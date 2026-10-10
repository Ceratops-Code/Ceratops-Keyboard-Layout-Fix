#Requires AutoHotkey v2.0.19+
#SingleInstance Force
#MaxThreadsPerHotkey 1
; UIA is used only for the focused text field. Do not change Windows' global
; screen-reader setting. Runtime text, clipboard backups and maps stay in RAM.
global IUIAutomationActivateScreenReader := 0
#Include Lib\UIA.ahk

global Converter := KeyboardConverter()
if A_LineFile = A_ScriptFullPath {
    A_IconTip := "Ceratops Keyboard Layout: single tap converts selection; double tap converts all"
    TraySetIcon(A_ScriptDir "\CeratopsKeyboardLayout.ico")
    ; The portable install has no AutoHotkey helper apps such as Window Spy.
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Exit Ceratops Keyboard Layout", (*) => ExitApp())
    ; Bind the target now: loop variables must not be captured by reference.
    for name, language in KeyboardConverter.Languages
        Hotkey("^!" language.Key, HandleConversionShortcut.Bind(name, language.Key))
    StartAppUpdateCheck()
}

StartAppUpdateCheck() {
    ; Setup suppresses only its own immediate restart. Future Windows sign-ins
    ; and manual launches check normally. The separate helper cannot block keys.
    for argument in A_Args
        if argument = "--skip-update-check"
            return
    try Run('"' A_WinDir '\System32\WindowsPowerShell\v1.0\powershell.exe"'
        . ' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'
        . A_ScriptDir '\Update-AppInstall.ps1"', A_ScriptDir, "Hide")
}

; Waiting for the first release prevents key auto-repeat from becoming a
; double tap. The second physical press must arrive within 350 ms while both
; modifiers remain down. #MaxThreadsPerHotkey suppresses a second callback
; while KeyWait observes that press.
HandleConversionShortcut(target, key, *) {
    window := WinExist("A")
    KeyWait(key)
    doubleTap := KeyWait(key, "D T0.35") && GetKeyState("Ctrl") && GetKeyState("Alt")
    ConvertFocusedText(target, window, doubleTap ? "all" : "selected")
}

class KeyboardConverter {
    ; The only language registry. Shortcuts, layout discovery, script detection
    ; and source counting all consume these definitions; maps use installed
    ; layouts only. Missing keyboards never prevent the tray app from starting.
    static Languages := Map(
        "en", {Name: "US English", LanguageId: 0x0409, Key: "vk45",
            ScriptRanges: [[0x41, 0x5A], [0x61, 0x7A]]},
        "he", {Name: "Hebrew", LanguageId: 0x040D, Key: "vk48",
            ScriptRanges: [[0x0590, 0x05FF]]},
        "ru", {Name: "Russian", LanguageId: 0x0419, Key: "vk52",
            ScriptRanges: [[0x0400, 0x052F], [0x2116, 0x2116]]})
    static ShiftStates := [false, true]

    ; An explicit handle snapshot also lets tests cover missing keyboards
    ; without changing the person's Windows language settings.
    __New(installedLayouts := unset) {
        this.Layouts := Map()
        for handle in IsSet(installedLayouts) ? installedLayouts : KeyboardConverter.InstalledLayoutHandles() {
            for name, language in KeyboardConverter.Languages {
                if (handle & 0xFFFF) = language.LanguageId && !this.Layouts.Has(name)
                    this.Layouts[name] := handle
            }
        }
        this.Maps := Map(), this.SymbolMaps := Map()
        for name in this.Layouts
            this.Maps[name] := this.BuildMap(name)
        for source in this.Layouts {
            this.SymbolMaps[source] := Map()
            for target in this.Layouts
                this.SymbolMaps[source][target] := this.BuildSymbolMap(source, target)
        }
    }

    static InstalledLayoutHandles() {
        result := []
        count := DllCall("GetKeyboardLayoutList", "Int", 0, "Ptr", 0, "Int")
        if count <= 0
            return result
        layouts := Buffer(count * A_PtrSize)
        count := DllCall("GetKeyboardLayoutList", "Int", count, "Ptr", layouts, "Int")
        Loop count
            result.Push(NumGet(layouts, (A_Index - 1) * A_PtrSize, "UPtr"))
        return result
    }

    RequireInstalledLayout(target) {
        if this.Layouts.Has(target)
            return this.Layouts[target]
        name := KeyboardConverter.Languages.Has(target)
            ? KeyboardConverter.Languages[target].Name : target
        throw Error(name " keyboard layout is not installed. Install it in Windows to use this shortcut.")
    }

    ; Map actual Windows layout output back through a physical scan code.
    ; wFlags=4 prevents ToUnicodeEx from altering the user's dead-key state.
    KeyText(layout, scan, shifted := false) {
        key := DllCall("MapVirtualKeyExW", "UInt", scan, "UInt", 3, "Ptr", layout, "UInt")
        state := Buffer(256, 0), output := Buffer(16, 0)
        if shifted
            NumPut("UChar", 0x80, state, 0x10)
        length := DllCall("ToUnicodeEx", "UInt", key, "UInt", scan, "Ptr", state,
            "Ptr", output, "Int", 8, "UInt", 4, "Ptr", layout, "Int")
        return length = 1 ? StrGet(output, 1, "UTF-16") : ""
    }

