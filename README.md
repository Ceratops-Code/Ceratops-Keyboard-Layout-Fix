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
See [the user guide](README.txt) for installation, shortcut behavior,
editor limitations, and removal.

| Shortcut | Action |
| --- | --- |
| Ctrl+Alt+E | Convert selected text to English |
| Ctrl+Alt+H | Convert selected text to Hebrew |
| Ctrl+Alt+R | Convert selected text to Russian |
| Ctrl+Alt+double E, H, or R | Select all and convert the whole text field |

The source code, installer script, and repository-owned tests are licensed
under [MIT](LICENSE). The bundled AutoHotkey runtime retains its
[GPL-2.0 license](license.txt), and UIA-v2 retains its
[MIT license](Lib/LICENSE.txt). The Ceratops image assets are not included in
the source-code MIT grant.

To build the installer, install the Inno Setup version pinned in
`dependencies.json`. The SDLC package actions `test`, `build`, and `publish`
for `ceratops-keyboard-layout-installer` call the repository-owned release
workflow. It finds the compiler on `PATH` or in its standard Windows installation
directories, builds `CeratopsKeyboardLayout-Setup.iss`, and creates
`CeratopsKeyboardLayout-Setup.exe` in the current checkout.
Publishing uses GitHub CLI and attaches both the installer and AutoHotkey's
corresponding GPL source archive. Matching draft uploads resume after interruption;
published assets are never overwritten. The app's SDLC `install` action consumes
the same successful build and runs setup silently from an administrator terminal.
Building alone does not publish or install it.
The [user guide](README.txt) lists the
desktop regression checks; GitHub CI validates the repository without trying
to run interactive desktop tests on a hosted runner.
