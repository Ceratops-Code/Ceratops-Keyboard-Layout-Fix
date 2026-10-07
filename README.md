# Ceratops Keyboard Layout

![Ceratops Keyboard Layout icon](CeratopsKeyboardLayout.png)

Ceratops Keyboard Layout converts text between US English, Hebrew Standard,
and Russian according to the physical keys used to type it. It also switches
Windows to the chosen keyboard layout.

Download the standalone Windows installer from
[GitHub Releases](https://github.com/Ceratops-Code/Ceratops-Keyboard-Layout-Fix/releases).
The installer includes the AutoHotkey runtime and starts Ceratops when you sign
in. English, Hebrew, and Russian keyboard layouts must already be installed in
Windows. See [the user guide](README.txt) for installation, shortcut behavior,
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

To build the installer, use Inno Setup 6 with
`CeratopsKeyboardLayout-Setup.iss`. The [user guide](README.txt) lists the
desktop regression checks; GitHub CI validates the repository without trying
to run interactive desktop tests on a hosted runner.