    ScriptOf(character) {
        code := Ord(character)
        for name, language in KeyboardConverter.Languages
            for bounds in language.ScriptRanges
                if code >= bounds[1] && code <= bounds[2]
                    return name
        return ""
    }

    BuildMap(target) {
        result := Map()
        result.CaseSense := true
        for source, layout in this.Layouts {
            if source = target
                continue
            ; Main typing area only: no numpad, navigation or control keys.
            Loop 0x35 {
                scan := A_Index
                for shifted in KeyboardConverter.ShiftStates {
                    from := this.KeyText(layout, scan, shifted)
                    if from = "" || this.ScriptOf(from) != source || result.Has(from)
                        continue
                    to := this.KeyText(this.Layouts[target], scan, shifted)
                    ; Hebrew has no capitals; retain Hebrew letter output even
                    ; when the source text was typed with Shift or Caps Lock.
                    if target = "he" && shifted && RegExMatch(from, "[A-ZА-ЯЁ]") {
                        base := this.KeyText(this.Layouts[target], scan)
                        if base != ""
                            to := base
                    }
                    if to != "" && Ord(to) >= 0x20
                        result[from] := to
                }
            }
        }
        return result
    }

    ; A printed punctuation mark can come from several physical keys. Keep
    ; separate source-layout maps instead of assigning it one global meaning.
    BuildSymbolMap(source, target) {
        result := Map()
        result.CaseSense := true
        if source = target
            return result
        Loop 0x35 {
            scan := A_Index
            for shifted in KeyboardConverter.ShiftStates {
                from := this.KeyText(this.Layouts[source], scan, shifted)
                if from = "" || Ord(from) < 0x21 || this.ScriptOf(from) != ""
                    || RegExMatch(from, "^[0-9]$") || result.Has(from)
                    continue
                to := this.KeyText(this.Layouts[target], scan, shifted)
                if to != "" && Ord(to) >= 0x20
                    result[from] := to
            }
        }
        return result
    }

    DominantSource(text, fallbackSource := "en") {
        counts := Map()
        for name in KeyboardConverter.Languages
            counts[name] := 0
        Loop Parse text {
            source := this.ScriptOf(A_LoopField)
            if counts.Has(source)
                counts[source] += 1
        }
        source := this.Layouts.Has(fallbackSource) ? fallbackSource : ""
        for candidate in this.Layouts {
            if source = ""
                source := candidate
        }
        for candidate, count in counts
            if count && (source = "" || count > counts[source])
                source := candidate
        return source
    }

    Convert(text, target, fallbackSource := "en") {
        this.RequireInstalledLayout(target)
        source := this.DominantSource(text, fallbackSource)
        result := "", mapping := this.Maps[target]
        position := 1, protectedMarkerEnd := 0
        Loop Parse text {
            character := A_LoopField
            if position = 1 || InStr("`r`n", SubStr(text, position - 1, 1)) {
                protectedMarkerEnd := 0
                ; Preserve Markdown-style list markers, which are structure,
                ; while still converting punctuation in the item's text.
                if RegExMatch(SubStr(text, position),
                    "^[ \t]*(?:[0-9]+[.)]|[-*+•])(?=[ \t\r\n]|$)", &marker)
                    protectedMarkerEnd := position + StrLen(marker[0]) - 1
            }
            characterSource := this.ScriptOf(character)
            if position <= protectedMarkerEnd {
                result .= character
            } else if characterSource != "" {
                source := characterSource
                result .= mapping.Has(character) ? mapping[character] : character
            } else if this.SymbolMaps.Has(source) {
                symbols := this.SymbolMaps[source][target]
                result .= symbols.Has(character) ? symbols[character] : character
            } else {
                ; Text from an absent source keyboard, including its symbols,
                ; stays intact because no installed layout can map its keys.
                result .= character
            }
            position += StrLen(character)
        }
        return result
    }
}

; CF_HTML keeps list and inline-formatting tags while the text inside them
; changes. Offsets are UTF-8 byte positions, never AutoHotkey character indexes.
class RichClipboard {
    static HtmlFormat() {
        format := DllCall("RegisterClipboardFormatW", "Str", "HTML Format", "UInt")
        if !format
            throw Error("Windows could not register the HTML clipboard format.")
        return format
    }

    static Open(owner := 0) {
        deadline := A_TickCount + 500
        while !DllCall("OpenClipboard", "Ptr", owner, "Int") {
            if A_TickCount >= deadline
                throw Error("The clipboard is busy. Press the shortcut again.")
            Sleep(20)
        }
    }

