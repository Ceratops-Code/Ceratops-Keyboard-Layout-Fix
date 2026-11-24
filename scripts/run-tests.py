#!/usr/bin/env python3
"""Run SDLC's repository or installer tests with Ceratops result receipts.

Use the locked scripts environment: uv run --project scripts --locked python scripts/run-tests.py.
Ceratops supplies result identities and input scope. The generated
write_check_results module appends outcomes and compacts them at command boundaries.
Without result arguments this remains a disposable test invocation. The running
record is completed only by its owning invocation; a fresh invocation never
overwrites a valid failed or interrupted attempt. CI runs the noninteractive
updater suite; a local Windows run also requires the desktop suites. The installer
suite uses pytest to preserve the existing unittest cases.

The caller may select the shared temporary base with CERATOPS_TASK_TEMP_ROOT.
Otherwise the base is <repo-parent>/tmp. Scratch always adds
<repo-name>/<checkout-name> beneath that base. Pytest owns its numbered scratch,
retaining the current run and two predecessors and pruning abandoned outputs
without deleting live runs. The updater suite owns and removes its private
subdirectory. Bytecode and pytest's persistent cache are disabled. Final result
receipts remain caller-owned; this runner never invents history paths.
"""

from __future__ import annotations

import argparse
import errno
import json
import os
import pathlib
import platform
import shlex
import shutil
import subprocess
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_TARGETS = ['Tests/test_installer_release.py']
DESKTOP_TESTS: tuple[tuple[str, str, list[str]], ...] = (
    ("key-conversion", "Tests/Test-KeyConversion.ahk", []),
    ("shortcut-dispatch", "Tests/Test-ShortcutKeys.ahk", ["--dispatch-only"]),
    ("accessible-conversion", "Tests/Test-AccessibleConversion.ahk", []),
)
def without_basetemp(arguments: list[str]) -> list[str]:
    """Remove inherited locations before pytest validates every occurrence."""
    options = iter(arguments)
    retained = []
    for option in options:
        if option == "--basetemp":
            next(options, None)
        elif not option.startswith("--basetemp="):
            retained.append(option)
    return retained


sys.path.insert(0, str(ROOT / "scripts"))
from write_check_results import (  # noqa: E402
    CHECK_CONTEXT_ENV,
    add_result_arguments,
    describe_result_contract,
    run_recorded_check,
)


def execution_profile(suite: str) -> str:
    """Keep CI acceptance distinct from the mandatory local desktop outcome."""
    if suite == "installer":
        return "installer"
    if os.environ.get("CI"):
        return "ci"
    if platform.system() != "Windows":
        raise ValueError("Local repository tests require a signed-in Windows desktop.")
    return "desktop"


def task_temp_root() -> pathlib.Path:
    """Add repository and checkout identity to the shared temporary base.

    Git identifies the primary repository even from a linked worktree. Resolve
    that identity before any scratch writes so a configured base cannot bypass
    project isolation or send different checkouts to the same pytest directory.
    """
    command = ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError(child_failure(command, result.returncode, result.stdout, result.stderr))
    primary = pathlib.Path(result.stdout.strip()).parent
    selected = os.environ.get("CERATOPS_TASK_TEMP_ROOT")
    base = pathlib.Path(selected).absolute() if selected else primary.parent / "tmp"
    return base / primary.name / ROOT.name


def child_failure(command: list[str], status: int | str, stdout: str, stderr: str) -> str:
    """Keep the exact runtime/argv, exit status and both streams on failure."""
    return (f"Command: {json.dumps(command)}\nExit status: {status}\n"
            f"stdout:\n{stdout or '<absent>'}\nstderr:\n{stderr or '<absent>'}")


def test_commands(
    args: argparse.Namespace, targets: list[str], temporary: pathlib.Path,
) -> list[tuple[str, list[str]]]:
    """Own framework and desktop task selection for both CI and local SDLC."""
    if args.probe_command is not None:
        return [("compatibility-probe", args.probe_command)]
    if args.suite == "installer":
        for target in targets:
            path = (ROOT / target.split("::", 1)[0]).resolve()
            if not path.is_relative_to(ROOT) or not path.exists():
                raise ValueError(f"test target must exist inside this repository: {target}")
        return [("installer", [
            sys.executable, "-m", "pytest", *targets, *without_basetemp(args.pytest_arg),
            "-p", "no:cacheprovider", "-o", "tmp_path_retention_policy=none",
        ])]
    powershell = shutil.which("pwsh")
    if powershell is None:
        raise ValueError("Repository tests require PowerShell Core (pwsh), declared in SDLC.")
    commands = [("updater", [
        powershell, "-NoProfile", "-NonInteractive", "-File",
        str(ROOT / "Tests/Test-AppUpdates.ps1"), "-TempRoot", str(temporary),
    ])]
    if args.profile == "desktop":
        commands.extend((name, [str(ROOT / "CeratopsKeyboardLayout.exe"),
                               "/ErrorStdOut=UTF-8", str(ROOT / path), *options])
                        for name, path, options in DESKTOP_TESTS)
    return commands


