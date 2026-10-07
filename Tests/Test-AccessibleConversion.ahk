#Requires AutoHotkey v2.0.19+
#Include ..\CeratopsKeyboardLayout.ahk

class CollapseRangeProbe {
    __New(selected) => this.Selected := selected
    CompareEndpoints(*) => this.Selected ? 1 : 0
    MoveEndpointByRange(*) => this.Selected := false
    Select() => 0
}
class CollapseFieldProbe extends AccessibleTextField {
    __New(selected) {
        this.Range := CollapseRangeProbe(selected)
        this.Dismissals := 0
        this.KeyCollapses := 0
    }
    GetRange() => this.Range
    EnsureFocus() => true
    CollapseByKey() {
        this.KeyCollapses += 1
        this.Range.Selected := false
    }
    DismissSelectionUI() => this.Dismissals += 1
}
if A_Args.Length && A_Args[1] = "--collapse-only" {
    for selected in [false, true] {
        field := CollapseFieldProbe(selected)
        field.Collapse()
        if field.Range.Selected || field.Dismissals != 1
            || field.KeyCollapses != (selected ? 1 : 0)
            throw Error("Collapse must dismiss the toolbar after clearing selection.")
    }
    field := CollapseFieldProbe(false)
    field.Collapse(true)
    if field.KeyCollapses != 1 || field.Dismissals != 1
        throw Error("Forced collapse must send a real editor key for a hidden selection.")
    try FileAppend("PASS 3 collapse paths`n", "*")
    ExitApp(0)
}

checks := 0
; Route fixture selection and paste to its own HWND, so this check never
; steals focus from a person typing. Real keys remain covered by the hotkey test.
class FixtureTextField extends AccessibleTextField {
    __New(window, control, element) {
        this.Control := control
        this.SelectAllCalls := 0
        this.CollapseKeyCalls := 0
        this.RichFragment := ""
        this.PastedFragment := ""
        this.CopyPrefix := ""
        this.RequireRich := false
        super.__New(window, element)
    }
    HasFocus() => DllCall("IsWindow", "Ptr", this.Control, "Int")
    IsCodexEditor() => this.RequireRich
    Paste() {
        rich := RichClipboard.ReadHtml()
        this.PastedFragment := rich ? rich.fragment : ""
        SendMessage(0x302, 0, 0, this.Control)
    }
    Copy() {
        SendMessage(0x301, 0, 0, this.Control)
        if this.RichFragment != "" {
            parts := {before: "<html><body><!--StartFragment-->",
                after: "<!--EndFragment--></body></html>"}
            html := RichClipboard.Build(parts, this.RichFragment)
            sequence := DllCall("GetClipboardSequenceNumber", "UInt")
            RichClipboard.Write(this.CopyPrefix A_Clipboard, html, &sequence)
        }
    }
    SelectAll() {
        this.SelectAllCalls += 1
        SendMessage(0xB1, 0, -1, this.Control)
    }
    CollapseByKey() {
        this.CollapseKeyCalls += 1
        start := Buffer(4, 0), finish := Buffer(4, 0)
        SendMessage(0xB0, start.Ptr, finish.Ptr, this.Control)
        end := NumGet(finish, "UInt")
        SendMessage(0xB1, end, end, this.Control)
    }
    DismissSelectionUI() => 0
}
class EmptySelectionPattern {
    __New(documentRange) => this.DocumentRange := documentRange
    GetSelection() => []
}
Assert(actual, expected, label) {
    global checks, fixtureWindow
    if !(actual == expected)
        throw Error(label "`nExpected: " expected "`nActual: " actual
            "`nFixture active: " WinActive("ahk_id " fixtureWindow))
    checks += 1
}
EditorSelection(control) {
    start := Buffer(4, 0), finish := Buffer(4, 0)
    SendMessage(0xB0, start.Ptr, finish.Ptr, control)
    return [NumGet(start, "UInt"), NumGet(finish, "UInt")]
}