    static ReadHtml() {
        format := this.HtmlFormat()
        this.Open()
        try {
            if !DllCall("IsClipboardFormatAvailable", "UInt", format, "Int")
                return false
            handle := DllCall("GetClipboardData", "UInt", format, "Ptr")
            if !handle
                throw Error("The editor's rich clipboard data is unavailable.")
            size := DllCall("GlobalSize", "Ptr", handle, "UPtr")
            if size < 1 || size > 16000000
                throw Error("The editor's rich selection is too large or invalid.")
            pointer := DllCall("GlobalLock", "Ptr", handle, "Ptr")
            if !pointer
                throw Error("The editor's rich clipboard data could not be read.")
            try {
                copy := Buffer(size + 1, 0)
                DllCall("RtlMoveMemory", "Ptr", copy.Ptr, "Ptr", pointer, "UPtr", size)
            } finally {
                DllCall("GlobalUnlock", "Ptr", handle)
            }
            return this.Parse(StrGet(copy.Ptr, "UTF-8"))
        } finally {
            DllCall("CloseClipboard")
        }
    }

    static Parse(raw) {
        header := SubStr(raw, 1, 4096), offsets := Map()
        for name in ["StartHTML", "EndHTML", "StartFragment", "EndFragment"] {
            if !RegExMatch(header, "im)^" name ":[ \t]*([0-9]+)[ \t]*$", &match)
                throw Error("The editor supplied an unsupported rich clipboard header.")
            offsets[name] := match[1] + 0
        }
        bytes := StrPut(raw, "UTF-8")
        data := Buffer(bytes)
        StrPut(raw, data, "UTF-8")
        startHtml := offsets["StartHTML"], endHtml := offsets["EndHTML"]
        startFragment := offsets["StartFragment"], endFragment := offsets["EndFragment"]
        if startHtml < 1 || startHtml > startFragment
            || startFragment > endFragment || endFragment > endHtml
            || endHtml > bytes - 1
            throw Error("The editor supplied invalid rich clipboard offsets.")
        return {before: this.ByteSlice(data, startHtml, startFragment),
            fragment: this.ByteSlice(data, startFragment, endFragment),
            after: this.ByteSlice(data, endFragment, endHtml)}
    }

    static ByteSlice(data, first, last) {
        return first = last ? "" : StrGet(data.Ptr + first, last - first, "UTF-8")
    }

    static Build(parts, fragment) {
        before := parts.before, after := parts.after
        template := "Version:1.0`r`nStartHTML:{:010}`r`nEndHTML:{:010}`r`n"
            . "StartFragment:{:010}`r`nEndFragment:{:010}`r`n"
        headerLength := StrPut(Format(template, 0, 0, 0, 0), "UTF-8") - 1
        startFragment := headerLength + StrPut(before, "UTF-8") - 1
        endFragment := startFragment + StrPut(fragment, "UTF-8") - 1
        endHtml := endFragment + StrPut(after, "UTF-8") - 1
        return Format(template, headerLength, endHtml, startFragment, endFragment)
            . before . fragment . after
    }

    ; Set both representations in one clipboard transaction. The caller owns
    ; the previous ClipboardAll backup and restores it only if our sequence wins.
    static Write(plain, html, &ownedSequence) {
        format := this.HtmlFormat(), touched := false
        this.Open(A_ScriptHwnd)
        try {
            if DllCall("GetClipboardSequenceNumber", "UInt") != ownedSequence
                throw Error("Clipboard changed while converting. Press the shortcut again.")
            if !DllCall("EmptyClipboard", "Int")
                throw Error("Windows could not prepare the clipboard.")
            touched := true
            this.SetFormat(13, plain, "UTF-16") ; CF_UNICODETEXT
            this.SetFormat(format, html, "UTF-8")
        } finally {
            DllCall("CloseClipboard")
            if touched
                ownedSequence := DllCall("GetClipboardSequenceNumber", "UInt")
        }
    }

    static SetFormat(format, value, encoding) {
        units := StrPut(value, encoding)
        bytes := encoding = "UTF-16" ? units * 2 : units
        handle := DllCall("GlobalAlloc", "UInt", 0x2, "UPtr", bytes, "Ptr")
        if !handle
            throw Error("Windows could not allocate clipboard memory.")
        try {
            pointer := DllCall("GlobalLock", "Ptr", handle, "Ptr")
            if !pointer
                throw Error("Windows could not lock clipboard memory.")
            try StrPut(value, pointer, units, encoding)
            finally DllCall("GlobalUnlock", "Ptr", handle)
            if !DllCall("SetClipboardData", "UInt", format, "Ptr", handle, "Ptr")
                throw Error("Windows could not set the clipboard format.")
            handle := 0 ; Windows owns the HGLOBAL after SetClipboardData.
        } finally {
            if handle
                DllCall("GlobalFree", "Ptr", handle)
        }
    }
}

class RichHtml {
    ; Copying words inside one numbered list item can include the item's
    ; generated marker and <ol>/<li> wrapper. Pasting that wrapper back into
    ; the same item creates a second bullet. Keep only its inline content.
    static InlineListItem(fragment) {
        working := fragment
        Loop 2 {
            if !RegExMatch(working, "is)^\s*<div\b[^>]*>(.*)</div>\s*$", &container)
                break
            working := container[1]
        }
        if RegExMatch(working,
            "is)^\s*<(ol|ul)\b[^>]*>\s*<li\b[^>]*>(.*)</li>\s*</\1>\s*$", &item)
            content := item[2]
        else if RegExMatch(working, "is)^\s*<li\b[^>]*>(.*)</li>\s*$", &item)
            content := item[1]
        else
            return false
        if RegExMatch(content, "i)</?\s*(?:ol|ul|li)\b")
            return false
        if RegExMatch(content, "is)^\s*<p\b[^>]*>(.*)</p>\s*$", &paragraph)
            content := paragraph[1]
        if RegExMatch(content, "i)</?\s*(?:p|div)\b")
            return false
        return content
    }

