Ceratops Keyboard Layout

Ctrl+Alt+E converts selected text to US English.
Ctrl+Alt+H converts selected text to Hebrew Standard.
Ctrl+Alt+R converts selected text to Russian.
Keep Ctrl+Alt held and tap the same letter twice within 350 ms to select all
and convert the entire field. Holding a letter is not a double tap. A single
tap waits briefly for a possible second tap. With no selection, a single tap
leaves the text alone and still switches the active keyboard layout.

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

Conversion uses the three installed Windows layouts. Shift/capitalization is
preserved between English and Russian; Hebrew letters have no capitals.
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
CeratopsKeyboardLayout-Setup.exe from
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
US English, Hebrew Standard and Russian keyboard layouts must be installed
in Windows separately.

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
The protected Program Files directory owns the scripts, pinned runtime, UIA
dependency, licenses and icon assets. It contains only the current version.
The service starts automatically at Windows boot and owns tray companions for
active desktop sessions; it stops them when removed. The common Startup
shortcut exists only in fallback mode and is owned by the installer. The
source folder also contains the Tests directory.
The project folder owns CeratopsKeyboardLayout-Setup.iss and a local current
standalone setup executable. The setup executable is excluded from Git and
published as a GitHub Release asset. Inno Setup 6's ISCC.exe compiles the
script to a temporary output directory; only a successful build replaces the
local setup executable. Temporary compiler and output files are removed after
the build.
The running utility creates no files, output versions, checkpoints or logs.
Maps and clipboard backups exist in memory and are released after use/exit.
Setup's one-time SYSTEM test task and its XML/result files live in the
installer's temporary directory and are removed immediately after the test.
They do not persist across restarts.
Regression checks create temporary test windows and close them on completion.
They restore the prior foreground window and clipboard where applicable.

Validation
Tests\Test-KeyConversion.ahk exercises the layout maps, list markers, selected
and whole-field conversion, undo, clipboard preservation and deselection.
Tests\Test-AccessibleConversion.ahk checks selected-text accessibility, rich
list clipboard conversion, duplicate-marker prevention, unsafe-rich-copy
refusal, and paste in a background
test field. Tests\Test-ShortcutKeys.ahk exercises single
and double global hotkeys, language changes and focused accessibility Ctrl+A
conversion with toolbar focus recovery and hidden-selection clearing. Run the latter
only after the installed service has stopped and its tray app has exited;
another global listener would invalidate the shortcut check.
The repository's Windows validation runs the key-conversion and accessibility
tests. Run the shortcut test locally from a signed-in desktop after the
installed service has stopped. Run each test with CeratopsKeyboardLayout.exe
/ErrorStdOut=UTF-8 and the test's script path, and wait for the process to exit.

Dependencies
AutoHotkey 2.0.29: https://github.com/AutoHotkey/AutoHotkey/releases/tag/v2.0.29
Its license is in license.txt.
UIA-v2: https://github.com/Descolada/UIA-v2
Its license is in Lib\LICENSE.txt. Exact dependency revisions are recorded
in dependencies.json. The installer requires no Windows keyboard driver or
separate AutoHotkey installation.
