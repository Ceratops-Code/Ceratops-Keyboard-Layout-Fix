#!/usr/bin/env python3
"""Exercise installer build preservation, bounded storage, and release recovery.

The compiler, public download, and GitHub boundary are replaced with behavioral
fakes: these tests neither install software nor touch GitHub. Each test owns a
private directory under the caller's task temp root and removes it on completion.
CI and local SDLC use this same executable test entrypoint.
"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
from typing import Any
from unittest import mock

import pytest

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("installer_release", REPOSITORY / "scripts" / "release-installer.py")
assert SPEC is not None and SPEC.loader is not None
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
RUNNER_SPEC = importlib.util.spec_from_file_location("test_runner", REPOSITORY / "scripts" / "run-tests.py")
assert RUNNER_SPEC is not None and RUNNER_SPEC.loader is not None
runner = importlib.util.module_from_spec(RUNNER_SPEC)
RUNNER_SPEC.loader.exec_module(runner)
TASK_TEMP_ROOT: pathlib.Path


@pytest.fixture(scope="module", autouse=True)
def use_test_temp_root(tmp_path_factory: pytest.TempPathFactory) -> None:
    """Let pytest own bounded scratch while preserving unittest's direct entry."""
    global TASK_TEMP_ROOT
    TASK_TEMP_ROOT = tmp_path_factory.mktemp("installer-cases")


class BuildTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="installer-check-", dir=TASK_TEMP_ROOT)
        self.addCleanup(temporary.cleanup)
        fixture = pathlib.Path(temporary.name)
        self.root = fixture / "repo"
        self.root.mkdir()
        self.version = "1.0.12"
        self.setup_name = "CeratopsKeyboardLayout-Setup-1.0.12.exe"
        self.store = fixture / "tmp/repo/primary/_installer-build" / release.PACKAGE
        self.bundle = self.root / ".git/ceratops/artifacts/worktrees/primary/members/packages" / release.PACKAGE / self.version / "native"
        self.build_result: dict[str, Any] = {}
        self.compiler = self.root / "tool" / "ISCC.exe"
        self.compiler.parent.mkdir()
        for name in ("ISCC.exe", "ISCmplr.dll", "ISPP.dll"):
            self.compiler.with_name(name).write_bytes(name.encode())
        self.dependencies = {"AutoHotkey": "2.0.29", "InnoSetup": "6.7.3", "source_archive_sha256": "pinned"}
        (self.root / "dependencies.json").write_text(json.dumps(self.dependencies), encoding="utf-8")
        (self.root / "payload.ahk").write_text("payload", encoding="utf-8")
        (self.root / release.SETUP_SCRIPT).write_text(
            f'#define AppVersion "{self.version}"\n[Files]\nSource: "payload.ahk"\nSource: "dependencies.json"\n', encoding="utf-8"
        )
        self.command = self.enterContext(mock.patch.object(release, "run_command", side_effect=self.compile))
        self.download = self.enterContext(mock.patch.object(release, "source_archive", side_effect=self.download_source))
        self.enterContext(mock.patch.object(release, "installer_version", side_effect=lambda path, root: self.version))

    def compile(self, argv: list[str], root: pathlib.Path, **kwargs: Any) -> subprocess.CompletedProcess[bytes]:
        if argv[:3] == ["gh", "repo", "view"]:
            return subprocess.CompletedProcess(argv, 0, b"example/keyboard\n", b"")
        if argv[:2] == ["git", "show"]:
            data = (self.root / release.SETUP_SCRIPT).read_bytes() if argv[2].endswith(":" + release.SETUP_SCRIPT) else json.dumps(self.dependencies).encode()
            return subprocess.CompletedProcess(argv, 0, data, b"")
        if argv[:2] == ["git", "status"]:
            return subprocess.CompletedProcess(argv, 0, b"", b"")
        if argv[:2] == ["git", "rev-parse"]:
            value = ("main" if "--abbrev-ref" in argv else
                     "a" * 40 if argv[2:] == ["HEAD"] else str(self.root / ".git"))
            return subprocess.CompletedProcess(argv, 0, value.encode(), b"")
        if argv[:2] == ["git", "archive"]:
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode="w") as archive:
                for name in (release.SETUP_SCRIPT, "payload.ahk", "dependencies.json"):
                    archive.add(self.root / name, arcname=name)
            return subprocess.CompletedProcess(argv, 0, stream.getvalue(), b"")
        if argv[0] == str(self.compiler):
            output = pathlib.Path(argv[1][2:])
            (output / self.setup_name).write_bytes(b"standalone installer")
        return subprocess.CompletedProcess(argv, 0, b"Compiler engine version: Inno Setup 6.7.3\n", b"")

    def download_source(self, root: pathlib.Path, dependencies: dict[str, str], path: pathlib.Path) -> None:
        path.write_bytes(b"corresponding GPL source")

    def build(self, commit: str = "a" * 40) -> tuple[pathlib.Path, dict[str, Any]]:
        bundle, result = release.build_installer(self.root, self.compiler, self.dependencies, commit)
        self.build_result = {**result, "artifact_directory": str(bundle)}
        return bundle, result

    def compiler_calls(self) -> list[Any]:
        return [call for call in self.command.call_args_list if call.args[0][0] == str(self.compiler)]

    def install(self) -> int:
        with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(self.build_result))), \
             mock.patch.object(release.subprocess, "run", side_effect=AssertionError("Installation must not contact GitHub.")), \
             mock.patch.object(sys, "argv", ["release-installer.py", "install", "--repo-root", str(self.root)]), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return release.main()

    def installer_calls(self) -> list[Any]:
        return [call for call in self.command.call_args_list if call.args[0][0] == str(self.bundle / self.setup_name)]

    def test_completed_build_contains_installer_and_corresponding_source(self) -> None:
        output = io.StringIO()
        with mock.patch.object(release, "compiler_path", return_value=self.compiler), \
             mock.patch.object(sys, "argv", ["builder", "build", "--repo-root", str(self.root)]), \
             contextlib.redirect_stdout(output):
            self.assertEqual(release.main(), 0)
        record = json.loads(output.getvalue())
        self.assertEqual(pathlib.Path(record["artifact_directory"]), self.bundle)
        self.assertEqual((self.bundle / self.setup_name).read_bytes(), b"standalone installer")
        self.assertEqual(record["version"], self.version)
        self.assertEqual(set(record["artifacts"]), {path.name for path in self.bundle.iterdir()})
        self.assertEqual(len(record["artifacts"]), 2)
        self.assertEqual(release.read_build(self.bundle, record), record)
        self.assertFalse(self.store.exists())

        receipt = self.root / "installer-result.json"
        allocated = self.root / "allocated"
        allocated.mkdir()
        with (mock.patch.object(release, "compiler_path", return_value=self.compiler),
              mock.patch.object(sys, "argv", ["builder", "build", "--repo-root", str(self.root),
                                             "--artifact-directory", str(allocated), "--receipt-file", str(receipt)])):
            self.assertEqual(release.main(), 0)
        output = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual((output["schema"], output["installationArtifactPath"]),
                         ("ceratops-builder-output", self.setup_name))
        artifacts = [str(allocated / entry["path"]) for entry in output["artifacts"]]
        self.assertEqual(set(artifacts), {str(path) for path in allocated.iterdir()})
        self.assertTrue(all(self.version in pathlib.Path(path).name for path in artifacts))
        self.assertFalse((self.root / self.setup_name).exists())
        accepted = json.dumps({"deliverables.packages.ceratops-keyboard-layout-installer": artifacts})
        with (mock.patch.object(release, "source_commit", side_effect=AssertionError("unexpected checkout access")),
              mock.patch.object(release, "compiler_path", side_effect=AssertionError("unexpected build")),
              mock.patch.object(release, "publish_installer") as publish):
            for action in ("install", "publish"):
                with mock.patch.object(sys, "argv", ["delivery", action, "--repo-root", str(self.root),
                                                    "--accepted-artifacts", accepted]):
                    self.assertEqual(release.main(), 0)
            self.assertEqual(publish.call_args.args[1], allocated)
            self.assertEqual(publish.call_args.args[3], record["source_commit"])
        self.command.assert_any_call([str(allocated / self.setup_name), "/VERYSILENT", "/SUPPRESSMSGBOXES",
                                      "/NORESTART", "/SP-"], self.root)

    def test_repeat_refuses_the_completed_version_without_compilation(self) -> None:
        first, record = self.build()
        self.store.mkdir(parents=True)
        (self.store / "abandoned").write_bytes(b"partially published")
        with self.assertRaisesRegex(release.ReleaseError, "output already exists"):
            self.build("b" * 40)
        self.assertEqual(release.read_build(first, record), record)
        self.assertEqual(len(self.compiler_calls()), 1)
        self.assertFalse(self.store.exists())

    def test_compilation_uses_snapshot_when_original_changes(self) -> None:
        captured: list[bytes] = []
        def edit_original(argv: list[str], root: pathlib.Path) -> subprocess.CompletedProcess[bytes]:
            if argv[0] == str(self.compiler):
                (self.root / "payload.ahk").write_bytes(b"concurrent edit")
                captured.append((root / "payload.ahk").read_bytes())
            return self.compile(argv, root)
        self.command.side_effect = edit_original
        self.build()
        self.assertEqual(captured, [b"payload"])

    def test_snapshot_cannot_write_outside_private_directory(self) -> None:
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            member = tarfile.TarInfo("../../escaped.txt")
            member.size = 1
            archive.addfile(member, io.BytesIO(b"x"))
        self.command.side_effect = None
        self.command.return_value = subprocess.CompletedProcess([], 0, stream.getvalue(), b"")
        with (mock.patch.object(release, "source_version", return_value=self.version),
              mock.patch.object(release, "build_store", return_value=(self.store, self.bundle)),
              self.assertRaisesRegex(release.ReleaseError, "outside")):
            self.build()
        self.assertFalse((self.root / "escaped.txt").exists())

    def test_compiler_failure_preserves_previous_installer_and_removes_staging(self) -> None:
        (self.root / self.setup_name).write_bytes(b"previous accepted build")
        def fail_compilation(argv: list[str], root: pathlib.Path) -> subprocess.CompletedProcess[bytes]:
            if argv[0] == str(self.compiler):
                raise release.ReleaseError("compiler failed")
            return self.compile(argv, root)
        self.command.side_effect = fail_compilation
        with self.assertRaises(release.ReleaseError):
            self.build()
        self.assertEqual((self.root / self.setup_name).read_bytes(), b"previous accepted build")
        self.assertFalse(self.store.exists())

    def test_source_download_failure_does_not_activate_partial_build(self) -> None:
        (self.root / self.setup_name).write_bytes(b"previous accepted build")
        self.download.side_effect = OSError("network unavailable")
        with self.assertRaises(OSError):
            self.build()
        self.assertEqual((self.root / self.setup_name).read_bytes(), b"previous accepted build")
        self.assertFalse(self.store.exists())

    def test_changed_completed_artifact_is_refused_without_rebuilding(self) -> None:
        bundle, _ = self.build()
        (bundle / self.setup_name).write_bytes(b"changed")
        self.assertEqual(self.install(), 1)
        self.assertFalse(self.installer_calls())
        self.assertEqual(len(self.compiler_calls()), 1)

    def test_wrong_compiler_version_does_not_activate_output(self) -> None:
        def wrong_compiler(argv: list[str], root: pathlib.Path) -> subprocess.CompletedProcess[bytes]:
            if argv[0] == str(self.compiler):
                return subprocess.CompletedProcess([], 0, b"Compiler engine version: Inno Setup 7.1.0", b"")
            return self.compile(argv, root)
        self.command.side_effect = wrong_compiler
        with self.assertRaisesRegex(release.ReleaseError, "pinned"):
            self.build()
        self.assertFalse((self.root / self.setup_name).exists())
        self.download.assert_not_called()

    def test_builder_leaves_older_versions_to_store_retention(self) -> None:
        older = self.bundle.parent.parent / "1.0.1" / "native"
        older.mkdir(parents=True)
        artifact = older / "previous.exe"
        artifact.write_bytes(b"previous")
        self.build()
        self.assertEqual(artifact.read_bytes(), b"previous")
        self.assertFalse(self.store.exists())

    def test_builder_leaves_checkout_outputs_untouched(self) -> None:
        unrelated = self.root / self.setup_name
        unrelated.write_bytes(b"existing output")
        self.build()
        self.assertEqual(unrelated.read_bytes(), b"existing output")
        self.assertEqual((self.bundle / self.setup_name).read_bytes(), b"standalone installer")

    def test_startup_only_removes_this_deliverable_scratch(self) -> None:
        self.store.mkdir(parents=True)
        (self.store / "old").write_bytes(b"orphan")
        unrelated = self.store.parent / "another-deliverable"
        unrelated.mkdir()
        (unrelated / "keep").write_bytes(b"keep")
        self.build()
        self.assertFalse(self.store.exists())
        self.assertEqual((unrelated / "keep").read_bytes(), b"keep")

    def test_startup_preserves_previous_output_when_build_fails(self) -> None:
        self.store.mkdir(parents=True)
        (self.store / "incomplete").write_bytes(b"older scratch")
        unrelated = self.root / self.setup_name
        unrelated.write_bytes(b"previous")
        self.download.side_effect = release.ReleaseError("Failed to download source")
        with self.assertRaisesRegex(release.ReleaseError, "Failed to download source"):
            self.build()
        self.assertEqual(unrelated.read_bytes(), b"previous")
        self.assertFalse(self.store.exists())
        self.assertFalse(self.bundle.exists())

    def test_mismatched_compiled_version_preserves_accepted_output(self) -> None:
        output = self.root / self.setup_name
        output.write_bytes(b"previous accepted build")
        with mock.patch.object(release, "installer_version", return_value="9.9.9"):
            with self.assertRaisesRegex(release.ReleaseError, "differs from AppVersion"):
                self.build()
        self.assertEqual(output.read_bytes(), b"previous accepted build")
        self.assertFalse(self.store.exists())
        self.download.assert_not_called()

    def test_unsafe_version_fails_before_compilation(self) -> None:
        receipt = self.store / "receipt.json"
        arguments = [
            "release-installer.py", "build", "--repo-root", str(self.root),
            "--artifact-directory", str(self.store), "--receipt-file", str(receipt),
            "--version", "1.0.13",
        ]
        with mock.patch.object(release, "source_commit", return_value="a" * 40), \
             mock.patch.object(release, "compiler_path") as compiler, \
             mock.patch.object(sys, "argv", arguments), contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(release.main(), 1)
        self.assertIn("Requested package version 1.0.13 differs from AppVersion 1.0.12.", stderr.getvalue())
        compiler.assert_not_called()
        self.assertFalse(receipt.exists())

        script = self.root / release.SETUP_SCRIPT
        script.write_text('#define AppVersion "../outside"\n[Files]\nSource: "payload.ahk"\n', encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "three-part"):
            self.build()
        self.assertEqual(self.compiler_calls(), [])

    def test_release_local_uses_the_shared_release_pool(self) -> None:
        with mock.patch.object(release, "git_output", side_effect=[
            str(self.root / ".git"), str(self.root / ".git"), "release/local",
        ]):
            scratch, output = release.build_store(self.root, self.version)
        self.assertEqual(scratch, self.store)
        self.assertIn("beta-stable", output.parts)
        self.assertEqual(output.parts[-2:], (self.version, "native"))

    def test_existing_directory_at_publication_cannot_be_overwritten(self) -> None:
        with (mock.patch.object(pathlib.Path, "rename", side_effect=FileExistsError),
              self.assertRaisesRegex(release.ReleaseError, "output already exists")):
            self.build()
        self.assertFalse(self.bundle.exists())
        self.assertFalse(self.store.exists())

    def test_wildcard_source_is_refused_before_compilation(self) -> None:
        (self.root / release.SETUP_SCRIPT).write_text(f'#define AppVersion "{self.version}"\n[Files]\nSource: "*.ahk"\n', encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "Unsupported"):
            self.build()
        self.assertEqual(self.compiler_calls(), [])

    def test_source_archive_requires_its_pinned_checksum(self) -> None:
        with mock.patch.object(release.urllib.request, "urlopen", return_value=io.BytesIO(b"wrong archive")):
            with self.assertRaisesRegex(release.ReleaseError, "checksum"):
                # Invoke the real downloader, bypassing the build's download fake.
                self._real_source_archive(self.root, self.dependencies, self.root / "source.zip")

    _real_source_archive = staticmethod(release.source_archive)

    def test_missing_build_prevents_installation(self) -> None:
        with mock.patch.object(sys, "stdin", io.StringIO("")), \
             mock.patch.object(sys, "argv", ["release-installer.py", "install", "--repo-root", str(self.root)]), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(release.main(), 1)
        self.assertEqual(self.compiler_calls(), [])

    def test_installation_consumes_completed_build_without_recompilation(self) -> None:
        self.build()
        self.assertEqual(self.install(), 0)
        self.assertEqual(len(self.compiler_calls()), 1)
        self.assertEqual(self.command.call_args.args[0][0], str(self.bundle / self.setup_name))
        self.assertFalse(any(call.args[0][0] == "gh" for call in self.command.call_args_list))

    def test_repeated_installation_and_interruption_use_the_completed_build(self) -> None:
        self.build()

        def check_interrupted_install(boundary: str) -> None:
            target: list[bytes] = []
            interrupt = True

            def install_effect(argv: list[str], root: pathlib.Path, **kwargs: Any) -> subprocess.CompletedProcess[bytes]:
                if argv[0] == str(self.bundle / self.setup_name):
                    if interrupt and boundary == "before":
                        raise release.ReleaseError("installation interrupted before launch")
                    target[:] = [(self.bundle / self.setup_name).read_bytes()]
                    if interrupt and boundary == "after":
                        raise release.ReleaseError("installation interrupted after launch")
                return self.compile(argv, root, **kwargs)

            self.command.side_effect = install_effect
            self.assertEqual(self.install(), 1)
            self.assertEqual(target, [] if boundary == "before" else [b"standalone installer"])
            interrupt = False
            self.assertEqual(self.install(), 0)
            self.assertEqual(self.install(), 0)
            self.assertEqual(target, [b"standalone installer"])

        for boundary in ("before", "after"):
            with self.subTest(boundary=boundary):
                check_interrupted_install(boundary)
        self.assertEqual(len(self.compiler_calls()), 1)
        self.assertFalse(any(call.args[0][0] == "gh" for call in self.command.call_args_list))

    def test_unreadable_snapshot_fails_cleanly_without_an_installer(self) -> None:
        def unreadable_archive(argv: list[str], root: pathlib.Path) -> subprocess.CompletedProcess[bytes]:
            if argv[:2] == ["git", "archive"]:
                return subprocess.CompletedProcess(argv, 0, b"not an archive", b"")
            return self.compile(argv, root)
        self.command.side_effect = unreadable_archive
        with mock.patch.object(release, "compiler_path", return_value=self.compiler), \
             mock.patch.object(sys, "argv", ["release-installer.py", "build", "--repo-root", str(self.root)]), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(release.main(), 1)
        self.assertFalse(self.bundle.exists())
        self.assertFalse(self.store.exists())