    static Convert(fragment, target, source) {
        result := "", position := 1, length := StrLen(fragment)
        while position <= length {
            tagStart := InStr(fragment, "<", , position)
            if !tagStart {
                result .= this.ConvertText(SubStr(fragment, position), target, &source)
                break
            }
            result .= this.ConvertText(SubStr(fragment, position, tagStart - position),
                target, &source)
            if SubStr(fragment, tagStart, 4) = "<!--" {
                commentEnd := InStr(fragment, "-->", , tagStart + 4)
                if !commentEnd
                    throw Error("The editor supplied malformed rich content.")
                tagEnd := commentEnd + 2
            } else {
                quote := "", tagEnd := 0
                Loop length - tagStart {
                    at := tagStart + A_Index
                    character := SubStr(fragment, at, 1)
                    if quote != "" {
                        if character = quote
                            quote := ""
                    } else if character = '"' || character = "'" {
                        quote := character
                    } else if character = ">" {
                        tagEnd := at
                        break
                    }
                }
                if !tagEnd
                    throw Error("The editor supplied malformed rich content.")
            }
            tag := SubStr(fragment, tagStart, tagEnd - tagStart + 1)
            if RegExMatch(tag,
                "i)^<[ \t]*(?:script|style|img|picture|video|audio|object|embed|iframe|canvas|svg)\b")
                throw Error("The editor supplied rich content that cannot be converted safely.")
            result .= tag
            position := tagEnd + 1
        }
        return result
    }

    static ConvertText(text, target, &source) {
        global Converter
        if text = ""
            return ""
        if InStr(text, Chr(1)) || InStr(text, Chr(2))
            throw Error("The editor supplied unsupported rich text controls.")
        decoded := "", protected := [], position := 1
        while found := RegExMatch(text,
            "&(#(?:[xX][0-9A-Fa-f]+|[0-9]+)|[A-Za-z][A-Za-z0-9]+);",
            &entity, position) {
            decoded .= SubStr(text, position, found - position)
            key := entity[1], replacement := ""
            if SubStr(key, 1, 1) = "#" {
                code := SubStr(key, 2, 1) = "x" || SubStr(key, 2, 1) = "X"
                    ? Integer("0x" SubStr(key, 3)) : Integer(SubStr(key, 2))
                if code < 1 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)
                    throw Error("The editor supplied an invalid HTML character reference.")
                replacement := Chr(code)
            } else {
                names := Map("amp", "&", "lt", "<", "gt", ">", "quot", '"',
                    "apos", "'", "nbsp", Chr(160))
                if names.Has(key)
                    replacement := names[key]
                else {
                    protected.Push(entity[0])
                    replacement := Chr(1) protected.Length Chr(2)
                }
            }
            decoded .= replacement
            position := found + StrLen(entity[0])
        }
        decoded .= SubStr(text, position)
        converted := Converter.Convert(decoded, target, source)
        Loop Parse decoded {
            script := Converter.ScriptOf(A_LoopField)
            if script != ""
                source := script
        }
        converted := StrReplace(StrReplace(StrReplace(converted,
            "&", "&amp;"), "<", "&lt;"), ">", "&gt;")
        for index, original in protected
            converted := StrReplace(converted, Chr(1) index Chr(2), original)
        return converted
    }
}

ConvertFocusedText(target, window, behavior) {
    static processing := false, queue := []
    queue.Push({target: target, window: window, behavior: behavior})
    if processing
        return
    processing := true
    try {
        ; A later hotkey can arrive while an editor is still finishing a paste.
        ; Preserve its original window and run every request in press order.
        while queue.Length {
            request := queue.RemoveAt(1)
            ConvertOneFocusedText(request.target, request.window, request.behavior)
        }
    } finally {
        processing := false
    }
}

ConvertOneFocusedText(target, window, behavior) {
    global Converter
    failureMessage := "", canSwitch := false
    try {
        ; Reject an unavailable target before asking an editor to select or copy.
        Converter.RequireInstalledLayout(target)
        canSwitch := true
        ; Avoid sending Ctrl+A/V while the invoking modifiers are still down.
        keys := ["Ctrl", "Alt"]
        for name, language in KeyboardConverter.Languages
            keys.Push(language.Key)
        for key in keys
            if !KeyWait(key, "T2")
                throw Error("Release the shortcut keys, then try again.")
        if !WinActive("ahk_id " window)
            return
        field := FocusedTextField(window)
        field.Convert(target, CurrentInputLanguage(window), behavior)
    } catch Error as failure {
        failureMessage := failure.Message
    } finally {
        ; The shortcut chooses its language even when there is no editable text.
        ; Never direct a late request to another window if focus has moved.
        if canSwitch {
            try SwitchInputLanguage(window, target)
            catch Error as failure {
                failureMessage .= (failureMessage = "" ? "" : "`n") failure.Message
            }
        }
        if failureMessage != "" {
            ToolTip(failureMessage)
            SetTimer(() => ToolTip(), -3000)
        }
    }
}

