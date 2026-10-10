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

; Change the queried snapshot without changing Windows settings. The real
; refresh and mapping operations still run, including the shortcut entry path.
class KeyboardLayoutSnapshotFixture extends KeyboardConverter {
    __New(handles) {
        this.CurrentHandles := handles, this.LayoutQueries := 0, this.FailQuery := false
        super.__New(handles)
    }

    ReadInstalledLayoutHandles() {
        this.LayoutQueries += 1
        if this.FailQuery
            throw Error("Fixture layout query failed")
        return this.CurrentHandles
    }
}

testExitCode := 1
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

    live := KeyboardLayoutSnapshotFixture([]), allHandles := []
    for name in KeyboardConverter.Languages {
        allHandles.Push(Converter.Layouts[name])
        live.CurrentHandles.Push(Converter.Layouts[name])
        Assert(live.RefreshInstalledLayouts(), true, "Added keyboard refreshes cached maps")
        Assert(live.RequireInstalledLayout(name), Converter.Layouts[name], "Added target is immediately available")
        for source, sample in samples {
            for target in live.Layouts {
                expected := live.Layouts.Has(source) ? Converter.Convert(sample, target, source) : sample
                Assert(live.Convert(sample, target, source), expected,
                    "Added keyboards participate as both source and target")
            }
        }
    }
    cachedMaps := live.Maps, cachedSymbols := live.SymbolMaps, cachedLayouts := live.Layouts
    Assert(live.RefreshInstalledLayouts(), false, "Unchanged layouts need no rebuild")
    Assert(live.Maps == cachedMaps && live.SymbolMaps == cachedSymbols
        && live.Layouts == cachedLayouts, true, "Unchanged layouts reuse all cached tables")
    reordered := []
    for handle in allHandles
        reordered.InsertAt(1, handle)
    reordered.Push(allHandles[1])
    live.CurrentHandles := reordered
    Assert(live.RefreshInstalledLayouts(), false, "Order and duplicate handles do not rebuild maps")
    Assert(live.Maps == cachedMaps, true, "Equivalent snapshots retain the accepted maps")
    live.FailQuery := true
    queryFailed := false
    try live.RefreshInstalledLayouts()
    catch Error
        queryFailed := true
    Assert(queryFailed, true, "A failed layout query is reported")
    Assert(live.Maps == cachedMaps && live.SymbolMaps == cachedSymbols
        && live.Layouts == cachedLayouts, true, "Query failure preserves the complete cache")
    live.FailQuery := false, live.CurrentHandles := allHandles.Clone()
    for name in KeyboardConverter.Languages {
        live.CurrentHandles.RemoveAt(1)
        Assert(live.RefreshInstalledLayouts(), true, "Removed keyboard refreshes cached maps")
        rejected := false
        try live.RequireInstalledLayout(name)
        catch Error
            rejected := true
        Assert(rejected, true, "Removed target is immediately unavailable")
        Assert(live.Maps.Has(name) || live.SymbolMaps.Has(name), false, "Removed keyboard has no stale maps")
        for source, targets in live.SymbolMaps
            Assert(targets.Has(name), false, "Removed symbol target has no stale map")
        for target in live.Layouts
            Assert(live.Convert(samples[name], target, name), samples[name], "Removed source text stays intact")
    }
    Assert(live.Layouts.Count, 0, "Removing every supported keyboard is safe")
    Assert(live.RefreshInstalledLayouts(), false, "Empty supported set is also cached")

    ; Temporary, task-owned window. Exercise the actual native edit operations,
    ; including clipboard preservation, undo and complete-field replacement.
    testGui := Gui(, "Keyboard layout conversion test")
    inputControl := testGui.AddEdit("w420 r4", "prefix שלום suffix")
    testGui.Show("Hide")
    field := NativeTextFieldFixture(testGui.Hwnd, inputControl.Hwnd)
    ; ClipboardAll can contain volatile bytes even when Windows' sequence is
    ; unchanged. Observe text and Windows' write counter without changing the
    ; user's clipboard or notifying clipboard listeners between desktop tests.
    clipboardBefore := A_Clipboard
    testClipboardSequence := DllCall("GetClipboardSequenceNumber", "UInt")
    ; The unavailable-target entry path must stop before asking even an
    ; unfocused editor to select or copy. Its message makes that ordering
    ; observable without depending on another app allowing window activation.
    completeConverter := Converter
    try {
        Converter := KeyboardLayoutSnapshotFixture(allHandles.Clone())
        Converter.CurrentHandles := []
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
        Assert(Converter.Layouts.Count, 0, "Shortcut refresh notices removed keyboards")
        Assert(Converter.LayoutQueries, KeyboardConverter.Languages.Count,
            "Each shortcut queries layouts exactly once")
        Converter.CurrentHandles := allHandles.Clone()
        Converter.FailQuery := true
        ConvertOneFocusedText(names[1], testGui.Hwnd, "all")
        Assert(inputControl.Value, "prefix שלום suffix", "Query failure leaves the text alone")
        Assert(field.Selection()[1], 2, "Query failure preserves selection start")
        Assert(field.Selection()[2], 5, "Query failure preserves selection end")
        Assert(DllCall("GetClipboardSequenceNumber", "UInt"), clipSequence,
            "Query failure leaves the clipboard alone")
        Assert(DllCall("GetKeyboardLayout", "UInt", inputThread, "Ptr"), inputLayout,
            "Query failure leaves the active keyboard alone")
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
    Assert(A_Clipboard == clipboardBefore, true, "Native clipboard content stays unchanged")
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
}
ExitApp(testExitCode)
