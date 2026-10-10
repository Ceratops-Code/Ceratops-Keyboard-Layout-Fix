#Requires AutoHotkey v2.0.19+
#Include ..\CeratopsKeyboardLayout.ahk
originalWindow := WinExist("A")
Codes(value) {
    result := ""
    Loop Parse value
        result .= Format("{:04X}", Ord(A_LoopField)) " "
    return result
}
class CodexLikeTextField extends AccessibleTextField {
    IsCodexEditor() => true
    Copy() {
        super.Copy()
        if !ClipWait(1)
            throw Error("The rich fixture did not copy its selection.")
        parts := {before: "<html><body><!--StartFragment-->",
            after: "<!--EndFragment--></body></html>"}
        html := RichClipboard.Build(parts, "<p>" A_Clipboard "</p>")
        sequence := DllCall("GetClipboardSequenceNumber", "UInt")
        RichClipboard.Write(A_Clipboard, html, &sequence)
    }
}
class NoInstalledLayouts extends KeyboardConverter {
    __New() => super.__New([])
    ReadInstalledLayoutHandles() => []
}
DismissToolbar(*) {
    global toolbar, toolbarControl
    toolbar.open := false
    toolbar.dismissals += 1
    toolbarControl.Focus()
}
SendDoubleShortcut(key) {
    ; Keep both modifiers down across the two distinct key presses.
    SendTestKeys("{Blind}{Ctrl DownR}{Alt DownR}{vk" key "}")
    Sleep(80)
    SendTestKeys("{Blind}{vk" key "}{Alt up}{Ctrl up}")
}
SendTestKeys(keys, targetWindow := 0) {
    global fixture
    if !targetWindow
        targetWindow := fixture.Hwnd
    ; Closing the settings dialog can restore its previous foreground window
    ; asynchronously. Never let a delayed activation send input into user work.
    if !WinActive("ahk_id " targetWindow)
        throw Error("Desktop shortcut check interrupted: the test window lost focus before input.")
    ; Exercise AHK's real hooks with input above their level. The converter's
    ; own level-zero sends must never recursively trigger configured shortcuts.
    priorLevel := A_SendLevel
    SendLevel(1)
    try SendEvent(keys)
    finally SendLevel(priorLevel)
}
try {
    if !WinExist("A")
        throw Error("The interactive desktop is unavailable. Unlock Windows before running this check.")
    ; AutoHotkey's hidden window title starts with the full script path.
    SetTitleMatchMode(2)
    DetectHiddenWindows(true)
    ; Match the running script name at either the project or installed path.
    ; Two global listeners make synthetic shortcut results meaningless.
    if WinExist("CeratopsKeyboardLayout.ahk ahk_class AutoHotkey")
        throw Error("Stop the Ceratops service and wait for its tray app to exit before testing hotkeys.")
    if !A_Args.Length
        throw Error("Supply the caller-owned task temp root as the first argument.")
    settingsDirectory := A_Args[1] "\shortcut-desktop-" DllCall("GetCurrentProcessId")
    settings := KeyboardShortcutSettings(settingsDirectory "\Shortcuts.ini")
    shortcuts := KeyboardShortcutManager(Converter, settings)
    shortcuts.Start()
    if DllCall("GetMenuItemCount", "Ptr", A_TrayMenu.Handle) != Converter.Layouts.Count + 7
        throw Error("Tray menu does not show the installed languages and shortcut help")
    shortcuts.ShowSettings()
    if shortcuts.Controls.Count != Converter.Layouts.Count
        throw Error("Settings dialog shows a keyboard that is not installed")
    for name, control in shortcuts.Controls {
        control.Hotkey.Focus()
        SendTestKeys("^!{F9}", shortcuts.Dialog.Hwnd)
        if KeyboardShortcutSettings.Parse(control.Hotkey.Value).Hotkey != "^!vk78"
            throw Error("Configured shortcut was intercepted instead of captured in the settings box")
        control.Hotkey.Value := KeyboardShortcutSettings.Parse(shortcuts.Assignments[name]).Control
    }
    shortcuts.Controls["en"].Hotkey.Value := "^+F8"
    shortcuts.SaveDialog()
    if shortcuts.Dialog
        throw Error("Settings dialog could not save: " shortcuts.Status.Text)
    if settings.Load()["en"] != "^+vk77"
        throw Error("Custom shortcut was not saved to the shared preference file")
    fixture := Gui(, "Keyboard shortcut test")
    toolbar := {open: false, dismissals: 0}
    fixture.OnEvent("Escape", DismissToolbar)
    inputControl := fixture.AddEdit("w420 r3", "שלום")
    toolbarControl := fixture.AddEdit("ReadOnly w120", "Formatting toolbar")
    fixture.Show()
    WinActivate("ahk_id " fixture.Hwnd)
    inputControl.Focus()
    if !WinWaitActive("ahk_id " fixture.Hwnd, , 2)
        throw Error("Test editor did not become active; foreground=" WinGetProcessName("A")
            " class=" WinGetClass("A") " fixture-visible=" DllCall("IsWindowVisible", "Ptr", fixture.Hwnd))
    Sleep(150)
    ; Wait for the dialog-close focus handoff before activating the fixture.
    WinActivate("ahk_id " fixture.Hwnd)
    if !WinWaitActive("ahk_id " fixture.Hwnd, , 2)
        throw Error("The test editor could not regain foreground focus.")
    editorThread := DllCall("GetWindowThreadProcessId", "Ptr", inputControl.Hwnd, "Ptr", 0, "UInt")
    priorLayout := DllCall("GetKeyboardLayout", "UInt", editorThread, "Ptr")
    ; A single tap's decision window starts at key-down, while both modifiers
    ; and the key remain held. No key-up is sent until after the assertion.
    SendMessage(0xB1, 0, StrLen(inputControl.Value), inputControl.Hwnd)
    ; DownR models physical modifiers: the converter may release them around
    ; Ctrl+A/C/V and AHK restores them after each send.
    SendTestKeys("{Ctrl DownR}{Shift DownR}{F8 down}")
    deadline := A_TickCount + 1000
    while inputControl.Value != "akuo" && A_TickCount < deadline {
        if !WinActive("ahk_id " fixture.Hwnd)
            throw Error("Held-key shortcut check interrupted: another window took focus.")
        Sleep(10)
    }
    if inputControl.Value != "akuo"
        throw Error("Saved shortcut did not convert while its keys were still held: text="
            Codes(inputControl.Value) " latch=" shortcuts.HeldKeys.Has("vk77")
            " pending=" IsObject(shortcuts.Pending) " active=" WinGetProcessName("A")
            " Ctrl=" GetKeyState("Ctrl") " Shift=" GetKeyState("Shift"))
    ; The hook suppresses F8, so its logical Windows state stays up. Its latch
    ; proves no key-up reached the listener before the conversion completed.
    if !GetKeyState("Ctrl") || !GetKeyState("Shift") || !shortcuts.HeldKeys.Has("vk77")
        throw Error("Held-modifier check did not keep the invoking keys down")
    SendTestKeys("{F8 up}{Shift up}{Ctrl up}")
    shortcuts.Apply(KeyboardShortcutSettings.Defaults())
    inputControl.Value := "שלום"
    expectedText := Map("en", "akuo", "he", "שלום", "ru", "флгщ")
    for target, layout in Converter.Layouts {
        language := KeyboardConverter.Languages[target]
        key := SubStr(language.Key, 3)
        expected := expectedText[target]
        WinActivate("ahk_id " fixture.Hwnd)
        inputControl.Focus()
        if !WinWaitActive("ahk_id " fixture.Hwnd, , 2)
            throw Error("Test editor lost focus before shortcut to " WinGetProcessName("A")
                " (window " WinExist("A") ", fixture " fixture.Hwnd ")")
        if ControlGetFocus("ahk_id " fixture.Hwnd) != inputControl.Hwnd
            throw Error("Test text control is not focused")
        SendDoubleShortcut(key)
        deadline := A_TickCount + 3000
        while ((inputControl.Value != expected
            || (DllCall("GetKeyboardLayout", "UInt", editorThread, "Ptr") & 0xFFFF) != language.LanguageId)
            && A_TickCount < deadline) {
            if !WinActive("ahk_id " fixture.Hwnd)
                throw Error("Desktop shortcut check interrupted: another window took focus.")
            Sleep(25)
        }
        if !(inputControl.Value == expected)
            throw Error("Shortcut " key ": expected " Codes(expected)
                ", got " Codes(inputControl.Value) ", language "
                Format("{:04X}", DllCall("GetKeyboardLayout", "UInt", editorThread, "Ptr") & 0xFFFF)
                ", foreground " WinGetProcessName("A"))
        if (DllCall("GetKeyboardLayout", "UInt", editorThread, "Ptr") & 0xFFFF) != language.LanguageId
            throw Error("Shortcut " key " did not select its keyboard layout")
        field := NativeTextField(fixture.Hwnd, inputControl.Hwnd)
        selection := field.Selection()
        if selection[1] != selection[2]
            throw Error("Shortcut left text selected")
        if !WinActive("ahk_id " fixture.Hwnd)
            throw Error("Shortcut moved focus away from test editor")
        WinActivate("ahk_id " fixture.Hwnd)
        inputControl.Focus()
        if !WinWaitActive("ahk_id " fixture.Hwnd, , 2)
            throw Error("Test editor lost focus before repeated shortcut")
        SendTestKeys("^!{vk" key "}")
        focusAfterSend := WinGetProcessName("A")
        ; Allow the editor to settle before checking its selection and focus.
        Sleep(450)
        if !WinActive("ahk_id " fixture.Hwnd)
            throw Error("Repeated shortcut " key " check lost test editor focus to "
                WinGetProcessName("A") " (immediately after send: " focusAfterSend ")")
        if inputControl.Value != expected
            throw Error("Single shortcut without a selection changed text: " Codes(inputControl.Value))
        selection := field.Selection()
        if selection[1] != selection[2]
            throw Error("Single shortcut " key " left text selected "
                selection[1] "-" selection[2])
    }
    inputControl.Value := "prefix שלום suffix"
    inputControl.Focus()
    SendMessage(0xB1, 7, 11, inputControl.Hwnd)
    SendTestKeys("^!{vk45}")
    deadline := A_TickCount + 3000
    while inputControl.Value != "prefix akuo suffix" && A_TickCount < deadline {
        if !WinActive("ahk_id " fixture.Hwnd)
            throw Error("Selected-text shortcut check interrupted: another window took focus.")
        Sleep(25)
    }
    if inputControl.Value != "prefix akuo suffix"
        throw Error("Single E did not convert only the selection: " Codes(inputControl.Value))
    field := NativeTextField(fixture.Hwnd, inputControl.Hwnd)
    selection := field.Selection()
    if selection[1] != selection[2]
        throw Error("Single E left its text selected")
    ; A missing target must be refused before Ctrl+A, clipboard access or an
    ; input-language change. Keep the person's actual keyboards untouched.
    completeConverter := Converter
    try {
        Converter := NoInstalledLayouts()
        inputControl.Value := "unchanged text"
        SendMessage(0xB1, 2, 5, inputControl.Hwnd)
        clipboardSequence := DllCall("GetClipboardSequenceNumber", "UInt")
        activeLayout := DllCall("GetKeyboardLayout", "UInt", editorThread, "Ptr")
        for target in KeyboardConverter.Languages {
            ConvertOneFocusedText(target, fixture.Hwnd, "all")
            ToolTip()
            selection := field.Selection()
            if inputControl.Value != "unchanged text" || selection[1] != 2 || selection[2] != 5
                throw Error("Unavailable target changed the editor text or selection")
            if DllCall("GetClipboardSequenceNumber", "UInt") != clipboardSequence
                throw Error("Unavailable target accessed the clipboard")
            if DllCall("GetKeyboardLayout", "UInt", editorThread, "Ptr") != activeLayout
                throw Error("Unavailable target switched the keyboard")
        }
    } finally {
        Converter := completeConverter
    }
    ; The fixture is already foreground for the shortcut check. Exercise the
    ; accessibility path here so its Ctrl+A cannot steal focus during a
    ; separate background test.
    inputControl.Value := "שלום /"
    inputControl.Focus()
    SendMessage(0xB1, StrLen(inputControl.Value), StrLen(inputControl.Value), inputControl.Hwnd)
    UIA.ElementFromHandle(fixture.Hwnd)
    richField := CodexLikeTextField(fixture.Hwnd, UIA.GetFocusedElement())
    toolbar.open := true
    try richField.Convert("en", "he", "all")
    catch Error as failure {
        selected := richField.GetRange()
        throw Error(failure.Message " current=" Codes(inputControl.Value)
            " selection-length=" StrLen(selected.GetText())
            " editor-focus=" richField.HasFocus())
    }
    if inputControl.Value != "akuo q"
        throw Error("Accessibility Ctrl+A changed the wrong text: " Codes(inputControl.Value))
    if richField.GetRange().CompareEndpoints("Start", richField.GetRange(), "End") != 0
        throw Error("Accessibility Ctrl+A left text selected")
    if toolbar.open || toolbar.dismissals != 1
        throw Error("Conversion did not dismiss the selection toolbar")
    if !richField.HasFocus() || ControlGetFocus("ahk_id " fixture.Hwnd) != inputControl.Hwnd
        throw Error("Conversion left focus on the read-only formatting toolbar")
    ; A following shortcut must find the editor, never the read-only toolbar.
    nextField := FocusedTextField(fixture.Hwnd)
    SendMessage(0xB1, 0, StrLen(inputControl.Value), inputControl.Hwnd)
    nextField.Convert("he", "en", "selected")
    if inputControl.Value != "שלום /"
        throw Error("Immediate second conversion failed: " Codes(inputControl.Value))
    richField.Convert("he", "he", "all")
    if inputControl.Value != "שלום /"
        throw Error("Repeated accessibility conversion changed text")
    if richField.GetRange().CompareEndpoints("Start", richField.GetRange(), "End") != 0
        throw Error("Repeated accessibility conversion left text selected")
    if !richField.HasFocus()
        throw Error("No-op conversion hid the editor caret")
    try FileAppend("PASS shortcut settings/capture, held modifiers, single/double hotkeys, unavailable targets and 2 accessibility conversions`n", "*")
    code := 0
} catch Error as failure {
    try FileAppend("FAIL: " failure.Message "`n", "*")
    code := 1
} finally {
    ; Always release synthetic input, including when a held-key assertion fails.
    try {
        SendLevel(1)
        SendEvent("{Blind}{F8 up}{Shift up}{vk45 up}{Alt up}{Ctrl up}")
    }
    try DllCall("PostMessageW", "Ptr", inputControl.Hwnd, "UInt", 0x50,
        "UPtr", 0, "Ptr", priorLayout)
    try fixture.Destroy()
    try WinActivate("ahk_id " originalWindow)
    if IsSet(settingsDirectory)
        try DirDelete(settingsDirectory, true)
}
ExitApp(code)