CurrentInputLanguage(window) {
    global Converter
    focus := ControlGetFocus("ahk_id " window)
    recipient := focus ? focus : window
    thread := DllCall("GetWindowThreadProcessId", "Ptr", recipient, "Ptr", 0, "UInt")
    if !thread
        return "en"
    current := DllCall("GetKeyboardLayout", "UInt", thread, "Ptr") & 0xFFFF
    for name, layout in Converter.Layouts
        if (layout & 0xFFFF) = current
            return name
    return "en"
}

SwitchInputLanguage(window, target) {
    global Converter
    if !window || !WinActive("ahk_id " window)
        return
    focus := ControlGetFocus("ahk_id " window)
    recipient := focus ? focus : window
    thread := DllCall("GetWindowThreadProcessId", "Ptr", recipient, "Ptr", 0, "UInt")
    if !thread
        throw Error("Windows could not identify the focused app's input thread.")
    layout := Converter.RequireInstalledLayout(target)
    language := layout & 0xFFFF
    current := DllCall("GetKeyboardLayout", "UInt", thread, "Ptr")
    if (current & 0xFFFF) = language
        return
    ; Windows sends this message to the focused window when the user picks a
    ; language. The receiving app accepts it through its own window procedure.
    if !DllCall("PostMessageW", "Ptr", recipient, "UInt", 0x50, "UPtr", 0,
        "Ptr", layout, "Int")
        throw Error("Windows could not request the keyboard layout change.")
    deadline := A_TickCount + 1000
    while WinActive("ahk_id " window) && A_TickCount < deadline {
        current := DllCall("GetKeyboardLayout", "UInt", thread, "Ptr")
        if (current & 0xFFFF) = language
            return
        Sleep(25)
    }
    if WinActive("ahk_id " window)
        throw Error("The active app did not switch its keyboard layout.")
}

FocusedTextField(window) {
    control := ControlGetFocus("ahk_id " window)
    if control {
        controlClass := WinGetClass("ahk_id " control)
        if controlClass = "Edit"
            return NativeTextField(window, control)
        if controlClass = "Scintilla"
            return ScintillaTextField(window, control)
    }
    ; Ask only the active Chromium/Electron window for its accessibility tree.
    ; This is required before its focused editor is visible to Windows UIA.
    if InStr(WinGetClass("ahk_id " window), "Chrome_WidgetWin")
        UIA.ElementFromHandle(window)
    element := UIA.GetFocusedElement()
    return AccessibleTextField(window, element)
}

class NativeTextField {
    __New(window, control) {
        this.Window := window, this.Control := control
        style := WinGetStyle("ahk_id " control)
        if style & 0x800 || style & 0x20
            throw Error("This field is read-only or protected.")
    }

    HasFocus() => WinActive("ahk_id " this.Window)
        && ControlGetFocus("ahk_id " this.Window) = this.Control

    Selection() {
        start := Buffer(4, 0), finish := Buffer(4, 0)
        SendMessage(0xB0, start.Ptr, finish.Ptr, this.Control)
        return [NumGet(start, "UInt"), NumGet(finish, "UInt")]
    }

    SelectAll() => SendInput("^{vk41}")

    Convert(target, source := "en", behavior := "all") {
        global Converter
        if !this.HasFocus()
            return
        selection := this.Selection()
        if behavior = "selected" && selection[1] = selection[2]
            return
        text := ControlGetText(this.Control)
        if behavior = "all" && (selection[1] != 0 || selection[2] != StrLen(text)) {
            ; Let the focused editor define Select All, as a real Ctrl+A does.
            this.SelectAll()
            ; Keyboard input reaches another process asynchronously. Wait for
            ; its selection before replacing text, or a later Ctrl+A can select
            ; the freshly converted result after this shortcut has returned.
            deadline := A_TickCount + 1000
            while this.HasFocus() && A_TickCount < deadline {
                selection := this.Selection()
                text := ControlGetText(this.Control)
                if selection[1] = 0 && selection[2] = StrLen(text)
                    break
                Sleep(10)
            }
            if !this.HasFocus()
                return
            if selection[1] != 0 || selection[2] != StrLen(text)
                throw Error("Ctrl+A did not select this field's entire text.")
        }
        first := selection[1], last := selection[2]
        text := ControlGetText(this.Control)
        if first = last
            return
        if last > StrLen(text)
            throw Error("The text selection changed. Press the shortcut again.")
        original := SubStr(text, first + 1, last - first)
        converted := Converter.Convert(original, target, source)
        if !this.HasFocus()
            return
        ; These standard edit messages preserve the clipboard and provide undo.
        SendMessage(0xB1, first, last, this.Control)
        if converted != original
            SendMessage(0xC2, 1, StrPtr(converted), this.Control)
        finish := first + StrLen(converted)
        SendMessage(0xB1, finish, finish, this.Control)
    }
}

