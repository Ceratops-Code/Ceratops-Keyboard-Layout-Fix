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
A shortcut for an unavailable target shows a brief message and leaves the
text, selection, clipboard, and active keyboard untouched.
Adding or removing a supported keyboard takes effect on the next conversion
shortcut, without restarting Ceratops. It reads Windows' available-layout list
once per request and reuses its conversion tables unless that list changes.
At startup, installed copies check GitHub for a newer stable release and ask
before upgrading. **Check for updates** in the tray menu runs the same check
on demand and reports when the app is up to date, with a green check, or the
check fails.
Ceratops stays usable during the check and downloads. The
updater prepares both installers first and restores the previous version if
the new installation fails. Both installers retain the registered installation
folder. Offline startup checks are quiet; portable copies do not
upgrade the installed app.
Installer filenames include their version, such as
`CeratopsKeyboardLayout-Setup-1.0.12.exe`. Install version 1.0.12 manually when
upgrading from an earlier release. Earlier updaters expect the unversioned filename.
Later automatic updates use the versioned filename for both upgrade and recovery.
See [the user guide](README.txt) for installation, shortcut behavior,
editor limitations, and removal.

| Default shortcut | Action |
| --- | --- |
| Ctrl+Alt+E | Convert selected text to English |
| Ctrl+Alt+H | Convert selected text to Hebrew |
| Ctrl+Alt+R | Convert selected text to Russian |
| Ctrl+Alt+double E, H, or R | Select all and convert the whole text field |

Right-click the green tray icon to see the combinations for installed supported
keyboards, with the combinations aligned on the left. Choose **Change key
combinations...** or double-click the tray icon to open **Key Combinations**.
Press a combination in each box and save. The checkbox before the Windows
symbol and **WinKey +** adds the Windows key; an empty box disables a shortcut.
The tray icon has no hover tooltip. Small icon sizes use a close-up face
and simplified keyboard to fill more of the Windows tray slot.
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

The project maintainer and code reviewer is
[RomanOstr](https://github.com/RomanOstr), as recorded in
[CODEOWNERS](.github/CODEOWNERS). RomanOstr is also the proposed release-signing
approver; that role and account security must be confirmed before enrollment.
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

Installed copies contact GitHub when checking for updates at startup or through
**Check for updates**. An upgrade downloads installers from GitHub only after
you agree. GitHub receives ordinary connection/request metadata, including your
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
the same successful build and runs setup silently from an administrator terminal.
Building alone does not publish or install it.
The [user guide](README.txt) lists the desktop regression checks.
`Tests/Test-AppUpdates.ps1` checks release selection, consent, download integrity,
rollback and cache retention without installing software. GitHub CI runs the
same updater and packaging checks; interactive desktop checks run locally.
