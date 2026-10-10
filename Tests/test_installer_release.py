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

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("installer_release", REPOSITORY / "scripts" / "release-installer.py")
assert SPEC is not None and SPEC.loader is not None
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
TASK_TEMP_ROOT: pathlib.Path


class BuildTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="installer-check-", dir=TASK_TEMP_ROOT)
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.store = self.root / "cache"
        self.store.mkdir()
        self.compiler = self.root / "tool" / "ISCC.exe"
        self.compiler.parent.mkdir()
        for name in ("ISCC.exe", "ISCmplr.dll", "ISPP.dll"):
            self.compiler.with_name(name).write_bytes(name.encode())
        self.dependencies = {"AutoHotkey": "2.0.29", "InnoSetup": "6.7.3", "source_archive_sha256": "pinned"}
        (self.root / "dependencies.json").write_text(json.dumps(self.dependencies), encoding="utf-8")
        (self.root / "payload.ahk").write_text("payload", encoding="utf-8")
        (self.root / release.SETUP_SCRIPT).write_text(
            '[Files]\nSource: "payload.ahk"\nSource: "dependencies.json"\n', encoding="utf-8"
        )
        self.command = self.enterContext(mock.patch.object(release, "run_command", side_effect=self.compile))
        self.download = self.enterContext(mock.patch.object(release, "source_archive", side_effect=self.download_source))
        self.enterContext(mock.patch.object(release, "installer_version", return_value="1.0.10"))

    def compile(self, argv: list[str], root: pathlib.Path, **kwargs: Any) -> subprocess.CompletedProcess[bytes]:
        if argv[:2] == ["git", "show"]:
            return subprocess.CompletedProcess(argv, 0, json.dumps(self.dependencies).encode(), b"")
        if argv[:2] == ["git", "archive"]:
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode="w") as archive:
                for name in (release.SETUP_SCRIPT, "payload.ahk", "dependencies.json"):
                    archive.add(self.root / name, arcname=name)
            return subprocess.CompletedProcess(argv, 0, stream.getvalue(), b"")
        if argv[0] == str(self.compiler):
            output = pathlib.Path(argv[1][2:])
            (output / release.SETUP_NAME).write_bytes(b"standalone installer")
        return subprocess.CompletedProcess(argv, 0, b"Compiler engine version: Inno Setup 6.7.3\n", b"")

    def download_source(self, root: pathlib.Path, dependencies: dict[str, str], path: pathlib.Path) -> None:
        path.write_bytes(b"corresponding GPL source")

    def build(self, commit: str = "a" * 40) -> tuple[pathlib.Path, dict[str, Any]]:
        return release.build_installer(self.root, self.store, self.compiler, self.dependencies, commit)

    def compiler_calls(self) -> list[Any]:
        return [call for call in self.command.call_args_list if call.args[0][0] == str(self.compiler)]

    def test_completed_build_contains_installer_and_corresponding_source(self) -> None:
        bundle, record = self.build()
        self.assertEqual((self.root / release.SETUP_NAME).read_bytes(), b"standalone installer")
        self.assertEqual(len(record["artifacts"]), 2)
        self.assertEqual(release.read_build(bundle, record["identity"]), record)
        self.assertFalse(any(p.name.startswith(".staging-") for p in self.store.iterdir()))

    def test_test_only_commit_reuses_completed_build_without_compilation(self) -> None:
        first, record = self.build()
        (self.root / "Tests").mkdir()
        (self.root / "Tests" / "case.py").write_text("new test", encoding="utf-8")
        second, reused = self.build("b" * 40)
        self.assertEqual(first, second)
        self.assertEqual(reused, record)
        self.assertEqual(len(self.compiler_calls()), 1)
        self.assertEqual(self.download.call_count, 1)

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
        with self.assertRaisesRegex(release.ReleaseError, "outside"):
            self.build()
        self.assertFalse((self.root / "escaped.txt").exists())

    def test_compiler_failure_preserves_previous_installer_and_removes_staging(self) -> None:
        (self.root / release.SETUP_NAME).write_bytes(b"previous accepted build")
        def fail_compilation(argv: list[str], root: pathlib.Path) -> subprocess.CompletedProcess[bytes]:
            if argv[0] == str(self.compiler):
                raise release.ReleaseError("compiler failed")
            return self.compile(argv, root)
        self.command.side_effect = fail_compilation
        with self.assertRaises(release.ReleaseError):
            self.build()
        self.assertEqual((self.root / release.SETUP_NAME).read_bytes(), b"previous accepted build")
        self.assertEqual(list(self.store.iterdir()), [])

    def test_source_download_failure_does_not_activate_partial_build(self) -> None:
        (self.root / release.SETUP_NAME).write_bytes(b"previous accepted build")
        self.download.side_effect = OSError("network unavailable")
        with self.assertRaises(OSError):
            self.build()
        self.assertEqual((self.root / release.SETUP_NAME).read_bytes(), b"previous accepted build")
        self.assertEqual(list(self.store.iterdir()), [])

    def test_changed_completed_artifact_is_refused_without_rebuilding(self) -> None:
        bundle, _ = self.build()
        (bundle / release.SETUP_NAME).write_bytes(b"changed unexpectedly")
        with self.assertRaisesRegex(release.ReleaseError, "changed after"):
            self.build()
        self.assertEqual(len(self.compiler_calls()), 1)

    def test_wrong_compiler_version_does_not_activate_output(self) -> None:
        def wrong_compiler(argv: list[str], root: pathlib.Path) -> subprocess.CompletedProcess[bytes]:
            if argv[0] == str(self.compiler):
                return subprocess.CompletedProcess([], 0, b"Compiler engine version: Inno Setup 7.1.0", b"")
            return self.compile(argv, root)
        self.command.side_effect = wrong_compiler
        with self.assertRaisesRegex(release.ReleaseError, "pinned"):
            self.build()
        self.assertFalse((self.root / release.SETUP_NAME).exists())
        self.download.assert_not_called()

    def test_only_current_and_two_predecessors_remain(self) -> None:
        current = None
        for number in range(5):
            (self.root / "payload.ahk").write_text(str(number), encoding="utf-8")
            current, _ = self.build()
        self.assertEqual(len([p for p in self.store.iterdir() if p.is_dir()]), 3)
        assert current is not None
        self.assertTrue(current.is_dir())

    def test_orphan_cleanup_keeps_unrelated_directory(self) -> None:
        orphan = self.store / (".staging-" + "a" * 32)
        unrelated = self.store / "unrelated"
        orphan.mkdir()
        unrelated.mkdir()
        with release.locked_store(self.store):
            self.assertFalse(orphan.exists())
            self.assertTrue(unrelated.is_dir())

    def test_second_operation_cannot_share_the_live_store(self) -> None:
        with release.locked_store(self.store):
            with self.assertRaises(release.ReleaseError), release.locked_store(self.store):
                self.fail("A second operation acquired the same store.")

    def test_wildcard_source_is_refused_before_compilation(self) -> None:
        (self.root / release.SETUP_SCRIPT).write_text('[Files]\nSource: "*.ahk"\n', encoding="utf-8")
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
        with mock.patch.object(release, "source_commit", return_value="a" * 40), \
             mock.patch.object(release, "build_store", return_value=self.store), \
             mock.patch.object(release, "compiler_path", return_value=self.compiler), \
             mock.patch.object(sys, "argv", ["release-installer.py", "install", "--repo-root", str(self.root)]), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(release.main(), 1)
        self.assertEqual(self.compiler_calls(), [])

    def test_installation_consumes_completed_build_without_recompilation(self) -> None:
        self.build()
        with mock.patch.object(release, "source_commit", return_value="a" * 40), \
             mock.patch.object(release, "build_store", return_value=self.store), \
             mock.patch.object(release, "compiler_path", return_value=self.compiler), \
             mock.patch.object(sys, "argv", ["release-installer.py", "install", "--repo-root", str(self.root)]), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(release.main(), 0)
        self.assertEqual(len(self.compiler_calls()), 1)
        self.assertEqual(self.command.call_args.args[0][0], str(self.root / release.SETUP_NAME))

    def test_unreadable_snapshot_fails_cleanly_without_an_installer(self) -> None:
        def unreadable_archive(argv: list[str], root: pathlib.Path) -> subprocess.CompletedProcess[bytes]:
            if argv[:2] == ["git", "archive"]:
                return subprocess.CompletedProcess(argv, 0, b"not an archive", b"")
            return self.compile(argv, root)
        self.command.side_effect = unreadable_archive
        with mock.patch.object(release, "source_commit", return_value="a" * 40), \
             mock.patch.object(release, "build_store", return_value=self.store), \
             mock.patch.object(release, "compiler_path", return_value=self.compiler), \
             mock.patch.object(sys, "argv", ["release-installer.py", "build", "--repo-root", str(self.root)]), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(release.main(), 1)
        self.assertFalse((self.root / release.SETUP_NAME).exists())
        self.assertFalse(any(p.name.startswith(".staging-") for p in self.store.iterdir()))


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
        self.record = {"version": "1.0.10", "artifacts": {release.SETUP_NAME: "installer-digest", "source.zip": "source-digest"}}
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
                               "assets": [{"name": release.SETUP_NAME, "state": "uploaded", "digest": "sha256:other"}]}
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


class GitHubResponseTests(unittest.TestCase):
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
