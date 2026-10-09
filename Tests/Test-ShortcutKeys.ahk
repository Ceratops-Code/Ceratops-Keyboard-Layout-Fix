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
DismissToolbar(*) {
    global toolbar, toolbarControl
    toolbar.open := false
    toolbar.dismissals += 1
    toolbarControl.Focus()
}
SendDoubleShortcut(key) {
    ; Keep both modifiers down across the two distinct key presses.
    SendInput("{Ctrl down}{Alt down}{vk" key "}")
    Sleep(80)
    SendInput("{vk" key "}{Alt up}{Ctrl up}")
}
try {
    DetectHiddenWindows(true)
    ; Match the running script name at either the project or installed path.
    ; Two global listeners make synthetic shortcut results meaningless.
    if WinExist("CeratopsKeyboardLayout.ahk ahk_class AutoHotkey")
        throw Error("Stop the Ceratops service and wait for its tray app to exit before testing hotkeys.")
    Run('"' A_AhkPath '" "' A_ScriptDir '\..\CeratopsKeyboardLayout.ahk"', , , &converterPid)
    DetectHiddenWindows(true)
    WinWait("ahk_pid " converterPid " ahk_class AutoHotkey", , 3)
    fixture := Gui(, "Keyboard shortcut test")
    toolbar := {open: false, dismissals: 0}
    fixture.OnEvent("Escape", DismissToolbar)
    inputControl := fixture.AddEdit("w420 r3", "שלום")
    toolbarControl := fixture.AddEdit("ReadOnly w120", "Formatting toolbar")
    fixture.Show()
    inputControl.Focus()
    if !WinWaitActive("ahk_id " fixture.Hwnd, , 2)
        throw Error("Test editor did not become active")
    Sleep(150)
    editorThread := DllCall("GetWindowThreadProcessId", "Ptr", inputControl.Hwnd, "Ptr", 0, "UInt")
    priorLayout := DllCall("GetKeyboardLayout", "UInt", editorThread, "Ptr")
    expectedText := Map("en", "akuo", "he", "שלום", "ru", "флгщ")
    for target, layout in Converter.Layouts {
        language := KeyboardConverter.Languages[target]
        key := SubStr(language.Key, 3)
        expected := expectedText[target]
        WinActivate("ahk_id " fixture.Hwnd)
        inputControl.Focus()
        if !WinWaitActive("ahk_id " fixture.Hwnd, , 2)
            throw Error("Test editor lost focus before shortcut")
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
        SendInput("^!{vk" key "}")
        focusAfterSend := WinGetProcessName("A")
        ; The single-tap handler waits 350 ms; check promptly afterward so
        ; unrelated desktop activity cannot invalidate this focus assertion.
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
    SendInput("^!{vk45}")
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
        Converter := KeyboardConverter([])
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
    try FileAppend("PASS single/double hotkeys, unavailable targets and 2 accessibility conversions`n", "*")
    code := 0
} catch Error as failure {
    try FileAppend("FAIL: " failure.Message "`n", "*")
    code := 1
} finally {
    ; Closing AutoHotkey's main window only hides it. End only the exact child
    ; process created by this test so its global hotkeys cannot remain active.
    try ProcessClose(converterPid)
    try DllCall("PostMessageW", "Ptr", inputControl.Hwnd, "UInt", 0x50,
        "UPtr", 0, "Ptr", priorLayout)
    try fixture.Destroy()
    try WinActivate("ahk_id " originalWindow)
}
ExitApp(code)
