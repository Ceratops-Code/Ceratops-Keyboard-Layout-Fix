#!/usr/bin/env python3
"""Build, publish, or install the standalone Windows setup through SDLC.

Inno Setup owns compilation and installation; gh owns GitHub authentication and
uploads. This adapter keeps successful build bundles under the primary checkout's
.build/installer directory so linked worktrees share them. Packaging inputs, not
test or CI edits, identify a build. Only integrity checks are repeated on reuse.
The directory has one exclusive lock, at most three completed bundles, and no
operational log. Private incomplete bundles are removed under the lock at startup
and on failure. Each checkout keeps its current versioned installer and at most
two predecessors; orphaned atomic-copy files are removed at startup. Published
release assets are never replaced or deleted.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import uuid
from collections.abc import Iterator, Mapping, Sequence
from typing import Any

SETUP_SCRIPT = "CeratopsKeyboardLayout-Setup.iss"
BUILD_SCHEMA = "ceratops-installer-build.v1"
BUNDLE_NAME = re.compile(r"[0-9a-f]{64}")
STAGING_NAME = re.compile(r"\.staging-[0-9a-f]{32}")
SETUP_FILENAME = re.compile(rf"{re.escape(pathlib.Path(SETUP_SCRIPT).stem)}-\d+\.\d+\.\d+\.exe")


class ReleaseError(RuntimeError):
    """An unmet release precondition; no automatic destructive recovery occurs."""


def installer_filename(version: str) -> str:
    """Use the product version in every build, release, and install path."""
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ReleaseError("The installer requires a three-part product version.")
    return f"{pathlib.Path(SETUP_SCRIPT).stem}-{version}.exe"


def source_version(root: pathlib.Path) -> str:
    """Inno's AppVersion definition is the only application-version owner."""
    versions = re.findall(r'(?m)^#define AppVersion "([^"]+)"$', (root / SETUP_SCRIPT).read_text(encoding="utf-8-sig"))
    if len(versions) != 1:
        raise ReleaseError("The installer must declare exactly one AppVersion.")
    installer_filename(versions[0])
    return versions[0]


def retain_checkout_installers(root: pathlib.Path, current: pathlib.Path | None = None) -> None:
    """Prune only this producer's versioned outputs under the shared build lock."""
    completed = []
    for path in root.iterdir():
        if path.name.startswith(".") and path.name.endswith(".tmp") and SETUP_FILENAME.fullmatch(path.name[1:-4]):
            if path.is_symlink() or not path.is_file():
                raise ReleaseError(f"Unsafe installer temporary file: {path.name}")
            path.unlink()
        elif SETUP_FILENAME.fullmatch(path.name):
            if path.is_symlink() or not path.is_file():
                raise ReleaseError(f"Unsafe installer output: {path.name}")
            completed.append(path)
    completed.sort(key=lambda path: path.stat().st_mtime_ns, reverse=True)
    keep = {current, *[path for path in completed if path != current][:2]} if current else set(completed[:3])
    for path in completed:
        if path not in keep:
            path.unlink()


def run_command(
    argv: Sequence[str], root: pathlib.Path, *, data: bytes | None = None
) -> subprocess.CompletedProcess[bytes]:
    """Use exact argv, inherited credentials, and bounded error excerpts."""
    result = subprocess.run(argv, cwd=root, input=data, capture_output=True, check=False)
    if result.returncode:
        details = (result.stderr or result.stdout).decode("utf-8", errors="replace")
        raise ReleaseError(f"{argv[0]} exited {result.returncode}: {details[-2000:].strip()}")
    return result


def git_output(root: pathlib.Path, *args: str) -> str:
    return run_command(["git", *args], root).stdout.decode("utf-8").strip()


def source_commit(root: pathlib.Path) -> str:
    """Do not label a build with a commit that omits local source changes."""
    if git_output(root, "status", "--porcelain"):
        raise ReleaseError("Commit source changes before building or releasing the installer.")
    return git_output(root, "rev-parse", "HEAD")