class FakeGitHub:
    """Model drafts, upload interruption, and the tag created on publication."""

    def __init__(self, bundle: pathlib.Path, record: dict[str, Any]) -> None:
        self.bundle = bundle
        self.record = record
        self.commit = "a" * 40
        self.tag_commit: str | None = None
        self.release: dict[str, Any] | None = None
        self.creations = 0
        self.publications = 0
        self.uploads: list[str] = []
        self.fail_upload: int | None = None
        self.requests: list[str] = []
        self.other_releases: list[dict[str, Any]] = []

    def asset(self, name: str) -> dict[str, str]:
        return {"name": name, "state": "uploaded", "digest": "sha256:" + self.record["artifacts"][name]}

    def request(self, root: pathlib.Path, endpoint: str, *, payload: Any = None,
                method: str = "GET", missing_ok: bool = False) -> Any:
        if "/git/ref/tags/" in endpoint:
            return None if self.tag_commit is None else {"object": {"type": "commit", "sha": self.tag_commit}}
        if "/commits/" in endpoint:
            if self.tag_commit is None and missing_ok:
                return None
            return {"sha": self.tag_commit}
        if "/releases?" in endpoint:
            page = int(endpoint.rsplit("page=", 1)[1]) - 1
            releases = self.other_releases + ([self.release] if self.release else [])
            return copy.deepcopy(releases[page * 100:(page + 1) * 100])
        if "/releases/tags/" in endpoint and self.release and self.release["draft"]:
            return None
        if method == "POST":
            self.creations += 1
            self.release = {"id": 1, "tag_name": payload["tag_name"], "target_commitish": payload["target_commitish"], "draft": True, "assets": []}
        elif method == "PATCH":
            assert self.release is not None
            self.publications += 1
            self.release["draft"] = False
            self.tag_commit = self.commit
        return copy.deepcopy(self.release)

    def api_command(self, argv: list[str], **kwargs: Any) -> subprocess.CompletedProcess[bytes]:
        """Expose GitHub's distinct absent-ref and unknown-commit responses."""
        endpoint = argv[2]
        self.requests.append(endpoint)
        if "/commits/" in endpoint and self.tag_commit is None:
            value = {"status": "422", "message": "No commit found for SHA: v1.0.10"}
            code = 1
        else:
            payload = json.loads(kwargs["input"]) if kwargs.get("input") else None
            value = self.request(self.bundle, endpoint, payload=payload,
                                 method=argv[argv.index("--method") + 1], missing_ok=True)
            code = 0 if value is not None else 1
            if value is None:
                value = {"status": "404", "message": "Not Found"}
        return subprocess.CompletedProcess(argv, code, json.dumps(value).encode(), b"")

    def command(self, argv: list[str], root: pathlib.Path, **kwargs: Any) -> subprocess.CompletedProcess[bytes]:
        if argv[:3] == ["gh", "repo", "view"]:
            return subprocess.CompletedProcess(argv, 0, b"example/keyboard\n", b"")
        assert self.release is not None
        name = pathlib.Path(argv[4]).name
        self.uploads.append(name)
        if self.fail_upload == len(self.uploads):
            raise release.ReleaseError("upload interrupted")
        self.release["assets"].append(self.asset(name))
        return subprocess.CompletedProcess(argv, 0, b"", b"")


class PublishTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="release-check-", dir=TASK_TEMP_ROOT)
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.setup_name = "CeratopsKeyboardLayout-Setup-1.0.10.exe"
        self.record = {"version": "1.0.10", "artifacts": {self.setup_name: "installer-digest", "source.zip": "source-digest"}}
        self.github = FakeGitHub(self.root, self.record)
        self.enterContext(mock.patch.object(release.subprocess, "run", side_effect=self.github.api_command))
        self.enterContext(mock.patch.object(release, "run_command", side_effect=self.github.command))

    def publish(self) -> None:
        release.publish_installer(self.root, self.root, self.record, self.github.commit)

    def test_new_release_is_published_only_after_both_uploads(self) -> None:
        self.publish()
        self.assertEqual(self.github.creations, 1)
        self.assertEqual(self.github.publications, 1)
        self.assertEqual(set(self.github.uploads), set(self.record["artifacts"]))

    def test_missing_tag_checks_refs_before_resolving_commit(self) -> None:
        self.publish()
        self.assertIn("/git/ref/tags/", self.github.requests[0])
        self.assertEqual(sum("/commits/" in endpoint for endpoint in self.github.requests), 1)
        self.assertFalse(any("/releases/tags/" in endpoint for endpoint in self.github.requests))

    def test_interrupted_upload_resumes_draft_and_skips_finished_asset(self) -> None:
        self.github.fail_upload = 2
        with self.assertRaisesRegex(release.ReleaseError, "interrupted"):
            self.publish()
        self.assertEqual(self.github.publications, 0)
        self.github.other_releases = [{"tag_name": f"other-{index}"} for index in range(100)]
        self.github.fail_upload = None
        self.publish()
        self.assertEqual(self.github.creations, 1)
        self.assertEqual(len(self.github.uploads), 3)
        self.assertEqual(self.github.publications, 1)
        self.assertTrue(any("page=2" in endpoint for endpoint in self.github.requests))

    def test_matching_published_release_has_no_repeated_side_effects(self) -> None:
        self.publish()
        self.publish()
        self.assertEqual(self.github.creations, 1)
        self.assertEqual(self.github.publications, 1)
        self.assertEqual(len(self.github.uploads), 2)

    def test_wrong_tag_commit_is_refused_before_creation(self) -> None:
        self.github.tag_commit = "b" * 40
        with self.assertRaisesRegex(release.ReleaseError, "different source commit"):
            self.publish()
        self.assertEqual(self.github.creations, 0)
        self.assertEqual(self.github.uploads, [])

    def test_different_existing_asset_is_never_overwritten(self) -> None:
        self.github.release = {"id": 1, "tag_name": "v1.0.10", "target_commitish": self.github.commit, "draft": True,
                               "assets": [{"name": self.setup_name, "state": "uploaded", "digest": "sha256:other"}]}
        with self.assertRaisesRegex(release.ReleaseError, "not be overwritten"):
            self.publish()
        self.assertEqual(self.github.uploads, [])
        self.assertEqual(self.github.publications, 0)

    def test_published_release_with_missing_asset_is_left_intact(self) -> None:
        self.github.release = {"id": 1, "tag_name": "v1.0.10", "target_commitish": self.github.commit, "draft": False, "assets": []}
        with self.assertRaisesRegex(release.ReleaseError, "will not be modified"):
            self.publish()
        self.assertEqual(self.github.uploads, [])

    def test_duplicate_drafts_are_refused_before_creation(self) -> None:
        self.github.other_releases = [{"tag_name": "v1.0.10"}, {"tag_name": "v1.0.10"}]
        with self.assertRaisesRegex(release.ReleaseError, "Multiple releases"):
            self.publish()
        self.assertEqual(self.github.creations, 0)