oldClipboard := ClipboardAll()
stage := "initial"
try {
    Run('"' A_AhkPath '" "' A_ScriptDir '\Show-TestField.ahk"', , , &fixturePid)
    fixtureWindow := WinWait("ahk_pid " fixturePid, , 3)
    control := ControlGetHwnd("Edit1", "ahk_id " fixtureWindow)
    element := UIA.ElementFromHandle(control, , false)
    try FileAppend("Focused type " element.Type ", TextPattern " element.IsTextPatternAvailable "`n", "*")
    field := FixtureTextField(fixtureWindow, control, element)
    A_Clipboard := "clipboard sentinel"
    ControlSetText("prefix שלום suffix", control)
    SendMessage(0xB1, 7, 11, control)
    stage := "plain selected"
    field.Convert("en", "he", "selected")
    Assert(ControlGetText(control), "prefix akuo suffix", "Accessibility selection conversion")
    Assert(field.GetRange().CompareEndpoints("Start", field.GetRange(), "End"), 0, "Accessibility selection collapsed")
    Assert(A_Clipboard, "clipboard sentinel", "Clipboard restored")
    ; A simulated rich editor exposes an ordered list through CF_HTML. Its
    ; structure and inline formatting must survive the conversion round trip.
    field.RichFragment := "<ol><li><p>שלום <strong title='x>y'>עולם</strong> &amp; &unknown;</p></li></ol>"
    ControlSetText("1. שלום עולם &", control)
    SendMessage(0xB1, 0, -1, control)
    stage := "rich full list"
    field.Convert("en", "he", "selected")
    Assert(ControlGetText(control), "1. akuo guko &", "Rich selection plain-text fallback")
    Assert(field.PastedFragment,
        "<ol><li><p>akuo <strong title='x>y'>guko</strong> &amp; &unknown;</p></li></ol>",
        "Rich list and inline formatting survive conversion")
    Assert(A_Clipboard, "clipboard sentinel", "Rich conversion restores clipboard")
    ; Chromium can include a generated list marker in the copied plain text
    ; even when the selected range contains only the item's words. Paste its
    ; inline markup into the existing item, not a second <ol>/<li> wrapper.
    field.CopyPrefix := "1. "
    field.RichFragment := "<ol><li><p><strong>שלום</strong></p></li></ol>"
    ControlSetText("שלום", control)
    SendMessage(0xB1, 0, -1, control)
    stage := "selected list item"
    field.Convert("en", "he", "selected")
    Assert(ControlGetText(control), "akuo", "Selected list text does not duplicate its marker")
    Assert(field.PastedFragment, "<strong>akuo</strong>",
        "Selected list text retains inline formatting without a second list")
    Assert(A_Clipboard, "clipboard sentinel", "Selected list conversion restores clipboard")
    Assert(RichHtml.InlineListItem("<ol><li>one</li><li>two</li></ol>"), false,
        "Multiple list items are never unwrapped as one")
    field.CopyPrefix := ""
    Assert(RichHtml.Convert("<ol><li>&#x5e9;לום</li></ol>", "en", "he"),
        "<ol><li>akuo</li></ol>", "Numeric HTML letter references convert")
    Assert(RichHtml.Convert("<p>שלום<strong>/</strong> english<strong>/</strong></p>",
        "en", "he"), "<p>akuo<strong>q</strong> english<strong>/</strong></p>",
        "Punctuation follows its adjacent language across formatting tags")
    malformedRefused := false
    try RichHtml.Convert("<ol><li title='unfinished>שלום", "en", "he")
    catch Error as failure
        malformedRefused := InStr(failure.Message, "malformed rich content") > 0
    Assert(malformedRefused, true, "Malformed rich markup is refused")
    mediaRefused := false
    try RichHtml.Convert("<ol><li>שלום<img src='cid:x'></li></ol>", "en", "he")
    catch Error as failure
        mediaRefused := InStr(failure.Message, "cannot be converted safely") > 0
    Assert(mediaRefused, true, "Embedded media is refused instead of flattened")
    field.RichFragment := ""
    field.RequireRich := true
    ControlSetText("שלום", control)
    SendMessage(0xB1, 0, -1, control)
    refused := false
    stage := "rich copy refusal"
    try field.Convert("en", "he", "selected")
    catch Error as failure
        refused := InStr(failure.Message, "did not provide rich clipboard content") > 0
    Assert(refused, true, "Rich editor without HTML refuses a flattening paste")
    Assert(ControlGetText(control), "שלום", "Refused rich copy leaves document unchanged")
    caret := EditorSelection(control)
    Assert(caret[1], caret[2], "Refused rich copy clears typing selection")
    Assert(A_Clipboard, "clipboard sentinel", "Refused rich copy restores clipboard")
    field.RequireRich := false
    ControlSetText("prefix שלום suffix", control)
    SendMessage(0xB1, 7, 11, control)
    stage := "whole field"
    field.Convert("en", "he", "all")
    Assert(ControlGetText(control), "prefix akuo suffix", "Accessibility Select All overrides partial selection")
    Assert(field.GetRange().CompareEndpoints("Start", field.GetRange(), "End"), 0,
        "Accessibility Select All result collapsed")
    field.Convert("he", "en", "selected")
    Assert(ControlGetText(control), "prefix akuo suffix", "Accessibility selected-only leaves a caret unchanged")
    pattern := field.Pattern
    field.Pattern := EmptySelectionPattern(pattern.DocumentRange)
    Assert(field.GetRange().CompareEndpoints("Start", field.GetRange(), "End"), 0,
        "No UIA selection means a plain caret")
    field.Pattern := pattern
    ControlSetText("שלום", control)
    SendMessage(0xB1, 2, 2, control)
    priorSelectAll := field.SelectAllCalls
    priorCollapseKeys := field.CollapseKeyCalls
    stage := "native no-op"
    field.Convert("he", "he", "all")
    Assert(ControlGetText(control), "שלום", "Same-language whole field preserves text")
    Assert(field.SelectAllCalls, priorSelectAll,
        "Same-language whole field never sends Ctrl+A")
    Assert(field.CollapseKeyCalls, priorCollapseKeys,
        "Same-language caret does not move")
    caret := EditorSelection(control)
    Assert(caret[1], 2, "Same-language caret stays at its original position")
    Assert(caret[2], 2, "Same-language conversion leaves no typing selection")
    typed := "X"
    SendMessage(0xC2, 1, StrPtr(typed), control)
    Assert(ControlGetText(control), "שלXום",
        "Typing after same-language conversion inserts instead of replacing")
    ControlSetText("שלום", control)
    SendMessage(0xB1, 0, 4, control)
    field.Convert("he", "he", "selected")
    caret := EditorSelection(control)
    Assert(caret[1], caret[2], "Selected-only no-op clears the typing selection")
    Assert(field.CollapseKeyCalls, priorCollapseKeys + 1,
        "Selected-only no-op uses the editor key")
    SendMessage(0xB1, 1, 3, control)
    field.Convert("he", "he", "all")
    caret := EditorSelection(control)
    Assert(field.SelectAllCalls, priorSelectAll,
        "Same-language partial selection does not send Ctrl+A")
    Assert(caret[1], caret[2], "Same-language partial selection is cleared")
    Assert(field.CollapseKeyCalls, priorCollapseKeys + 2,
        "Same-language partial selection uses the editor key")
    field.RequireRich := true
    ControlSetText("שלום", control)
    SendMessage(0xB1, 2, 2, control)
    priorCollapseKeys := field.CollapseKeyCalls
    stage := "Codex no-op"
    field.Convert("he", "he", "all")
    Assert(field.CollapseKeyCalls, priorCollapseKeys + 1,
        "Codex same-language conversion clears a hidden typing selection with an editor key")
    caret := EditorSelection(control)
    Assert(caret[1], caret[2], "Codex same-language conversion leaves no typing selection")
    typed := "X"
    SendMessage(0xC2, 1, StrPtr(typed), control)
    Assert(ControlGetText(control), "שלXום",
        "Typing after Codex same-language conversion inserts instead of replacing")
    field.RequireRich := false
    try FileAppend("PASS " checks " accessibility checks`n", "*")
    code := 0
} catch Error as failure {
    try FileAppend("FAIL " stage ": " failure.Message " (line " failure.Line ")`n", "*")
    code := 1
} finally {
    A_Clipboard := oldClipboard
    try WinClose("ahk_pid " fixturePid)
}
ExitApp(code)