def build_store(root: pathlib.Path) -> pathlib.Path:
    common = pathlib.Path(git_output(root, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    store = common.parent / ".build" / "installer"
    if not store.resolve().is_relative_to(common.parent.resolve()):
        raise ReleaseError("The installer build store must stay inside its repository.")
    return store


def file_digest(path: pathlib.Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def remove_bundle(store: pathlib.Path, path: pathlib.Path) -> None:
    """Remove only this producer's direct, non-linked child directory."""
    if path.is_symlink() or path.resolve().parent != store.resolve():
        raise ReleaseError(f"Unsafe build directory: {path}")
    shutil.rmtree(path)


@contextlib.contextmanager
def locked_store(store: pathlib.Path) -> Iterator[None]:
    """One lock spans compilation, activation, and all release side effects."""
    store.mkdir(parents=True, exist_ok=True)
    if store.is_symlink():
        raise ReleaseError("The installer build store must not be a symbolic link.")
    lock_path = store / ".lock"
    if lock_path.is_symlink():
        raise ReleaseError("The installer lock must not be a symbolic link.")
    with lock_path.open("a+b") as lock:
        try:
            lock.seek(0)
            if not lock.read(1):
                lock.write(b"\0")
                lock.flush()
        except OSError as error:
            raise ReleaseError("Another installer operation is already running.") from error
        lock.seek(0)
        if sys.platform == "win32":
            import msvcrt

            try:
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as error:
                raise ReleaseError("Another installer operation is already running.") from error
        else:
            import fcntl

            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                raise ReleaseError("Another installer operation is already running.") from error
        try:
            for path in store.iterdir():
                if STAGING_NAME.fullmatch(path.name):
                    remove_bundle(store, path)
            yield
        finally:
            lock.seek(0)
            if sys.platform == "win32":
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def retain_builds(store: pathlib.Path, current: pathlib.Path) -> None:
    completed = sorted(
        (p for p in store.iterdir() if BUNDLE_NAME.fullmatch(p.name) and p.is_dir()),
        key=lambda p: p.stat().st_mtime_ns,
        reverse=True,
    )
    # Current plus the two newest other completed bundles is the finite group.
    keep = {current, *[p for p in completed if p != current][:2]}
    for path in completed:
        if path not in keep:
            remove_bundle(store, path)


def compiler_path(root: pathlib.Path, version: str) -> pathlib.Path:
    compiler = shutil.which("ISCC.exe")
    if compiler:
        return pathlib.Path(compiler)
    folder = f"Inno Setup {version.split('.')[0]}"
    for variable, parent in (
        ("LOCALAPPDATA", "Programs"), ("ProgramFiles(x86)", ""), ("ProgramFiles", "")
    ):
        if os.environ.get(variable):
            path = pathlib.Path(os.environ[variable]) / parent / folder / "ISCC.exe"
            if path.is_file():
                return path
    raise ReleaseError(f"Install Inno Setup {version}; ISCC.exe was not found.")


def packaging_inputs(root: pathlib.Path, compiler: pathlib.Path) -> dict[str, str]:
    """Read literal Inno [Files] metadata; hashing binds bytes, not behavior.

    Dynamic includes and wildcard sources cannot establish a complete input set
    here, so they fail before compilation rather than producing a stale cache.
    The current installer declares all runtime, license, and icon files literally.
    """
    script = (root / SETUP_SCRIPT).read_text(encoding="utf-8-sig")
    if re.search(r"(?im)^\s*#include\b", script):
        raise ReleaseError("Installer includes require explicit packaging-input support.")
    sources = re.findall(r'(?im)^\s*Source:\s*"([^"]+)"', script)
    if not sources:
        raise ReleaseError("The installer declares no literal source files.")
    inputs = {}
    for name in [SETUP_SCRIPT, *sources]:
        relative = pathlib.PureWindowsPath(name)
        if relative.is_absolute() or relative.drive or ".." in relative.parts or re.search(r"[*?{}#]", name):
            raise ReleaseError(f"Unsupported installer source path: {name}")
        path = root.joinpath(*relative.parts)
        if not path.resolve().is_relative_to(root.resolve()) or not path.is_file():
            raise ReleaseError(f"Installer source is missing or outside the repository: {name}")
        inputs[relative.as_posix()] = file_digest(path)
    # ISCC is a thin front end; its compiler and preprocessor DLLs also identify
    # the actual tool. Paths in receipts stay portable across Windows accounts.
    for name in (compiler.name, "ISCmplr.dll", "ISPP.dll"):
        path = compiler.with_name(name)
        if not path.is_file():
            raise ReleaseError(f"The Inno Setup compiler dependency is missing: {name}")
        inputs[f"compiler/{name}"] = file_digest(path)
    return inputs


def build_identity(inputs: Mapping[str, str], compiler_version: str) -> str:
    payload = json.dumps({"inputs": inputs, "compiler": compiler_version}, sort_keys=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def installer_version(path: pathlib.Path, root: pathlib.Path) -> str:
    environment = os.environ.copy()
    environment["CERATOPS_INSTALLER_FILE"] = str(path)
    result = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command",
         "(Get-Item -LiteralPath $env:CERATOPS_INSTALLER_FILE).VersionInfo.ProductVersion"],
        cwd=root, env=environment, capture_output=True, check=True,
    )
    version = result.stdout.decode("utf-8-sig").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ReleaseError("The compiled installer has no three-part product version.")
    return version


def source_archive(root: pathlib.Path, dependencies: Mapping[str, str], output: pathlib.Path) -> None:
    """Keep the pinned GPL source next to the installer before any upload."""
    version = dependencies["AutoHotkey"]
    url = f"https://github.com/AutoHotkey/AutoHotkey/archive/refs/tags/v{version}.zip"
    request = urllib.request.Request(url, headers={"User-Agent": "CeratopsKeyboardLayout"})
    with urllib.request.urlopen(request, timeout=60) as response, output.open("xb") as stream:
        shutil.copyfileobj(response, stream)
    if file_digest(output) != dependencies["source_archive_sha256"]:
        raise ReleaseError("The AutoHotkey source archive does not match its pinned checksum.")


def read_build(bundle: pathlib.Path, identity: str) -> dict[str, Any]:
    try:
        record = json.loads((bundle / "receipt.json").read_text(encoding="utf-8"))
        if record["schema"] != BUILD_SCHEMA or record["identity"] != identity:
            raise ReleaseError("The installer build receipt belongs to another build.")
        if not re.fullmatch(r"\d+\.\d+\.\d+", record["version"]) or not isinstance(record["artifacts"], dict):
            raise ReleaseError("The installer build receipt has invalid metadata.")
        for name, digest in record["artifacts"].items():
            if pathlib.PureWindowsPath(name).name != name or file_digest(bundle / name) != digest:
                raise ReleaseError("A completed installer artifact changed after its build.")
        if installer_filename(record["version"]) not in record["artifacts"]:
            raise ReleaseError("The completed build has no installer.")
        return record
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ReleaseError(f"The installer build is incomplete: {bundle.name}") from error


def activate_installer(root: pathlib.Path, bundle: pathlib.Path, record: Mapping[str, Any]) -> None:
    name = installer_filename(record["version"])
    output = root / name
    pending = root / f".{name}.tmp"
    if output.is_symlink() or pending.is_symlink():
        raise ReleaseError("The installer output must not be a symbolic link.")
    pending.unlink(missing_ok=True)
    try:
        shutil.copyfile(bundle / name, pending)
        pending.replace(output)
    finally:
        pending.unlink(missing_ok=True)
    retain_checkout_installers(root, output)


@contextlib.contextmanager
def source_snapshot(root: pathlib.Path, store: pathlib.Path, commit: str) -> Iterator[tuple[pathlib.Path, pathlib.Path]]:
    """Compile committed Git bytes in isolation from concurrent working edits."""
    staging = store / f".staging-{uuid.uuid4().hex}"
    snapshot = staging / "source"
    snapshot.mkdir(parents=True)
    try:
        data = run_command(["git", "archive", "--format=tar", commit], root).stdout
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            for member in archive:
                relative = pathlib.PurePosixPath(member.name)
                destination = snapshot.joinpath(*relative.parts)
                if pathlib.PureWindowsPath(member.name).drive or not destination.resolve().is_relative_to(snapshot.resolve()):
                    raise ReleaseError("Git snapshot contains a path outside its private directory.")
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    stream = archive.extractfile(member)
                    assert stream is not None
                    with stream, destination.open("xb") as output:
                        shutil.copyfileobj(stream, output)
                else:
                    raise ReleaseError("Installer snapshots require ordinary tracked files.")
        yield staging, snapshot
    finally:
        if staging.exists():
            remove_bundle(store, staging)


def build_installer(
    root: pathlib.Path, store: pathlib.Path, compiler: pathlib.Path,
    dependencies: Mapping[str, str], commit: str,
) -> tuple[pathlib.Path, dict[str, Any]]:
    with source_snapshot(root, store, commit) as (staging, snapshot):
        version = source_version(snapshot)
        setup_name = installer_filename(version)
        inputs = packaging_inputs(snapshot, compiler)
        identity = build_identity(inputs, dependencies["InnoSetup"])
        bundle = store / identity
        if bundle.exists():
            record = read_build(bundle, identity)
        else:
            result = run_command([str(compiler), f"/O{staging}", SETUP_SCRIPT], snapshot)
            banner = result.stdout.decode("utf-8", errors="replace")
            match = re.search(r"Compiler engine version:\s*Inno Setup ([\d.]+)", banner)
            if not match or match.group(1) != dependencies["InnoSetup"]:
                raise ReleaseError("The compiler does not match the pinned Inno Setup version.")
            if installer_version(staging / setup_name, root) != version:
                raise ReleaseError("The compiled installer version differs from AppVersion.")
            source_name = f"AutoHotkey-v{dependencies['AutoHotkey']}-source.zip"
            source_archive(root, dependencies, staging / source_name)
            record = {
                "schema": BUILD_SCHEMA, "identity": identity, "source_commit": commit,
                "version": version, "inputs": inputs,
                "artifacts": {name: file_digest(staging / name) for name in (setup_name, source_name)},
            }
            (staging / "receipt.json").write_text(json.dumps(record, sort_keys=True) + "\n", encoding="utf-8")
            remove_bundle(staging, snapshot)
            staging.rename(bundle)
    activate_installer(root, bundle, record)
    retain_builds(store, bundle)
    return bundle, record


def github_json(
    root: pathlib.Path, endpoint: str, *, payload: Mapping[str, Any] | None = None,
    method: str = "GET", missing_ok: bool = False,
) -> Any:
    argv = ["gh", "api", endpoint, "--method", method]
    data = None
    if payload is not None:
        argv.extend(["--input", "-"])
        data = json.dumps(payload).encode("utf-8")
    result = subprocess.run(argv, cwd=root, input=data, capture_output=True, check=False)
    try:
        value = json.loads(result.stdout)
    except ValueError as error:
        raise ReleaseError("GitHub returned no usable JSON response.") from error
    if result.returncode:
        # A missing resource is the only condition authorizing creation. Auth,
        # rate limits, and network failures never masquerade as an absent release.
        if missing_ok and str(value.get("status")) == "404":
            return None
        raise ReleaseError(f"GitHub request failed: {value.get('message', 'unknown error')}")
    return value


def release_assets_match(release: Mapping[str, Any], artifacts: Mapping[str, str]) -> set[str]:
    present = set()
    for asset in release["assets"]:
        name = asset["name"]
        if name in artifacts:
            if asset["state"] != "uploaded" or asset.get("digest") != f"sha256:{artifacts[name]}":
                raise ReleaseError(f"Existing release asset differs; it will not be overwritten: {name}")
            present.add(name)
    return present


def find_release_by_tag(root: pathlib.Path, repository: str, tag: str) -> Any:
    """Find drafts as well as published releases; ambiguous drafts fail closed."""
    matches: list[dict[str, Any]] = []
    for page in range(1, 101):
        releases = github_json(root, f"repos/{repository}/releases?per_page=100&page={page}")
        matches.extend(release for release in releases if release["tag_name"] == tag)
        if len(matches) > 1:
            raise ReleaseError(f"Multiple releases use {tag}; choose the intended draft first.")
        if len(releases) < 100:
            return matches[0] if matches else None
    raise ReleaseError("The release listing exceeds the supported page limit.")


def publish_installer(root: pathlib.Path, bundle: pathlib.Path, record: Mapping[str, Any], commit: str) -> None:
    """Resume matching drafts; an already-published matching release is success."""
    repository = run_command(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], root).stdout.decode().strip()
    tag = f"v{record['version']}"
    # Missing refs return 404; the commits endpoint reports an unknown tag as
    # 422. Check existence through refs, then let GitHub peel annotated tags.
    tag_ref = github_json(root, f"repos/{repository}/git/ref/tags/{tag}", missing_ok=True)
    tag_commit = github_json(root, f"repos/{repository}/commits/{tag}") if tag_ref is not None else None
    if tag_commit is not None and tag_commit["sha"] != commit:
        raise ReleaseError(f"{tag} already points to a different source commit.")
    # The by-tag endpoint promises published releases. List releases to find
    # resumable drafts, then address the selected release by its stable ID.
    release = find_release_by_tag(root, repository, tag)
    if release is None:
        release = github_json(root, f"repos/{repository}/releases", method="POST", payload={
            "tag_name": tag, "target_commitish": commit, "name": f"Ceratops Keyboard Layout {record['version']}",
            "draft": True, "generate_release_notes": True,
            "body": "Standalone Windows installer. AutoHotkey's corresponding GPL source is attached.",
        })
    endpoint = f"repos/{repository}/releases/{release['id']}"
    if release["target_commitish"] != commit:
        raise ReleaseError("The draft release belongs to a different source commit.")
    present = release_assets_match(release, record["artifacts"])
    missing = set(record["artifacts"]) - present
    if missing and not release["draft"]:
        raise ReleaseError("A published release is missing required assets; it will not be modified.")
    for name in sorted(missing):
        run_command(["gh", "release", "upload", tag, str(bundle / name), "--repo", repository], root)
    release = github_json(root, endpoint)
    if release_assets_match(release, record["artifacts"]) != set(record["artifacts"]):
        raise ReleaseError("The draft does not contain all required release assets.")
    if release["draft"]:
        github_json(root, f"repos/{repository}/releases/{release['id']}", method="PATCH", payload={"draft": False, "make_latest": "true"})
    release = github_json(root, endpoint)
    tag_commit = github_json(root, f"repos/{repository}/commits/{tag}")
    if release["draft"] or tag_commit["sha"] != commit or release_assets_match(release, record["artifacts"]) != set(record["artifacts"]):
        raise ReleaseError("GitHub has not completed the expected release publication.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "publish", "install"))
    parser.add_argument("--repo-root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.repo_root.resolve()
    try:
        commit = source_commit(root)
        dependencies = json.loads(git_output(root, "show", f"{commit}:dependencies.json"))
        compiler = compiler_path(root, dependencies["InnoSetup"])
        store = build_store(root)
        with locked_store(store):
            retain_checkout_installers(root)
            if args.action == "build":
                build_installer(root, store, compiler, dependencies, commit)
            else:
                with source_snapshot(root, store, commit) as (_, snapshot):
                    identity = build_identity(packaging_inputs(snapshot, compiler), dependencies["InnoSetup"])
                bundle = store / identity
                if not bundle.is_dir():
                    raise ReleaseError("Run the SDLC installer build action before publication or installation.")
                record = read_build(bundle, identity)
                activate_installer(root, bundle, record)
                retain_builds(store, bundle)
                if args.action == "publish":
                    publish_installer(root, bundle, record, commit)
                else:
                    run_command([str(root / installer_filename(record["version"])), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-"], root)
        print("OK")
        return 0
    except (ReleaseError, OSError, ValueError, KeyError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