; Notepad++ uses Scintilla rather than a standard Edit or UIA text field.
; Query only pointer-free Scintilla messages across processes. Its text comes
; through the clipboard; the original formats are restored unless the user
; copies something new while conversion is in progress.
class ScintillaTextField {
    __New(window, control) {
        this.Window := window, this.Control := control
        if this.Message(2140) ; SCI_GETREADONLY
            throw Error("This field is read-only.")
    }

    HasFocus() => WinActive("ahk_id " this.Window)
        && ControlGetFocus("ahk_id " this.Window) = this.Control

    Message(code, wParam := 0, lParam := 0)
        => SendMessage(code, wParam, lParam, this.Control)

    Selection() => [this.Message(2143), this.Message(2145)]

    CheckSelection() {
        if this.Message(2570) != 1 || this.Message(2372)
            throw Error("Use one ordinary text selection or a single caret.")
    }

    Convert(target, source := "en", behavior := "all") {
        global Converter
        if !this.HasFocus()
            return
        selection := this.Selection()
        if behavior = "selected" {
            this.CheckSelection()
            if selection[1] = selection[2]
                return
        } else {
            ordinarySelection := true
            try this.CheckSelection()
            catch Error
                ordinarySelection := false
            fullSelection := ordinarySelection && selection[1] = 0
                && selection[2] = this.Message(2006)
            if !fullSelection {
                ; Let the editor perform its own Select All keyboard command.
                SendInput("^{vk41}")
                deadline := A_TickCount + 1000
                while this.HasFocus() && A_TickCount < deadline {
                    selection := this.Selection()
                    length := this.Message(2006)
                    if selection[1] = 0 && selection[2] = length {
                        ordinarySelection := true
                        try this.CheckSelection()
                        catch Error
                            ordinarySelection := false
                        if ordinarySelection
                            break
                    }
                    Sleep(10)
                }
                if !this.HasFocus()
                    return
                this.CheckSelection()
                length := this.Message(2006)
                if selection[1] != 0 || selection[2] != length
                    throw Error("Ctrl+A did not select this editor's entire text.")
            }
        }
        if selection[1] = selection[2]
            return
        originalLength := this.Message(2006)
        saved := ClipboardAll(), ownedSequence := 0
        try {
            ; Clear first so a failed copy cannot be mistaken for old text.
            A_Clipboard := ""
            ownedSequence := DllCall("GetClipboardSequenceNumber", "UInt")
            if !this.HasFocus()
                return
            this.Message(2178) ; SCI_COPY: synchronous, selected range only.
            if !ClipWait(1) || !this.HasFocus()
                throw Error("The editor did not copy its selected text.")
            ownedSequence := DllCall("GetClipboardSequenceNumber", "UInt")
            original := A_Clipboard
            if StrLen(original) > 1000000
                throw Error("Select a smaller block of text (under 1 million characters).")
            converted := Converter.Convert(original, target, source)
            this.CheckSelection()
            live := this.Selection()
            if !this.HasFocus() || this.Message(2006) != originalLength
                || live[1] != selection[1] || live[2] != selection[2]
                throw Error("The text or selection changed. Press the shortcut again.")
            if converted != original {
                if DllCall("GetClipboardSequenceNumber", "UInt") != ownedSequence
                    throw Error("Clipboard changed while converting. Press the shortcut again.")
                A_Clipboard := converted
                ownedSequence := DllCall("GetClipboardSequenceNumber", "UInt")
                if !this.HasFocus()
                    return
                if DllCall("GetClipboardSequenceNumber", "UInt") != ownedSequence
                    throw Error("Clipboard changed while converting. Press the shortcut again.")
                if !this.Message(2173) ; SCI_CANPASTE
                    throw Error("This editor cannot paste into the selection.")
                this.Message(2179) ; SCI_PASTE is synchronous and undoable.
            }
            if this.HasFocus()
                this.Message(2556, this.Message(2008)) ; SCI_SETEMPTYSELECTION
        } finally {
            if ownedSequence && DllCall("GetClipboardSequenceNumber", "UInt") = ownedSequence
                A_Clipboard := saved
        }
    }
}

class AccessibleTextField {
    __New(window, element) {
        this.Window := window, this.Element := element
        if element.IsPassword || !element.IsEnabled
            throw Error("This field is protected or disabled.")
        if element.Type != UIA.Type.Edit && element.Type != UIA.Type.Document
            throw Error("Place the caret in an editable text field first.")
        if element.IsValuePatternAvailable && element.ValueIsReadOnly
            throw Error("This text field is read-only.")
        if !element.IsTextPatternAvailable
            throw Error("This app does not expose its text selection to Windows.")
        this.Pattern := element.TextPattern
        this.GetRange()
    }

    HasFocus() => WinActive("ahk_id " this.Window)
        && UIA.CompareElements(this.Element, UIA.GetFocusedElement())

