Ceratops Keyboard Layout

Ctrl+Alt+E converts selected text to US English.
Ctrl+Alt+H converts selected text to Hebrew Standard.
Ctrl+Alt+R converts selected text to Russian.
Keep Ctrl+Alt held and tap the same letter twice within 350 ms to select all
and convert the entire field. Holding a letter is not a double tap. A single
tap waits for a 350 ms double-tap window measured from key-down. With no selection, a single tap
leaves the text alone and still switches the active keyboard layout.
The second press of a double tap immediately selects all and converts the
field instead. Only one conversion runs, so punctuation is not converted
twice. Neither action waits for key release, even when the keys stay held.

Right-click the green tray icon to see the current combinations for installed
supported keyboards, the single/double-tap explanation, and Change shortcuts...
Press a combination in each box, optionally check Win to add the Windows key,
then Save. Include Ctrl, Alt or Win; leaving a box empty disables that shortcut.
Restore defaults resets the displayed rows. Each combination belongs to one
language. A combination reserved by an absent language's saved shortcut still
needs a different assignment. Cancel leaves the current shortcuts unchanged.
One installation-wide settings file is shared by all accounts. Upgrades keep
the choices; uninstall removes them. A running app in another session reloads
shared changes the next time its tray menu opens. No settings watcher is used.

The keys work by physical keyboard position, not by translation or phonetics.
For example, Hebrew א becomes English t, and Hebrew ד becomes English s.
The double tap sends Ctrl+A to the focused editor and waits for its complete
selection, even when part of the text was already selected. The result is
left unselected. In Codex, Ceratops dismisses the selection formatting toolbar
and restores focus to the editor so its caret remains visible. When an
accessibility editor's full text needs no conversion, Ceratops skips Ctrl+A
and clears any typing selection. In Codex it sends a real Right key because
the editor can report a caret while retaining a hidden selection.
Already-target-language letters, whitespace, numbers and unmapped
characters such as emoji are preserved. Symbols that move between the
layouts convert by physical key too: Hebrew / becomes English q, and Hebrew
' becomes English w. Nearby letters identify a symbol's source layout; for
symbol-only text, the active keyboard layout is used. A symbol typed under a
different past layout cannot always be identified from the character alone.
List markers at the start of a line, such as 1. and -, stay unchanged when
followed by whitespace or line end while the item's text converts. In an
accessibility-based rich editor, Ceratops copies the editor's HTML fragment,
changes its text while retaining list and inline-formatting tags, and pastes
both rich and plain forms. When only words inside one list item are selected,
it removes the clipboard's generated list wrapper before pasting into the
existing item, so the bullet is not duplicated. If that wrapper is unusual,
it pastes plain converted words inside the item to keep the list structure.
If a rich editor provides no usable HTML copy, conversion stops.

Conversion uses whichever supported Windows layouts are currently available.
The app still starts when Hebrew, Russian, or US English is absent. Only
installed layouts participate in conversion. A shortcut for a missing target
shows a brief message without selecting text, changing it, touching the
clipboard, or switching the keyboard. Text and symbols from an absent source
layout are preserved. Adding or removing a keyboard takes effect on the next
shortcut without restarting Ceratops. Each conversion request reads Windows'
layout list once before touching the editor or clipboard. Conversion tables
stay cached unless that list changes; order and duplicate entries do not cause
a rebuild. A changed list produces a complete replacement cache before it is
used. A failed query stops that conversion without changing text, selection,
clipboard or active keyboard. No background polling or watcher is used.
Shift/capitalization is preserved between English and Russian; Hebrew letters
have no capitals.
Text is processed only in memory, without network requests or saved text logs.
The clipboard is preserved unless the user copies something new concurrently.

Plain text fields, Notepad++/Scintilla editors, and editors exposing a Windows
accessibility text selection are supported. Multiple or rectangular Scintilla
selections, password, read-only and unsupported fields are refused with a
short tooltip. Rich-content preservation depends on the editor supplying a
valid Windows HTML clipboard fragment and accepting it on paste. Selections
with embedded media are refused because their non-HTML data may be required.
Applications
running as administrator cannot be
controlled by an ordinary Startup instance. The installed service launches an
elevated tray instance for administrator accounts, so their elevated editors
are supported. A standard account gets an ordinary tray instance.
The shortcuts do not make an unsupported custom editor compatible: a caret or
clipboard copy alone cannot prove that Ctrl+A selected its text.

