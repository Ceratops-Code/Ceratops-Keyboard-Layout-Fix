# Ceratops Keyboard Layout

![Ceratops Keyboard Layout icon](CeratopsKeyboardLayout.png)

Ceratops Keyboard Layout converts text between US English, Hebrew Standard,
and Russian according to the physical keys used to type it. It also switches
Windows to the chosen keyboard layout.

Download the standalone Windows installer from
[GitHub Releases](https://github.com/Ceratops-Code/Ceratops-Keyboard-Layout-Fix/releases).
The installer includes the AutoHotkey runtime and starts Ceratops when you sign
in. It uses whichever of the supported keyboard layouts are installed in
Windows; missing Hebrew or Russian keyboards do not prevent it from starting.
Before running a downloaded installer, check its immutable release attestation
with GitHub CLI, replacing the tag and filename with the downloaded version:

```powershell
gh release verify-asset v1.0.12 ./CeratopsKeyboardLayout-Setup-1.0.12.exe --repo Ceratops-Code/Ceratops-Keyboard-Layout-Fix
```

Proceed only when the command succeeds. This checks release provenance;
the executable remains unsigned under the signing policy below.
A shortcut for an unavailable target shows a brief message and leaves the
text, selection, clipboard, and active keyboard untouched.
Adding or removing a supported keyboard takes effect on the next conversion
shortcut, without restarting Ceratops. It reads Windows' available-layout list
once per request and reuses its conversion tables unless that list changes.
The installed service checks GitHub every 24 hours and automatically installs a
newer stable release without a confirmation or administrator prompt. Its next
check time survives service and Windows restarts. Missed days cause one check
when the service resumes. **Check for updates** in the tray menu remains
available on demand and reports the result.
Ceratops stays usable during the check and download. The updater checks the
new installer's size and SHA-256 digest before running it, without requesting a
previous release. A download failure leaves the installation unchanged. If
setup fails after it starts, the installation may be incomplete; run the latest
published installer manually. Setup retains the registered installation folder.
Automatic failures are logged and the next attempt is the following day.
A Startup fallback without the service checks at sign-in and asks before an
upgrade. Portable copies do not upgrade the installed app.
Installer filenames include their version, such as
`CeratopsKeyboardLayout-Setup-1.0.12.exe`. Install version 1.0.12 manually when
upgrading from an earlier release. Earlier updaters expect the unversioned filename.
Later automatic updates use the versioned filename for the new installer.
See [the user guide](README.txt) for installation, shortcut behavior,
editor limitations, and removal.

| Default shortcut | Action |
| --- | --- |
| Ctrl+Alt+E | Convert selected text to English |
| Ctrl+Alt+H | Convert selected text to Hebrew |
| Ctrl+Alt+R | Convert selected text to Russian |
| Ctrl+Alt+double E, H, or R | Select all and convert the whole text field |

Left-click or right-click the green tray icon to see installed supported keyboard
languages on the left and combinations in a compact column on the right.
Combinations align at their first character, including custom combinations.
A single left click waits for Windows' double-click interval; right-click opens
immediately.
Choose **Change key combinations...** or double-click the tray icon to open
**Key Combinations**.
Press a combination in each box and save. The checkbox before the Windows
flag and **WinKey +** adds the Windows key; an empty box disables a shortcut.
The checkbox has no drawn caption; its separate screen-reader name is **WinKey**,
so changing display scale cannot expose clipped label fragments beside the flag.
The tray menu shows the app version. Hovering opens no tooltip or popup.
**Force restart Ceratops** restarts the installed service and terminates stuck
tray processes from this installation. The same command is available in the
Start Menu when the tray app itself cannot respond; Windows asks for
administrator permission when needed.
Upgrades use the recovery worker bundled with the new installer to stop stuck
old processes before replacing files, then start the new version automatically.
Operational logs record starts, stops, recovery, upgrades and errors, with no
typing, converted text or routine shortcut activity. Elevated processes write to
`%ProgramData%\CeratopsKeyboardLayoutLogs`; ordinary processes use
`%LocalAppData%\CeratopsKeyboardLayout\Logs`. Each component keeps at most three
1 MiB files.
A closer crop of Trixie's green face fills more of the small icon with visible
artwork, with no keyboard or surrounding padding. Windows controls the tray's
physical icon size; increasing the image's resolution alone does not enlarge it.
The PNG, program icon, tray icon, and
installer use the same artwork.
Settings are shared by this installation, in
`%ProgramData%\CeratopsKeyboardLayout\Shortcuts.ini`. They survive upgrades and
are removed on uninstall. Other running sessions reload them when their tray
menu opens; no background polling is used.

A single tap converts the selection after a 350 ms double-tap decision window
measured from key-down. A second tap within that window selects all and converts
the field immediately. Hold the modifiers between taps. Neither action waits
for key release, and a held key's automatic repeats are ignored. Only one
conversion runs for a double tap, so punctuation is not converted twice.

The source code, installer script, and repository-owned tests are licensed
under [MIT](LICENSE). The bundled AutoHotkey runtime retains its
[GPL-2.0 license](license.txt), and UIA-v2 retains its
[MIT license](Lib/LICENSE.txt). The Ceratops image assets are not included in
the source-code MIT grant.

## Code signing policy

Current releases are unsigned. The project is preparing an application to
[SignPath Foundation](https://signpath.org/); signing is not yet enabled.

The project maintainer, code reviewer, and release-signing approver is
[RomanOstr](https://github.com/RomanOstr), as recorded in
[CODEOWNERS](.github/CODEOWNERS).
All signing-team accounts must use multifactor authentication on GitHub and
SignPath. Every release-signing request will require manual approval.

The intended signing scope is the Ceratops installer built from this repository
on a GitHub-hosted Windows runner. The bundled AutoHotkey runtime is upstream
software; it will not be submitted for a Ceratops signature without an accepted
source-build arrangement. Only the approved signed output will be published
as a signed release. Existing published assets will not be replaced.

If accepted, the project homepage and download pages will display:
"Free code signing provided by [SignPath.io](https://signpath.io/), certificate
by [SignPath Foundation](https://signpath.org/)." Windows will identify SignPath
Foundation as the certificate publisher. This attribution does not claim
that enrollment has already been approved.

## Privacy policy

Text conversion runs locally on your computer. Ceratops does not upload your
text, clipboard contents, or key events to GitHub, SignPath, or the maintainers.
Key combinations are stored locally in the shared settings path described above.

The Windows service contacts GitHub once a day and automatically installs newer
stable releases. Manual checks through **Check for updates** ask before installing.
GitHub receives ordinary connection/request metadata, including your
IP address, the requested release URL, and the
`CeratopsKeyboardLayout-Updater` user-agent. See
[GitHub's privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).
Conversion does not require a network connection.

The installed application does not contact SignPath. If signing is enabled,
maintainers will submit build artifacts and signing requests to that service.
The maintainer application and account are covered by
[SignPath's privacy policy](https://signpath.io/privacy-policy).
For privacy questions, contact the maintainer through the project's
[GitHub profile](https://github.com/RomanOstr).

## Build and release

To build the installer, install the Inno Setup version pinned in
`dependencies.json`. The SDLC package actions `test`, `build`, and `publish`
for `ceratops-keyboard-layout-installer` call the repository-owned release
workflow. It finds the compiler on `PATH` or in its standard Windows installation
directories, builds `CeratopsKeyboardLayout-Setup.iss`, and creates
`CeratopsKeyboardLayout-Setup-<version>.exe` in the current checkout. `AppVersion`
in the installer script owns the version used in its filename, Windows file
details, and release tag. The installer also carries the product description,
Ceratops-Code publisher, copyright, and project/support/update links. These
details do not replace a trusted code signature.
Publishing uses GitHub CLI and attaches both the installer and AutoHotkey's
corresponding GPL source archive. Matching draft uploads resume after interruption;
published assets are never overwritten. The app's SDLC `install` action consumes
the successful build and runs setup silently from an administrator terminal.
Ceratops owns operation selection and order. Shipping selects package publication
before local installation; the repository adapter performs each selected effect.
Building alone does not publish or install it.
The [user guide](README.txt) lists the desktop regression checks.
`sdlc/sdlc.yml` is the operation contract. Ceratops executes its named operations;
`scripts/run-tests.py` owns test selection and result receipts. The repository
test action runs updater checks in CI and adds the interactive Windows suites
locally. The installer package test action runs the existing Python cases through
pytest. CI invokes the same SDLC test actions through the pinned Ceratops action.
Python tooling uses the locked Python 3.14 environment under `scripts`.
`Tests/Test-AppUpdates.ps1` checks release selection, consent, download integrity,
setup failure reporting and cache cleanup without installing software.
