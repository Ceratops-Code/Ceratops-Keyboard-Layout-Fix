#Requires AutoHotkey v2.0.19+
#Include ..\CeratopsKeyboardLayout.ahk

checks := 0
Assert(actual, expected, label) {
    global checks
    if !(actual == expected)
        throw Error(label "`nExpected: " expected "`nActual: " actual)
    checks += 1
}

; The hidden edit control exercises replacement without competing for the
; user's foreground window. The hotkey test covers real Ctrl+A delivery.
class NativeTextFieldFixture extends NativeTextField {
    HasFocus() => true
    SelectAll() => SendMessage(0xB1, 0, -1, this.Control)
}

try {
    for test in [
        ["אד", "en", "ts"], ["שלום", "en", "akuo"],
        ["руддщ", "en", "hello"], ["Руддщ", "en", "Hello"],
        ["hello", "he", "יקךךם"], ["HELLO", "he", "יקךךם"],
        ["руддщ", "he", "יקךךם"], ["РУДДЩ", "he", "יקךךם"],
        ["hello", "ru", "руддщ"], ["HELLO", "ru", "РУДДЩ"],
        ["יקךךם", "ru", "руддщ"], ["אד руддщ English 123 😀`r`n", "en", "ts hello English 123 😀`r`n"],
        ["שלום", "he", "שלום"], ["Привет", "ru", "Привет"],
        ["English", "en", "English"], [",.", "he", "תץ"],
        ["ёЁ№", "en", "``~#"], ["123 😀`t`r`n", "ru", "123 😀`t`r`n"]
    ]
        Assert(Converter.Convert(test[1], test[2]), test[3], "Mapping to " test[2])

    Assert(Converter.Convert("/", "en", "he"), "q", "Hebrew slash uses Q key")
    Assert(Converter.Convert("'", "en", "he"), "w", "Hebrew apostrophe uses W key")
    Assert(Converter.Convert("[", "en", "he"), "]", "Hebrew left bracket uses right bracket key")
    Assert(Converter.Convert("]", "en", "he"), "[", "Hebrew right bracket uses left bracket key")
    Assert(Converter.Convert(";", "en", "he"), "``", "Hebrew semicolon uses backtick key")
    Assert(Converter.Convert(",", "en", "he"), "'", "Hebrew comma uses quote key")
    Assert(Converter.Convert(".", "en", "he"), "/", "Hebrew period uses slash key")
    Assert(Converter.Convert("/.,", "en", "ru"), "|/?", "Russian punctuation uses its physical keys")
    Assert(Converter.Convert("wq``[]/.", "he"), "'/;][.ץ", "English symbols convert to Hebrew")
    Assert(Converter.Convert("שלום /", "en", "en"), "akuo q", "Hebrew text determines nearby symbol source")
    Assert(Converter.Convert("1. hello.", "he"), "1. יקךךםץ",
        "Numbered-list marker stays intact while body punctuation converts")
    Assert(Converter.Convert("1.", "he"), "1.",
        "Empty numbered-list marker stays intact")
    Assert(Converter.Convert("1. שלום`n2. שלום", "en"), "1. akuo`n2. akuo",
        "Numbered-list markers survive multiple lines")
    Assert(Converter.Convert("  12. hello", "ru"), "  12. руддщ",
        "Indented numbered-list marker stays intact")
    Assert(Converter.Convert("- hello", "he"), "- יקךךם",
        "Unordered-list marker stays intact")

    ; Temporary, task-owned window. Exercise the actual native edit operations,
    ; including clipboard preservation, undo and complete-field replacement.
    testGui := Gui(, "Keyboard layout conversion test")
    inputControl := testGui.AddEdit("w420 r4", "prefix שלום suffix")
    testGui.Show("Hide")
    field := NativeTextFieldFixture(testGui.Hwnd, inputControl.Hwnd)
    clipBefore := ClipboardAll()
    SendMessage(0xB1, 7, 11, inputControl.Hwnd)
    Assert(inputControl.Value, "prefix שלום suffix", "Fixture text before selected conversion")
    Assert(field.Selection()[1], 7, "Fixture selection start")
    Assert(field.Selection()[2], 11, "Fixture selection end")
    field.Convert("en", "he", "selected")
    Assert(inputControl.Value, "prefix akuo suffix", "Only selection converted")
    Assert(field.Selection()[1], field.Selection()[2], "Selection removed")
    SendMessage(0x304, 0, 0, inputControl.Hwnd)
    Assert(inputControl.Value, "prefix שלום suffix", "Replacement can be undone")
    SendMessage(0xB1, 2, 2, inputControl.Hwnd)
    Assert(inputControl.Value, "prefix שלום suffix", "Text before selected-only caret conversion")
    Assert(field.Selection()[1], 2, "Caret start before selected-only conversion")
    Assert(field.Selection()[2], 2, "Caret end before selected-only conversion")
    field.Convert("en", "he", "selected")
    Assert(inputControl.Value, "prefix שלום suffix", "Selected-only leaves an unselected field unchanged")
    Assert(field.Selection()[1], 2, "Selected-only preserves the caret")
    SendMessage(0xB1, 7, 11, inputControl.Hwnd)
    field.Convert("en", "he", "all")
    Assert(inputControl.Value, "prefix akuo suffix", "Select-all overrides a partial selection")
    Assert(field.Selection()[1], field.Selection()[2], "Select-all result is unselected")
    inputControl.Value := "שלום`r`nруддщ"
    SendMessage(0xB1, 2, 2, inputControl.Hwnd)
    field.Convert("en", "he", "all")
    Assert(StrReplace(inputControl.Value, "`r`n", "`n"), "akuo`nhello", "No selection converts entire multiline field")
    Assert(field.Selection()[1], field.Selection()[2], "Whole field deselected")
    field.Convert("en", "en", "all")
    Assert(StrReplace(inputControl.Value, "`r`n", "`n"), "akuo`nhello",
        "Repeated whole field conversion does not append")
    Assert(field.Selection()[1], field.Selection()[2], "Repeated whole field deselected")
    Assert(DllCall("msvcrt\memcmp", "Ptr", clipBefore, "Ptr", ClipboardAll(), "UPtr", clipBefore.Size, "Int"), 0, "Native clipboard unchanged")
    inputControl.Value := "English text"
    SendMessage(0xB1, 0, 7, inputControl.Hwnd)
    field.Convert("en", "en", "selected")
    Assert(inputControl.Value, "English text", "No-op preserves text")
    Assert(field.Selection()[1], field.Selection()[2], "No-op deselects")
    inputControl.Value := ""
    field.Convert("he", "en", "all")
    Assert(inputControl.Value, "", "Empty field")
    testGui.Destroy()
    try FileAppend("PASS " checks " checks`n", "*")
    ExitApp(0)
} catch Error as failure {
    try testGui.Destroy()
    try FileAppend("FAIL: " failure.Message " (line " failure.Line ")`n", "*")
    ExitApp(1)
}