To install on another 64-bit Windows PC, download
CeratopsKeyboardLayout-Setup-<version>.exe (for example,
CeratopsKeyboardLayout-Setup-1.0.12.exe) from
https://github.com/Ceratops-Code/Ceratops-Keyboard-Layout-Fix/releases
and run it. The standalone installer includes
the runtime and dependencies. It asks for administrator approval once and
installs to Program Files\CeratopsKeyboardLayout with a Start Menu entry.
Before creating its automatic LocalSystem service, setup runs a temporary
SYSTEM task to test whether it can launch an elevated tray app in the active
desktop session. If the test and service start succeed, the service starts
with Windows and launches the tray app at sign-in without another UAC prompt.
If either fails, setup adds a common Startup shortcut that launches the
ordinary tray app at each sign-in. Setup also starts it immediately under
the original user token when available. After sign-in, that fallback cannot
edit administrator-run apps. Remove the installation through Windows
Settings > Apps. Uninstall stops and removes the service or Startup shortcut.
Uninstall an older per-user version first if one exists, to avoid two copies.
Install the Windows keyboard layouts you want to use separately; the
installer does not add languages or require all supported keyboards.

Updates
Version 1.0.12 introduces versioned installer filenames. Install it manually
when upgrading from an earlier release, whose updater expects the previous
filename. Later automatic updates use versioned installers for both the new
version and recovery.
Each start of an installed tray app checks the public GitHub Releases API for
a newer stable version and asks whether to upgrade. No account is needed.
Choosing No keeps the current version; the next normal start checks again.
An offline or unavailable GitHub API does not interrupt the app or show errors.
Only the registered installed copy checks; unpacked source copies skip it.
The check sends no text or clipboard content to GitHub.

Choosing Yes starts a separate Windows PowerShell helper. A normally launched
tray app requests administrator approval once for installation; an already
elevated tray app does not need another prompt. The helper downloads both the
new installer and the published installer for the currently installed version
from this repository. Both must match GitHub's SHA-256 digest and byte count
before installation starts. It holds their accepted files against writes and
deletion through setup and recovery. If either package cannot be obtained,
it reports Upgrade failed and leaves the running version untouched.

Hotkeys continue working during checks/downloads and pause briefly while setup
replaces the app and restarts its service or Startup fallback. If new setup
fails or registers the wrong version, the helper runs the previous installer
and reports Upgrade failed. If Windows also prevents recovery, it reports that
separately and gives the saved previous installer's path for manual recovery.
Automatic recovery cannot guarantee success against disk or Windows failures.
Setup's immediate restart skips the update prompt; later starts check normally.

To run the unpacked copy instead, launch CeratopsKeyboardLayout.exe with
CeratopsKeyboardLayout.ahk as its argument.
CeratopsKeyboardLayout.exe embeds the Trixie icon from
CeratopsKeyboardLayout.ico. The archive_sha256 in dependencies.json identifies
the original upstream release archive, before the installed executable's icon
and display metadata were customized. The executable still runs the
AutoHotkey engine and retains its upstream license.
Right-click its Trixie-with-a-keyboard tray icon and choose
Exit Ceratops Keyboard Layout to stop it.
The tray menu omits AutoHotkey tools such as Window Spy, which this portable
installation does not include.