class TaskTempRootTests(unittest.TestCase):
    """Keep the shared base separate from each repository and checkout's scratch."""

    def test_configured_and_default_bases_include_project_and_checkout(self) -> None:
        primary = REPOSITORY.parent / "Example-Project"
        for configured in (False, True):
            for checkout in (primary, primary.parent / "worktrees" / primary.name / "example-task"):
                with self.subTest(configured=configured, checkout=checkout.name):
                    selected = primary.parent / "shared-temp"
                    environment = {"CERATOPS_TASK_TEMP_ROOT": str(selected)} if configured else {}
                    result = subprocess.CompletedProcess([], 0, str(primary / ".git") + "\n", "")
                    with mock.patch.object(runner, "ROOT", checkout), \
                         mock.patch.dict(os.environ, environment, clear=True), \
                         mock.patch.object(runner.subprocess, "run", return_value=result):
                        expected = (selected if configured else primary.parent / "tmp") / primary.name / checkout.name
                        self.assertEqual(runner.task_temp_root(), expected)
                        self.assertEqual(runner.task_temp_root(), expected)

    def test_failed_repository_lookup_creates_no_scratch_or_test_process(self) -> None:
        with tempfile.TemporaryDirectory(prefix="root-check-", dir=TASK_TEMP_ROOT) as directory:
            base = pathlib.Path(directory) / "shared-temp"
            failed = subprocess.CompletedProcess([], 128, "", "repository unavailable")
            with mock.patch("write_check_results.CurrentCheckResults"), mock.patch.dict(os.environ, {"CERATOPS_TASK_TEMP_ROOT": str(base)}), \
                 mock.patch.object(runner.subprocess, "run", return_value=failed) as command, \
                 contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(runner.main(["--suite", "installer"]), 2)
            self.assertFalse(base.exists())
            self.assertEqual(command.call_count, 1)
            self.assertIn("repository unavailable", stderr.getvalue())

    def test_interrupted_runs_reuse_the_same_project_and_checkout_scope(self) -> None:
        for moment in ("before", "after"):
            with self.subTest(moment=moment):
                self.assert_interrupted_run_scope(moment)

    def assert_interrupted_run_scope(self, moment: str) -> None:
        with tempfile.TemporaryDirectory(prefix="root-check-", dir=TASK_TEMP_ROOT) as directory:
            base = pathlib.Path(directory) / "shared-temp"
            primary = pathlib.Path(directory) / "Example-Project"
            expected = base / primary.name / REPOSITORY.name
            interrupted = True

            def launch(command: list[str], **options: Any) -> subprocess.CompletedProcess[str]:
                if command[0] == "git":
                    return subprocess.CompletedProcess(command, 0, str(primary / ".git") + "\n", "")
                self.assertEqual(pathlib.Path(options["env"]["PYTEST_DEBUG_TEMPROOT"]), expected)
                if interrupted and moment == "before":
                    raise KeyboardInterrupt
                (expected / "pytest-of-fixture").mkdir()
                (expected / "child-effect.txt").write_text("completed", encoding="utf-8")
                if interrupted:
                    raise KeyboardInterrupt
                return subprocess.CompletedProcess(command, 0, "", "")

            with mock.patch("write_check_results.CurrentCheckResults"), mock.patch.dict(os.environ, {"CERATOPS_TASK_TEMP_ROOT": str(base), "PYTEST_ADDOPTS": ""}), \
                 mock.patch.object(runner.subprocess, "run", side_effect=launch), \
                 contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(KeyboardInterrupt):
                    runner.main(["--suite", "installer"])
                self.assertFalse((expected / "pytest-of-fixture").exists())
                interrupted = False
                self.assertEqual(runner.main(["--suite", "installer"]), 0)
                self.assertEqual(runner.main(["--suite", "installer"]), 0)
            self.assertEqual((expected / "child-effect.txt").read_text(encoding="utf-8"), "completed")
            self.assertFalse((expected / "pytest-of-fixture").exists())
            self.assertEqual([path.name for path in base.iterdir()], [primary.name])


