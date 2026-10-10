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

testExitCode := 1, testClipboardSequence := 0
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

    ; Cover every installed-layout subset without adding/removing Windows
    ; keyboards. Expected text stays independent of the language registry.
    samples := Map("en", "hello /.,", "he", "שלום /.,", "ru", "руддщ /.,")
    names := []
    for name in KeyboardConverter.Languages
        names.Push(name)
    Loop (1 << names.Length) {
        mask := A_Index - 1, handles := [], availableCount := 0
        for index, name in names {
            if mask & (1 << (index - 1)) {
                ; This test PC needs the layouts to exercise real Win32 key
                ; output. Subsets model PCs that do not have those keyboards.
                handles.Push(Converter.Layouts[name])
                handles.Push(Converter.Layouts[name])
                availableCount += 1
            }
        }
        handles.Push(0x040C) ; An unrelated input language is ignored.
        subset := KeyboardConverter(handles)
        Assert(subset.Layouts.Count, availableCount, "Only supported installed layouts, subset " mask)
        Assert(subset.Maps.Count, availableCount, "One conversion map per installed target")
        Assert(subset.SymbolMaps.Count, availableCount, "Symbol sources need installed layouts")
        fallback := subset.DominantSource("123 /.,", "not-supported")
        Assert(availableCount ? subset.Layouts.Has(fallback) : fallback = "", true,
            "Unknown source falls back only to an available keyboard")
        for target in KeyboardConverter.Languages {
            if !subset.Layouts.Has(target) {
                rejected := false
                try subset.Convert("unchanged", target)
                catch Error as failure {
                    rejected := InStr(failure.Message, KeyboardConverter.Languages[target].Name) > 0
                }
                Assert(rejected, true, "Unavailable target has a useful error, subset " mask)
                continue
            }
            Assert(subset.RequireInstalledLayout(target), Converter.Layouts[target], "Installed handle is retained")
            Assert(subset.SymbolMaps[target].Count, availableCount, "Only available symbol targets")
            for source, sample in samples {
                expected := subset.Layouts.Has(source)
                    ? Converter.Convert(sample, target, source) : sample
                Assert(subset.Convert(sample, target, source), expected,
                    "Subset " mask " maps " source " to " target " without absent-layout lookups")
            }
            Assert(subset.Convert("123 /.,", target, target), "123 /.,",
                "An available target preserves its own symbols")
        }
    }

    ; Temporary, task-owned window. Exercise the actual native edit operations,
    ; including clipboard preservation, undo and complete-field replacement.
    testGui := Gui(, "Keyboard layout conversion test")
    inputControl := testGui.AddEdit("w420 r4", "prefix שלום suffix")
    testGui.Show("Hide")
    field := NativeTextFieldFixture(testGui.Hwnd, inputControl.Hwnd)
    ; ClipboardAll can contain volatile bytes even when Windows' sequence is
    ; unchanged. Own a known fixture and check both its content and sequence;
    ; restore the user's formats unless another copy replaced our fixture.
    savedClipboard := ClipboardAll()
    clipboardFixture := "Ceratops native conversion clipboard fixture"
    A_Clipboard := clipboardFixture
    testClipboardSequence := DllCall("GetClipboardSequenceNumber", "UInt")
    ; The unavailable-target entry path must stop before asking even an
    ; unfocused editor to select or copy. Its message makes that ordering
    ; observable without depending on another app allowing window activation.
    completeConverter := Converter
    try {
        Converter := KeyboardConverter([])
        SendMessage(0xB1, 2, 5, inputControl.Hwnd)
        clipSequence := DllCall("GetClipboardSequenceNumber", "UInt")
        inputThread := DllCall("GetWindowThreadProcessId", "Ptr", inputControl.Hwnd, "Ptr", 0, "UInt")
        inputLayout := DllCall("GetKeyboardLayout", "UInt", inputThread, "Ptr")
        for target, language in KeyboardConverter.Languages {
            ToolTip()
            ConvertOneFocusedText(target, testGui.Hwnd, "all")
            tooltipWindow := WinExist("ahk_class tooltips_class32 ahk_pid " DllCall("GetCurrentProcessId", "UInt"))
            Assert(tooltipWindow != 0, true, "Unavailable shortcut shows a message before checking focus")
            ToolTip()
            Assert(inputControl.Value, "prefix שלום suffix", "Unavailable shortcut preserves text")
            Assert(field.Selection()[1], 2, "Unavailable shortcut preserves selection start")
            Assert(field.Selection()[2], 5, "Unavailable shortcut preserves selection end")
            Assert(DllCall("GetClipboardSequenceNumber", "UInt"), clipSequence,
                "Unavailable shortcut leaves the clipboard alone")
            Assert(DllCall("GetKeyboardLayout", "UInt", inputThread, "Ptr"), inputLayout,
                "Unavailable shortcut leaves the active keyboard alone")
        }
    } finally {
        ToolTip()
        Converter := completeConverter
    }
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
    Assert(DllCall("GetClipboardSequenceNumber", "UInt"), testClipboardSequence,
        "Native conversion does not write any clipboard format")
    Assert(A_Clipboard, clipboardFixture, "Native clipboard content stays unchanged")
    inputControl.Value := "English text"
    SendMessage(0xB1, 0, 7, inputControl.Hwnd)
    field.Convert("en", "en", "selected")
    Assert(inputControl.Value, "English text", "No-op preserves text")
    Assert(field.Selection()[1], field.Selection()[2], "No-op deselects")
    inputControl.Value := ""
    field.Convert("he", "en", "all")
    Assert(inputControl.Value, "", "Empty field")
    try FileAppend("PASS " checks " checks`n", "*")
    testExitCode := 0
} catch Error as failure {
    try FileAppend("FAIL: " failure.Message " (line " failure.Line ")`n", "*")
} finally {
    try testGui.Destroy()
    try {
        if testClipboardSequence && DllCall("GetClipboardSequenceNumber", "UInt") = testClipboardSequence
            A_Clipboard := savedClipboard
    } catch Error as failure {
        try FileAppend("FAIL: Clipboard restoration: " failure.Message "`n", "*")
        testExitCode := 1
    }
}
ExitApp(testExitCode)