Storage and lifecycle
Manage-KeyboardShortcuts.ahk owns
%ProgramData%\CeratopsKeyboardLayout\Shortcuts.ini. Setup creates this data-only
folder with local-user write access; Program Files remains protected. Settings
are read at app start and when its tray menu or settings dialog opens. Save
checks all assignments, stages the new file and atomically replaces the current
file; a failed save restores the previous live shortcuts. Under an exclusive
delete-on-close Shortcuts.ini.lock, startup and each save remove an orphaned
Shortcuts.ini.pending. Successful saves leave only the current INI, with no
history or logs. Symbolic links/junctions are refused so the elevated app cannot
write through user-substituted paths. Settings are data, never executable code.
Uninstall removes these exact settings files and the directory if it is empty.
The protected Program Files directory owns the scripts, pinned runtime, UIA
dependency, licenses and icon assets. It contains the current application
version and, during updates, the protected UpdateCache subdirectory.
The service starts automatically at Windows boot and owns tray companions for
active desktop sessions; it stops them when removed. The common Startup
shortcut exists only in fallback mode and is owned by the installer. The
source folder also contains the Tests directory.
The project folder owns CeratopsKeyboardLayout-Setup.iss and versioned
standalone setup executables. AppVersion in that script owns their filename,
Windows file/product version, and release tag. Publisher, description,
copyright and project/support/update links are installer metadata; a trusted
code signature is separate. Setup executables are excluded from Git and
published as a GitHub Release asset. SDLC calls scripts\release-installer.py
for build, publication and installation. The Inno Setup version is pinned in
dependencies.json. The helper finds ISCC.exe on PATH or in its standard Windows
installation directories. It compiles CeratopsKeyboardLayout-Setup.iss into a
private staging bundle and obtains the checksum-pinned AutoHotkey source ZIP.
Only successful bundles replace the current version's setup executable.
Each checkout keeps that installer and at most two predecessors. At startup
and after activation the helper prunes this versioned output group, removes
abandoned atomic-copy files, and leaves unrelated files untouched.
The primary checkout's .build\installer directory owns one lock and at most
three completed build bundles. Packaging bytes and compiler identity identify
each bundle; changing only tests or CI does not rebuild an accepted installer.
Each bundle contains the installer, GPL source ZIP and its build receipt.
At startup the owning helper removes abandoned staging bundles under its lock;
after each build or reuse it prunes all but the current bundle and two others.
It removes private staging and atomic-copy files after success or failure and
creates no operational history. Failed compilation leaves the previous setup.
Publication requires a successful current build and authenticated GitHub CLI.
It resumes matching draft uploads, checks the tag's source commit and uploaded
checksums, and publishes only after both required assets are present. Published
release assets are never replaced or deleted; each keeps its version identity.
The app's SDLC install action consumes that successful build, runs setup silently,
and requires an administrator terminal. Building does not install or publish it.
The conversion code creates no files or text logs. Maps and clipboard backups
exist in memory and are released after use/exit.
Update-AppInstall.ps1 owns UpdateCache beside the installed scripts. Under a
machine-wide upgrade lock it creates a unique attempt directory for the two
installers. At helper startup it removes abandoned attempts and retains only
the newest failed-recovery attempt while preparing the new one. On completion
it deletes downloads and temporary attempts; if recovery fails, it keeps only
that attempt's previous installer and an error record limited to 8 KiB. Later
successful installation removes that recovery copy. Uninstall removes the
owned cache. There are no update history logs. Links and unrelated directories
are left untouched; cleanup failures are reported instead of hiding the
installation outcome. A session-wide check lock prevents duplicate prompts.
Setup's one-time SYSTEM test task and its XML/result files live in the
installer's temporary directory and are removed immediately after the test.
They do not persist across restarts.
Regression checks create temporary test windows and close them on completion.
They restore the prior foreground window and clipboard where applicable.
Tests\test_installer_release.py checks build failure preservation, cache reuse,
bounded retention, upload interruption, and published-asset protection without
installing software or accessing GitHub. Local SDLC and GitHub CI run the same
test entrypoint. Its private test files are removed from the caller-selected
task temp root, or the repository parent's tmp project test directory.
Tests\Test-AppUpdates.ps1 uses the same temporary-file ownership: each run
creates one private directory under the caller's -TempRoot and removes it on
completion. Its default is the repository parent's tmp project test directory.

Checks
Tests\Test-AppUpdates.ps1 exercises version ordering, stable release assets,
upgrade consent, offline checks, checksums, download limits, preparation
failures, recovery, concurrent installation and bounded cache retention.
On Windows it also checks file locks, executable launch under a read lock,
cache junction refusal and busy/abandoned update locks. It substitutes HTTP
and installer boundaries and never installs software or changes a service.
Run it with powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File
Tests\Test-AppUpdates.ps1, optionally passing -TempRoot for its private files.
Tests\Test-KeyConversion.ahk exercises the layout maps, every installed-layout
subset, live additions/removals, unchanged-cache reuse, failed layout queries,
shortcut parsing and shared settings, failed-save recovery, tap timing,
list markers, selected and whole-field conversion, undo, clipboard
preservation and deselection. The test PC needs all supported layouts to
exercise real Win32 key output; subset checks simulate missing keyboards.
Tests\Test-AccessibleConversion.ahk checks selected-text accessibility, rich
list clipboard conversion, duplicate-marker prevention, unsafe-rich-copy
refusal, and paste in a background
test field. Tests\Test-ShortcutKeys.ahk exercises single
and double global hotkeys, settings capture, held modifiers, language changes and focused accessibility Ctrl+A
conversion with toolbar focus recovery and hidden-selection clearing. Run the latter
only after the installed service has stopped and its tray app has exited;
another global listener would invalidate the shortcut check.
GitHub CI runs repository, packaging and portable updater checks. Run the SDLC test operation on a signed-in
Windows desktop for the key-conversion and accessibility checks. Run the
shortcut test there after the installed service has stopped. Run each test
with CeratopsKeyboardLayout.exe
/ErrorStdOut=UTF-8 and the test's script path, and wait for the process to exit.
Pass a caller-owned task temp root as the shortcut test's first argument; the
key-conversion suite also accepts that argument for its settings fixture.
Their private settings files are removed on completion. The default for the
key-conversion suite is the repository parent's tmp project test directory.
Windows must be unlocked for accessibility and foreground shortcut checks.

Dependencies
The Ceratops source code and installer script use the MIT license in LICENSE.
This does not change the bundled dependencies' licenses.
AutoHotkey 2.0.29: https://github.com/AutoHotkey/AutoHotkey/releases/tag/v2.0.29
Its license is in license.txt.
Its corresponding source is at
https://github.com/AutoHotkey/AutoHotkey/archive/refs/tags/v2.0.29.zip.
UIA-v2: https://github.com/Descolada/UIA-v2
Its license is in Lib\LICENSE.txt. Exact dependency revisions are recorded
in dependencies.json. The installer requires no Windows keyboard driver or
separate AutoHotkey installation.