    ; Rich editors can briefly focus their selection toolbar after Ctrl+A.
    ; Refocus only the same editor in the same active window; another editor
    ; receiving focus means the user has moved on, so no paste is allowed.
    EnsureFocus() {
        if this.HasFocus()
            return true
        if !WinActive("ahk_id " this.Window)
            return false
        deadline := A_TickCount + 300
        while A_TickCount < deadline {
            if this.HasFocus()
                return true
            Sleep(25)
        }
        focused := UIA.GetFocusedElement()
        if focused.Type = UIA.Type.Edit || focused.Type = UIA.Type.Document {
            ; Codex's formatting toolbar exposes a read-only Edit element.
            ; It is not another place the user can type, so return to the
            ; original editor instead of treating the toolbar as a new field.
            if !this.IsCodexEditor() || !focused.IsValuePatternAvailable
                || !focused.ValueIsReadOnly
                return false
        }
        this.Element.SetFocus()
        return this.HasFocus()
    }

    GetRange() {
        ranges := this.Pattern.GetSelection()
        if ranges.Length = 1
            return ranges[1]
        if ranges.Length = 0 {
            ; ProseMirror exposes no TextPattern range for a plain caret.
            ; A collapsed proxy triggers Ctrl+A; its position is irrelevant
            ; because there is no selected text to replace.
            range := this.Pattern.DocumentRange.Clone()
            range.MoveEndpointByRange("Start", range, "End")
            return range
        }
        throw Error("Use one text selection or a single caret.")
    }

    ; The Codex desktop window is hosted by ChatGPT.exe in this installation.
    IsCodexEditor() {
        process := WinGetProcessName("ahk_id " this.Window)
        return process = "ChatGPT.exe" || process = "Codex.exe"
    }

    ; Codex can leave its selection toolbar open after UIA reports a caret.
    ; Escape requests dismissal without moving the insertion point. Send
    ; it only to the same focused editor; other apps retain their own behavior.
    DismissSelectionUI() {
        if !WinActive("ahk_id " this.Window) || !this.IsCodexEditor()
            return
        if !this.EnsureFocus()
            return
        SendInput("{Escape}")
        ; Escape dismisses Codex's toolbar, but the toolbar may briefly take
        ; keyboard focus as it closes. Put focus and the visible caret back in
        ; the editor before the next shortcut can inspect the focused element.
        Sleep(50)
        if this.EnsureFocus()
            this.Element.SetFocus()
    }

    CollapseByKey() => SendInput("{Right}")

    Collapse(forceKey := false) {
        range := this.GetRange()
        if forceKey || range.CompareEndpoints("Start", range, "End") != 0 {
            ; A real editor key clears the typing selection. Some providers
            ; report a collapsed UIA range even while their editor would still
            ; replace text typed next, so do not rely on UIA alone here.
            if this.EnsureFocus()
                this.CollapseByKey()
            current := this.GetRange()
            if current.CompareEndpoints("Start", current, "End") != 0 {
                deadline := A_TickCount + 300
                while WinActive("ahk_id " this.Window) && A_TickCount < deadline {
                    current := this.GetRange()
                    if current.CompareEndpoints("Start", current, "End") = 0
                        break
                    Sleep(25)
                }
                if current.CompareEndpoints("Start", current, "End") != 0 {
                    range.MoveEndpointByRange("Start", range, "End")
                    range.Select()
                    current := this.GetRange()
                    if current.CompareEndpoints("Start", current, "End") != 0
                        throw Error("The editor did not clear its selection.")
                }
            }
        }
        this.DismissSelectionUI()
    }

    ; Keep the external input operation separate so test fixtures can paste
    ; directly into their own control without competing with the user's focus.
    Paste() => SendInput("^{vk56}")

    Copy() => SendInput("^{vk43}")

    SelectAll() => SendInput("^{vk41}")