class TestRunnerTests(unittest.TestCase):
    """Exercise the normal runner entrypoint without executing desktop effects."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="runner-check-", dir=TASK_TEMP_ROOT)
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.enterContext(mock.patch("write_check_results.CurrentCheckResults"))
        self.enterContext(mock.patch.object(runner, "task_temp_root", return_value=self.root / "scratch"))
        self.enterContext(mock.patch.object(runner.platform, "system", return_value="Windows"))
        self.enterContext(mock.patch.object(runner.shutil, "which", return_value="pwsh"))
        self.enterContext(mock.patch.dict(os.environ, {"CI": "", "PYTEST_ADDOPTS": ""}))
        self.command = self.enterContext(mock.patch.object(runner.subprocess, "run",
            return_value=subprocess.CompletedProcess([], 0, "", "")))

    def run_runner(self, arguments: list[str] | None = None) -> int:
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = runner.main(arguments or [])
        self.stdout, self.stderr = stdout.getvalue(), stderr.getvalue()
        return code

    def receipt_arguments(self, identity: str) -> list[str]:
        return ["--result-file", str(self.root / f"{identity}.json"), "--result-id", identity,
                "--candidate-id", "candidate", "--check-id", "repository", "--check-version", "runner"]

    def read_receipt(self, identity: str) -> dict[str, Any]:
        return json.loads((self.root / f"{identity}.json").read_text(encoding="utf-8"))

    def test_local_desktop_and_ci_have_distinct_recorded_scope(self) -> None:
        from write_check_results import summarize_check_result

        self.assertEqual(self.run_runner(self.receipt_arguments("desktop")), 0)
        self.assertEqual(self.command.call_count, 4)
        desktop = self.read_receipt("desktop")
        self.assertEqual(desktop["invocation"]["profile"], "desktop")
        self.assertEqual([item["name"] for item in desktop["checks"]],
                         ["updater", "key-conversion", "shortcut-dispatch", "accessible-conversion"])
        self.assertTrue(all(item["status"] == "passed" for item in desktop["checks"]))
        self.assertEqual([item["id"] for item in summarize_check_result(desktop)["checks"]],
                         ["updater", "key-conversion", "shortcut-dispatch", "accessible-conversion"])
        self.command.reset_mock()
        with mock.patch.dict(os.environ, {"CI": "true"}), \
             mock.patch.object(runner.platform, "system", return_value="Linux"):
            self.assertEqual(self.run_runner(self.receipt_arguments("ci")), 0)
        self.assertEqual(self.command.call_count, 1)
        self.assertEqual(self.command.call_args.args[0][0], "pwsh")
        ci = self.read_receipt("ci")
        self.assertEqual(ci["invocation"]["profile"], "ci")
        self.assertEqual(ci["checks"][-1]["status"], "not_applicable")
        optional = summarize_check_result(ci)["checks"][-1]
        self.assertEqual(optional["id"], "desktop-interaction")
        self.assertFalse(optional["required"])

    def test_ci_acceptance_cannot_replace_desktop_tests(self) -> None:
        arguments = self.receipt_arguments("ci")
        with mock.patch.dict(os.environ, {"CI": "true"}):
            self.assertEqual(self.run_runner(arguments), 0)
        original = (self.root / "ci.json").read_bytes()
        self.command.reset_mock()
        self.assertEqual(self.run_runner(arguments), 2)
        self.assertEqual(self.command.call_count, 0)
        self.assertEqual((self.root / "ci.json").read_bytes(), original)

    def test_repeated_accepted_runner_call_does_not_repeat_child_effects(self) -> None:
        arguments = self.receipt_arguments("accepted")
        self.assertEqual(self.run_runner(arguments), 0)
        original = (self.root / "accepted.json").read_bytes()
        self.assertEqual(self.run_runner(arguments), 0)
        self.assertEqual(self.command.call_count, 4)
        self.assertEqual((self.root / "accepted.json").read_bytes(), original)

    def test_each_child_failure_stops_later_suites_and_keeps_both_streams(self) -> None:
        def check_failure(stage: int) -> None:
            self.command.reset_mock()
            self.command.side_effect = [subprocess.CompletedProcess([], 0, "", "")] * stage + [
                subprocess.CompletedProcess([], 7, "child output", "child error")]
            self.assertEqual(self.run_runner(), 7)
            self.assertEqual(self.command.call_count, stage + 1)
            command = self.command.call_args.args[0]
            self.assertIn("Command: " + json.dumps(command), self.stderr)
            self.assertIn("Exit status: 7", self.stderr)
            self.assertIn("stdout:\nchild output", self.stderr)
            self.assertIn("stderr:\nchild error", self.stderr)

        for stage in range(4):
            with self.subTest(stage=stage):
                check_failure(stage)

    def test_interrupted_child_boundaries_require_a_fresh_normal_call(self) -> None:
        def check_interruption(stage: int, boundary: str) -> None:
            effects: list[list[str]] = []
            interrupt = True

            def effect(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
                if interrupt and len(effects) == stage and boundary == "before":
                    raise KeyboardInterrupt
                effects.append(command)
                if interrupt and len(effects) == stage + 1 and boundary == "after":
                    raise KeyboardInterrupt
                return subprocess.CompletedProcess(command, 0, "", "")

            self.command.side_effect = effect
            identity = f"interrupted-{stage}-{boundary}"
            arguments = self.receipt_arguments(identity)
            self.assertEqual(self.run_runner(arguments), 130)
            self.assertEqual(len(effects), stage + (boundary == "after"))
            self.assertEqual(self.read_receipt(identity)["status"], "interrupted")
            original = (self.root / f"{identity}.json").read_bytes()
            self.assertEqual(self.run_runner(arguments), 2)
            interrupt = False
            fresh = self.receipt_arguments(f"fresh-{stage}-{boundary}")
            before = len(effects)
            self.assertEqual(self.run_runner(fresh), 0)
            self.assertEqual(len(effects), before + 4)
            self.assertEqual(self.run_runner(fresh), 0)
            self.assertEqual(len(effects), before + 4)
            self.assertEqual((self.root / f"{identity}.json").read_bytes(), original)

        for stage in range(4):
            for boundary in ("before", "after"):
                with self.subTest(stage=stage, boundary=boundary):
                    check_interruption(stage, boundary)

    def test_missing_powershell_blocks_before_child_effects(self) -> None:
        with mock.patch.object(runner.shutil, "which", return_value=None):
            self.assertEqual(self.run_runner(), 2)
        self.assertIn("PowerShell Core", self.stderr)
        self.assertEqual(self.command.call_count, 0)

    def test_non_windows_local_repository_run_cannot_skip_desktop_tests(self) -> None:
        with mock.patch.object(runner.platform, "system", return_value="Linux"):
            self.assertEqual(self.run_runner(), 2)
        self.assertIn("signed-in Windows desktop", self.stderr)
        self.assertEqual(self.command.call_count, 0)

    def test_installer_uses_current_python_and_keeps_scratch_in_its_scope(self) -> None:
        with mock.patch.dict(os.environ, {"PYTEST_ADDOPTS": "--basetemp=unsafe -q"}):
            self.assertEqual(self.run_runner(["--suite", "installer", "--pytest-arg=--basetemp=unsafe"]), 0)
        command = self.command.call_args.args[0]
        environment = self.command.call_args.kwargs["env"]
        self.assertEqual(command[:3], [sys.executable, "-m", "pytest"])
        self.assertFalse(any("basetemp" in argument for argument in command))
        self.assertIn("tmp_path_retention_policy=none", command)
        self.assertEqual(environment["PYTEST_ADDOPTS"], "-q")
        self.assertEqual(environment["PYTEST_DEBUG_TEMPROOT"], str(self.root / "scratch"))
        self.assertEqual(environment["PYTHONDONTWRITEBYTECODE"], "1")
        self.assertNotIn(runner.CHECK_CONTEXT_ENV, environment)

    def test_child_launch_error_retains_runtime_and_absent_output(self) -> None:
        self.command.side_effect = FileNotFoundError("missing executable")
        self.assertEqual(self.run_runner(), 127)
        self.assertIn('"pwsh"', self.stderr)
        self.assertIn("stdout:\n<absent>", self.stderr)
        self.assertIn("FileNotFoundError: missing executable", self.stderr)

    def test_shared_probe_protocol_keeps_canonical_acceptance_and_reuses_it(self) -> None:
        from write_check_results import select_build_check_summaries

        command = [sys.executable, "-c", "pass"]
        arguments = self.receipt_arguments("probe") + ["--probe-command", json.dumps(command)]
        self.assertEqual(self.run_runner(arguments), 0)
        receipt = self.read_receipt("probe")
        self.assertEqual(set(receipt), {"schema", "result_id", "candidate_id", "check_id",
                                       "check_version", "invocation", "status", "exit_code"})
        self.assertEqual(receipt["invocation"], {"targets": [], "pytest_args": [],
                                               "pytest_addopts": [], "probe_command": command})
        self.assertEqual(self.command.call_args.args[0], command)
        self.assertEqual(self.run_runner(arguments), 0)
        self.assertEqual(self.command.call_count, 1)

        tag = "members/packages/fixture/1.0a1"
        path = f".ceratops/build/{tag}/build_receipt.json"
        stored = {"tag": tag, "receipt": {"identity": {"target": "native"}},
                  "summary": {"checks": [{**receipt, "qualificationLevel": "alpha"}]}}
        with (mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}),
              mock.patch("write_check_results._build_git") as git,
              mock.patch("write_check_results.read_build_check_summary", return_value=stored) as read):
            for _repeat in range(2):
                git.side_effect = [b"head-commit", tag.encode() + b"\n", path.encode() + b"\0"]
                self.assertEqual(select_build_check_summaries(self.root, qualification_level="beta"), [stored])
                read.assert_called_with(self.root, tag, path, revision="head-commit")
            read.reset_mock()
            for level in ("rc", "final"):
                git.side_effect = [b"head-commit", tag.encode() + b"\n"]
                self.assertEqual(select_build_check_summaries(self.root, qualification_level=level), [])
            read.assert_not_called()


class GitHubResponseTests(unittest.TestCase):
    def test_child_failure_keeps_command_status_and_both_streams(self) -> None:
        for stdout, stderr in ((b"child output", b"child error"), (b"", b"")):
            response = subprocess.CompletedProcess([], 7, stdout, stderr)
            with mock.patch.object(release.subprocess, "run", return_value=response):
                with self.assertRaises(release.ReleaseError) as observed:
                    release.run_command(["gh", "repo", "view"], REPOSITORY)
            message = str(observed.exception)
            self.assertIn('["gh", "repo", "view"]', message)
            self.assertIn("Exit status: 7", message)
            self.assertIn("stdout:\n" + (stdout.decode() or "<absent>"), message)
            self.assertIn("stderr:\n" + (stderr.decode() or "<absent>"), message)

    def test_only_404_can_mean_a_missing_release(self) -> None:
        for status in (401, 403, 422, 429, 503):
            response = subprocess.CompletedProcess([], 1, json.dumps({"status": str(status), "message": "denied"}).encode(), b"")
            with self.subTest(status=status), mock.patch.object(release.subprocess, "run", return_value=response):
                with self.assertRaises(release.ReleaseError):
                    release.github_json(REPOSITORY, "repos/example/keyboard/releases/tags/v1", missing_ok=True)

    def test_missing_release_response_is_explicit(self) -> None:
        response = subprocess.CompletedProcess([], 1, b'{"status":"404","message":"Not Found"}', b"")
        with mock.patch.object(release.subprocess, "run", return_value=response):
            self.assertIsNone(release.github_json(REPOSITORY, "repos/example/keyboard/releases/tags/v1", missing_ok=True))


def main() -> int:
    global TASK_TEMP_ROOT
    common = pathlib.Path(subprocess.check_output(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=REPOSITORY, text=True
    ).strip())
    TASK_TEMP_ROOT = pathlib.Path(os.environ.get("CERATOPS_TASK_TEMP_ROOT", str(common.parent.parent / "tmp" / common.parent.name / "installer-release-tests")))
    TASK_TEMP_ROOT.mkdir(parents=True, exist_ok=True)
    try:
        program = unittest.main(exit=False)
        return 0 if program.result.wasSuccessful() else 1
    finally:
        try:
            TASK_TEMP_ROOT.rmdir()
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