def execute_check(
    args: argparse.Namespace, targets: list[str], inherited: list[str], checks: list[dict[str, Any]],
) -> int:
    """Stop at the first failed effect and retain each actual suite outcome."""
    temporary = task_temp_root()
    commands = test_commands(args, targets, temporary)
    temporary.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.pop(CHECK_CONTEXT_ENV, None)
    environment.pop("PYTHONPYCACHEPREFIX", None)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["PYTEST_DEBUG_TEMPROOT"] = str(temporary)
    environment["PYTEST_ADDOPTS"] = shlex.join(inherited)
    for name, command in commands:
        try:
            result = subprocess.run(command, cwd=ROOT, env=environment, check=False,
                                    capture_output=True, text=True, encoding="utf-8", errors="replace")
            code = result.returncode if result.returncode >= 0 else 1
        except KeyboardInterrupt:
            checks.append({"name": name, "status": "interrupted", "exit_code": 130})
            print(child_failure(command, "interrupted", "", ""), file=sys.stderr)
            raise
        except OSError as error:
            code = 127
            result = subprocess.CompletedProcess(command, code, "", f"{type(error).__name__}: {error}")
        finally:
            if name == "installer":
                # Pytest removes its numbered runs, leaving their empty parent.
                for parent in temporary.glob("pytest-of-*"):
                    if not parent.is_dir() or parent.is_symlink() or parent.is_junction():
                        continue
                    try:
                        parent.rmdir()
                    except FileNotFoundError:
                        continue
                    except OSError as error:
                        if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
                            print(f"Cannot remove pytest scratch parent {parent}: {error}", file=sys.stderr)
        checks.append({"name": name, "status": "passed" if code == 0 else "failed", "exit_code": code})
        if code:
            print(child_failure(command, result.returncode, result.stdout, result.stderr), file=sys.stderr)
            return code
    if args.profile == "ci":
        checks.append({"name": "desktop-interaction", "status": "not_applicable",
                       "reason": "Interactive Windows suites run locally before release."})
    print("OK")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("targets", nargs="*", help="Repository-relative test files or directories.")
    parser.add_argument("--suite", choices=("repository", "installer"), default="repository")
    parser.add_argument("--pytest-arg", action="append", default=[], help="Repeat using --pytest-arg=VALUE.")
    add_result_arguments(parser)
    args = parser.parse_args(argv)
    if args.describe_test_results:
        describe_result_contract()
        return 0
    try:
        if args.probe_command is not None:
            args.probe_command = json.loads(args.probe_command)
            if (not isinstance(args.probe_command, list) or not args.probe_command
                    or any(not isinstance(item, str) or "\0" in item for item in args.probe_command)
                    or not args.probe_command[0]):
                raise ValueError("probe-command must be a nonempty JSON argv")
        inherited = without_basetemp(shlex.split(os.environ.get("PYTEST_ADDOPTS", "")))
        targets = args.targets or DEFAULT_TARGETS
        if args.suite != "installer" and (args.targets or args.pytest_arg):
            raise ValueError("Python test targets and pytest arguments require --suite installer.")
        args.profile = "probe" if args.probe_command else execution_profile(args.suite)
        invocation = {
            "targets": targets if args.suite == "installer" and not args.probe_command else [],
            "pytest_args": [] if args.probe_command else without_basetemp(args.pytest_arg),
            "pytest_addopts": [] if args.probe_command else inherited,
            "probe_command": args.probe_command,
        }
        # Compatibility probes use the unextended shared protocol. Actual test
        # receipts also bind their selected suite and CI/desktop scope.
        if args.probe_command is None:
            invocation.update({"suite": args.suite, "profile": args.profile})
        checks: list[dict[str, Any]] = []
        return run_recorded_check(lambda: execute_check(args, targets, inherited, checks), args, invocation,
                                  checks=(lambda: checks) if args.probe_command is None else None, repo_root=ROOT)
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