    Convert(target, source := "en", behavior := "all") {
        global Converter
        if !this.HasFocus()
            return
        restoreRange := this.GetRange(), range := restoreRange.Clone()
        if behavior = "selected" && range.CompareEndpoints("Start", range, "End") = 0
            return
        if behavior = "all" {
            document := this.Pattern.DocumentRange
            selected := range.GetText(), fullText := document.GetText()
            selectedWhole := selected != "" && (selected == fullText
                || (range.CompareEndpoints("Start", document, "Start") = 0
                && range.CompareEndpoints("End", document, "End") = 0))
            if fullText = ""
                return
            if StrLen(fullText) > 1000000
                throw Error("Select a smaller block of text (under 1 million characters).")
            plannedOriginal := fullText
            plannedConverted := Converter.Convert(fullText, target, source)
            if plannedConverted = fullText {
                ; No Ctrl+A is needed when the whole editor is already in the
                ; requested layout. Codex can report a caret while keeping a
                ; hidden typing selection, so clear it with a real editor key.
                if this.IsCodexEditor() || range.CompareEndpoints("Start", range, "End") != 0
                    this.Collapse(this.IsCodexEditor())
                return
            }
        }
        if behavior = "all" && !selectedWhole {
            ; UIA's document range can fail to select what Ctrl+A selects in
            ; an editor. Use the editor's real keyboard selection instead.
            this.SelectAll()
            deadline := A_TickCount + 1000
            selectedWhole := false
            while this.HasFocus() && A_TickCount < deadline {
                range := this.GetRange()
                document := this.Pattern.DocumentRange
                selected := range.GetText(), fullText := document.GetText()
                if selected != "" && (selected == fullText
                    || (range.CompareEndpoints("Start", document, "Start") = 0
                    && range.CompareEndpoints("End", document, "End") = 0)) {
                    selectedWhole := true
                    break
                }
                Sleep(25)
            }
            if !selectedWhole {
                restoreRange.Select()
                throw Error("Ctrl+A did not select this editor's entire text.")
            }
            if !this.EnsureFocus() {
                restoreRange.Select()
                return
            }
        }
        originalRange := range.Clone()
        original := range.GetText()
        if StrLen(original) > 1000000
            throw Error("Select a smaller block of text (under 1 million characters).")
        converted := behavior = "all" && original = plannedOriginal
            ? plannedConverted : Converter.Convert(original, target, source)
        if !this.EnsureFocus()
            return
        if converted = original {
            this.Collapse(this.IsCodexEditor())
            return
        }
        ; Use the editor's existing selection. Windows accessibility can report
        ; the correct text after Ctrl+A yet its Select() call can clear the
        ; browser's actual copy selection. Copy the editor's own rich fragment:
        ; plain paste would replace an actual list with unformatted characters.
        saved := ClipboardAll(), ownedSequence := 0, pasted := false
        try {
            if !this.EnsureFocus()
                return
            liveRange := this.GetRange()
            if originalRange.CompareEndpoints("Start", liveRange, "Start") != 0
                || originalRange.CompareEndpoints("End", liveRange, "End") != 0
                || range.GetText() != original
                throw Error("The text or selection changed. Press the shortcut again.")
            if !this.EnsureFocus()
                return
            A_Clipboard := ""
            ownedSequence := DllCall("GetClipboardSequenceNumber", "UInt")
            if !this.EnsureFocus()
                return
            this.Copy()
            if !ClipWait(1) || !this.EnsureFocus()
                throw Error("The editor did not copy its selected text.")
            ownedSequence := DllCall("GetClipboardSequenceNumber", "UInt")
            copiedPlain := A_Clipboard
            if StrLen(copiedPlain) > 1000000
                throw Error("Select a smaller block of text (under 1 million characters).")
            rich := RichClipboard.ReadHtml()
            if !rich && (!this.Element.IsValuePatternAvailable || this.IsCodexEditor())
                throw Error("This editor did not provide rich clipboard content; nothing changed.")
            ; The browser may prepend an auto-generated list marker to its
            ; clipboard copy even though the user's selection excludes it.
            markerLength := behavior = "selected"
                && RegExMatch(copiedPlain,
                    "^[ \t]*(?:[0-9]+[.)]|[-*+\x{2022}])[ \t]+", &marker)
                ? StrLen(marker[0]) : 0
            insideListItem := markerLength
                && SubStr(copiedPlain, markerLength + 1) = original
            convertedPlain := insideListItem
                ? converted : Converter.Convert(copiedPlain, target, source)
            if rich {
                sourceFragment := insideListItem
                    ? RichHtml.InlineListItem(rich.fragment) : rich.fragment
                if sourceFragment {
                    sourceLanguage := Converter.DominantSource(
                        insideListItem ? original : copiedPlain, source)
                    convertedFragment := RichHtml.Convert(sourceFragment, target, sourceLanguage)
                    if converted != original && convertedFragment = sourceFragment
                        throw Error("The editor's rich copy omitted the text to convert; nothing changed.")
                    convertedHtml := RichClipboard.Build(rich, convertedFragment)
                } else
                    rich := false ; Plain paste inside the existing list item keeps its bullet.
            }
            liveRange := this.GetRange()
            if originalRange.CompareEndpoints("Start", liveRange, "Start") != 0
                || originalRange.CompareEndpoints("End", liveRange, "End") != 0
                || liveRange.GetText() != original
                throw Error("The text or selection changed. Press the shortcut again.")
            if DllCall("GetClipboardSequenceNumber", "UInt") != ownedSequence
                throw Error("Clipboard changed while converting. Press the shortcut again.")
            if rich
                RichClipboard.Write(convertedPlain, convertedHtml, &ownedSequence)
            else {
                A_Clipboard := convertedPlain
                ownedSequence := DllCall("GetClipboardSequenceNumber", "UInt")
            }
            if !this.EnsureFocus()
                return
            this.Paste()
            pasted := true
            ; Pasting into a rich editor can briefly focus its toolbar. Keep
            ; observing the original editor's selection even while focus is
            ; elsewhere; its UIA document text can remain a stale snapshot.
            Sleep(100)
            deadline := A_TickCount + 2000
            while A_TickCount < deadline {
                current := this.GetRange()
                if current.CompareEndpoints("Start", current, "End") = 0
                    break
                Sleep(25)
            }
            if this.EnsureFocus() {
                current := this.GetRange()
                if current.CompareEndpoints("Start", current, "End") != 0 && current.GetText() != converted {
                    this.Collapse()
                    throw Error("The app did not complete the paste. Try again after it responds.")
                }
                this.Collapse()
            }
        } finally {
            ; A concurrent user copy always wins over our saved clipboard.
            if ownedSequence && DllCall("GetClipboardSequenceNumber", "UInt") = ownedSequence
                A_Clipboard := saved
            if !pasted && this.HasFocus()
                this.Collapse(this.IsCodexEditor())
        }
    }
}
