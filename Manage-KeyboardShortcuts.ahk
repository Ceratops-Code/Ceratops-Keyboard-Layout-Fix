#Requires AutoHotkey v2.0.19+

; One application-wide preference file contains data, never AHK expressions.
; The installer grants write access only to its ProgramData settings folder.
; This owner keeps one completed INI, one atomic pending file and an exclusive
; delete-on-close lock. Pending files are removed under that lock at startup,
; before saving and after failure. There is no settings history or text log.
class KeyboardShortcutSettings {
    __New(path := A_AppDataCommon "\CeratopsKeyboardLayout\Shortcuts.ini") {
        this.Path := path
        SplitPath(path, , &directory)
        this.Directory := directory
    }

    static Defaults() {
        result := Map()
        for name, language in KeyboardConverter.Languages
            result[name] := "^!" language.Key
        return result
    }

    static Parse(value) {
        if value = ""
            return {Hotkey: "", Key: "", Label: "Not assigned", Control: "", Win: false}
        if !RegExMatch(value, "^([#!^+]*)([^#!^+].*)$", &parts)
            throw Error("Choose a keyboard key with Ctrl, Alt or Win.")
        modifiers := "", label := ""
        modifierNames := Map("^", "Ctrl", "!", "Alt", "+", "Shift", "#", "Win")
        for symbol in StrSplit("^!+#") {
            if InStr(parts[1], symbol) {
                modifiers .= symbol
                label .= modifierNames[symbol] "+"
            }
        }
        if !RegExMatch(modifiers, "[\^!#]")
            throw Error("Include Ctrl, Alt or Win so ordinary typing stays available.")
        keyName := parts[2]
        if !(StrLen(keyName) = 1 || RegExMatch(keyName, "i)^[a-z][a-z0-9]*$"))
            throw Error("Choose one keyboard key, without a mouse button or custom command.")
        vk := GetKeyVK(keyName)
        if vk < 8 || vk > 254 || vk = 0x10 || vk = 0x11 || vk = 0x12
            || vk = 0x5B || vk = 0x5C || (vk >= 0xA0 && vk <= 0xA5)
            throw Error("Choose a keyboard key other than a modifier.")
        if (vk = 0x2E && InStr(modifiers, "^") && InStr(modifiers, "!"))
            || (vk = 0x4C && InStr(modifiers, "#"))
            throw Error("Windows reserves that combination. Choose another shortcut.")
        key := Format("vk{:02X}", vk)
        ; Distinguish Enter/navigation keys from their numpad equivalents.
        if vk = 0x0D || (vk >= 0x21 && vk <= 0x28) || vk = 0x2D || vk = 0x2E
            key .= Format("sc{:03X}", GetKeySC(keyName))
        display := (vk >= 0x30 && vk <= 0x39) || (vk >= 0x41 && vk <= 0x5A)
            ? Chr(vk) : GetKeyName(key)
        return {Hotkey: modifiers key, Key: key, Label: label display,
            Control: StrReplace(modifiers, "#") GetKeyName(key), Win: !!InStr(modifiers, "#")}
    }

    static CheckAssignments(values) {
        result := Map(), used := Map()
        for name in KeyboardConverter.Languages {
            shortcut := KeyboardShortcutSettings.Parse(values[name])
            if shortcut.Hotkey != "" {
                if used.Has(shortcut.Hotkey)
                    throw Error(shortcut.Label " is already assigned to "
                        KeyboardConverter.Languages[used[shortcut.Hotkey]].Name ". Choose another combination.")
                used[shortcut.Hotkey] := name
            }
            result[name] := shortcut.Hotkey
        }
        return result
    }

    ReadLocked() {
        values := KeyboardShortcutSettings.Defaults()
        if !FileExist(this.Path)
            return values
        file := this.OpenPlainFile(this.Path, 0x80000000, 3)
        try {
            if file.Length > 16384
                throw Error("The shortcut settings file is too large.")
            content := file.Read()
        } finally {
            DllCall("CloseHandle", "Ptr", file.Handle)
        }
        section := "", seen := Map()
        for line in StrSplit(content, "`n", "`r") {
            line := Trim(line, " `t" Chr(0xFEFF))
            if line = "" || SubStr(line, 1, 1) = ";"
                continue
            if RegExMatch(line, "^\[([^\]]+)\]$", &match) {
                section := match[1]
                continue
            }
            if section != "Shortcuts" || !RegExMatch(line, "^([^=]+)=(.*)$", &match)
                throw Error("The shortcut settings file has an invalid entry.")
            name := Trim(match[1])
            if !values.Has(name) || seen.Has(name)
                throw Error("The shortcut settings file has an unknown or repeated language.")
            seen[name] := true
            values[name] := Trim(match[2])
        }
        return KeyboardShortcutSettings.CheckAssignments(values)
    }

    Load() {
        if !DirExist(this.Directory)
            return KeyboardShortcutSettings.Defaults()
        handles := this.AcquireLock()
        try {
            this.RemovePending()
            return this.ReadLocked()
        } finally {
            this.ReleaseLock(handles)
        }
    }

    Save(values) {
        values := KeyboardShortcutSettings.CheckAssignments(values)
        if !DirExist(this.Directory)
            DirCreate(this.Directory)
        handles := this.AcquireLock()
        try {
            this.RemovePending()
            content := "[Shortcuts]`r`n"
            for name, value in values
                content .= name "=" value "`r`n"
            file := this.OpenPlainFile(this.Path ".pending", 0x40000000, 1)
            try {
                if file.Write(content) != StrPut(content, "UTF-8") - 1
                    throw Error("Windows did not write the complete shortcut settings.")
                if !DllCall("FlushFileBuffers", "Ptr", file.Handle)
                    throw OSError()
            } finally {
                DllCall("CloseHandle", "Ptr", file.Handle)
            }
            ; Replace the directory entry, never write through a destination link.
            if !DllCall("MoveFileEx", "Str", this.Path ".pending", "Str", this.Path, "UInt", 0x9)
                throw OSError()
        } finally {
            try this.RemovePending()
            this.ReleaseLock(handles)
        }
    }

    AcquireLock() {
        ; Users can edit settings, so even an elevated tray must not follow
        ; reparse points or write through a substituted folder/file. Holding
        ; the directory without delete sharing prevents a rename while saving.
        directory := DllCall("CreateFile", "Str", this.Directory, "UInt", 0x80,
            "UInt", 3, "Ptr", 0, "UInt", 3, "UInt", 0x02200000, "Ptr", 0, "Ptr")
        if directory = -1
            throw OSError()
        try {
            KeyboardShortcutSettings.RejectReparsePoint(directory)
            lock := DllCall("CreateFile", "Str", this.Path ".lock", "UInt", 0xC0010000,
                "UInt", 0, "Ptr", 0, "UInt", 4, "UInt", 0x04200000, "Ptr", 0, "Ptr")
            if lock = -1
                throw Error("Shortcut settings are busy or not writable. Try again after the other settings window closes.")
            try KeyboardShortcutSettings.RejectReparsePoint(lock)
            catch {
                DllCall("CloseHandle", "Ptr", lock)
                throw
            }
            return [directory, lock]
        } catch {
            DllCall("CloseHandle", "Ptr", directory)
            throw
        }
    }

    static RejectReparsePoint(handle) {
        information := Buffer(52)
        if !DllCall("GetFileInformationByHandle", "Ptr", handle, "Ptr", information)
            throw OSError()
        if NumGet(information, 0, "UInt") & 0x400
            throw Error("Shortcut settings cannot use a symbolic link or junction.")
    }

    OpenPlainFile(path, access, creation) {
        handle := DllCall("CreateFile", "Str", path, "UInt", access,
            "UInt", 1, "Ptr", 0, "UInt", creation, "UInt", 0x00200080, "Ptr", 0, "Ptr")
        if handle = -1
            throw OSError()
        try {
            KeyboardShortcutSettings.RejectReparsePoint(handle)
            ; Handle wrappers neither own nor close the OS handle. Callers
            ; explicitly close it; reading Handle also flushes AHK's buffer.
            file := FileOpen(handle, "h")
            file.Encoding := "UTF-8"
            return file
        } catch {
            DllCall("CloseHandle", "Ptr", handle)
            throw
        }
    }

    RemovePending() {
        if FileExist(this.Path ".pending")
            FileDelete(this.Path ".pending")
    }

    ReleaseLock(handles) {
        for handle in [handles[2], handles[1]]
            DllCall("CloseHandle", "Ptr", handle)
    }
}

class KeyboardShortcutManager {
    static TrayOwner := 0

    __New(converter, settings := unset) {
        this.Converter := converter
        this.Settings := IsSet(settings) ? settings : KeyboardShortcutSettings()
        this.Assignments := KeyboardShortcutSettings.Defaults()
        this.Registered := Map(), this.HeldKeys := Map(), this.Pending := 0
        this.Requests := [], this.Processing := false, this.Dialog := 0
        this.Dispatch := this.ProcessRequests.Bind(this)
        this.SingleTap := this.ExpireSingleTap.Bind(this)
        this.Context := this.CanHandleShortcut.Bind(this)
        this.MenuOpen := false, this.MenuFont := 0, this.MenuRows := Map()
        this.SuppressLeftUp := false
        this.OpenMenu := this.ShowTrayMenu.Bind(this)
        this.OpenSettings := this.ShowSettings.Bind(this)
    }

    Start() {
        warning := ""
        try this.Assignments := this.Settings.Load()
        catch Error as failure {
            WriteAppError("settings.load-failed", failure)
            warning := "Using default shortcuts. " failure.Message
        }
        this.ReplaceBindings(this.Assignments)
        this.RebuildTray()
        if warning != ""
            TrayTip(warning, "Ceratops Keyboard Layout")
    }

    CanHandleShortcut(*) => !this.Dialog || !WinActive("ahk_id " this.Dialog.Hwnd)

    ReplaceBindings(values) {
        bindings := Map()
        for name, value in values {
            shortcut := KeyboardShortcutSettings.Parse(value)
            if value = ""
                continue
            bindings["$" value] := this.OnPress.Bind(this, name, shortcut.Key)
            bindings["~*" shortcut.Key " up"] := this.OnRelease.Bind(this, shortcut.Key)
        }
        old := this.Registered
        HotIf(this.Context)
        try {
            for key, callback in bindings
                Hotkey(key, callback, "On T1 I0")
            for key in old
                if !bindings.Has(key)
                    Hotkey(key, "Off")
            this.Registered := bindings
            this.ResetTap()
        } catch {
            for key in bindings
                if !old.Has(key)
                    try Hotkey(key, "Off")
            for key, callback in old
                Hotkey(key, callback, "On")
            throw
        } finally {
            HotIf()
        }
    }

    OnPress(target, key, *) {
        if this.HeldKeys.Has(key)
            return
        this.HeldKeys[key] := true
        this.AcceptPress(target, WinExist("A"), A_TickCount)
    }

    OnRelease(key, *) {
        if this.HeldKeys.Has(key)
            this.HeldKeys.Delete(key)
    }

    AcceptPress(target, window, time) {
        last := this.Pending
        doubleTap := IsObject(last) && last.Target = target && last.Window = window
            && time >= last.Time && time - last.Time <= 350
        if doubleTap {
            SetTimer(this.SingleTap, 0)
            this.Pending := 0
            last.Behavior := "all"
            this.QueueRequest(last)
            return
        }
        ; A different shortcut cannot complete the previous double tap.
        this.ExpireSingleTap()
        this.Pending := {Target: target, Window: window, Time: time, Behavior: "selected"}
        ; Decide from the first key-down, even if the key remains held. Running
        ; the selection action first would remap punctuation twice on double tap.
        SetTimer(this.SingleTap, -350)
    }

    ExpireSingleTap() {
        if !IsObject(this.Pending)
            return
        request := this.Pending
        this.Pending := 0
        SetTimer(this.SingleTap, 0)
        this.QueueRequest(request)
    }

    QueueRequest(request) {
        this.Requests.Push(request)
        this.ScheduleDispatch()
    }

    ScheduleDispatch() {
        if !this.Processing && this.Requests.Length {
            this.Processing := true
            SetTimer(this.Dispatch, -1)
        }
    }

    ResetTap() {
        SetTimer(this.SingleTap, 0)
        this.Pending := 0, this.HeldKeys := Map()
    }

    ProcessRequests() {
        try {
            while this.Requests.Length {
                request := this.Requests.RemoveAt(1)
                ConvertOneFocusedText(request.Target, request.Window, request.Behavior)
            }
        } finally {
            this.Processing := false
            ; A hotkey can append after the loop observed an empty queue. Its
            ; original window/order stay queued; never wait for another key.
            ; If it arrives after this reset, QueueRequest already schedules it.
            this.ScheduleDispatch()
        }
    }

    InstalledRows() {
        rows := []
        for name, language in KeyboardConverter.Languages
            if this.Converter.Layouts.Has(name)
                rows.Push({Name: name, Language: language.Name,
                    Shortcut: KeyboardShortcutSettings.Parse(this.Assignments[name])})
        return rows
    }

    RebuildTray() {
        rows := this.InstalledRows()
        layout := this.MeasureTrayColumns(rows)
        previousOwner := KeyboardShortcutManager.TrayOwner
        ; Native items borrow our buffers and font until they are removed.
        A_TrayMenu.Delete()
        if previousOwner
            previousOwner.ReleaseMenuFont()
        this.MenuFont := layout.Font, this.MenuLayout := layout, this.MenuRows := Map()
        KeyboardShortcutManager.TrayOwner := this
        ; One router follows the current owner, including after a settings or
        ; layout rebuild. Old managers cannot paint a newer manager's menu.
        static listener := (w, l, message, hwnd) => KeyboardShortcutManager.TrayOwner.RouteTrayMessage(w, l, message, hwnd)
        static listening := false
        if !listening {
            for message in [0x404, 0x2B, 0x2C]
                OnMessage(message, listener)
            listening := true
        }
        for index, row in rows {
            label := row.Language "`t" row.ShortcutText
            A_TrayMenu.Add(label, this.ShowSettings.Bind(this))
            itemId := DllCall("GetMenuItemID", "Ptr", A_TrayMenu.Handle, "Int", index - 1, "UInt")
            ; MSAAMENUINFO keeps a spoken name for Windows accessibility even
            ; though these two text columns are drawn by this app.
            row.AccessibleText := Buffer((StrLen(label) + 1) * 2, 0)
            StrPut(label, row.AccessibleText, "UTF-16")
            row.AccessibleInfo := Buffer(A_PtrSize = 8 ? 16 : 12, 0)
            NumPut("UInt", 0xAA0DF00D, "UInt", StrLen(label), row.AccessibleInfo)
            NumPut("Ptr", row.AccessibleText.Ptr, row.AccessibleInfo, 8)
            item := Buffer(A_PtrSize = 8 ? 80 : 48, 0)
            NumPut("UInt", item.Size, "UInt", 0x120, "UInt", 0x100, item)
            NumPut("Ptr", row.AccessibleInfo.Ptr, item, A_PtrSize = 8 ? 48 : 32)
            if !DllCall("SetMenuItemInfoW", "Ptr", A_TrayMenu.Handle, "UInt", index - 1,
                "Int", true, "Ptr", item)
                throw OSError()
            this.MenuRows[itemId] := row
        }
        if !this.Converter.Layouts.Count {
            A_TrayMenu.Add("No supported keyboards installed", (*) => 0)
            A_TrayMenu.Disable("No supported keyboards installed")
        }
        A_TrayMenu.Add()
        A_TrayMenu.Add("Single tap: selection", (*) => 0)
        A_TrayMenu.Disable("Single tap: selection")
        A_TrayMenu.Add("Double tap: all text", (*) => 0)
        A_TrayMenu.Disable("Double tap: all text")
        settingsItem := "Change key combinations..."
        A_TrayMenu.Add(settingsItem, this.ShowSettings.Bind(this))
        if !this.Converter.Layouts.Count
            A_TrayMenu.Disable(settingsItem)
        A_TrayMenu.Default := settingsItem
        A_TrayMenu.ClickCount := 2
        A_TrayMenu.Add("Check for updates", (*) => StartAppUpdateCheck(true))
        A_TrayMenu.Add("Force restart Ceratops", StartAppForceRestart)
        if !AppServiceIsInstalled()
            A_TrayMenu.Disable("Force restart Ceratops")
        A_TrayMenu.Add()
        version := GetAppVersionText()
        versionItem := version = "" ? "Version unavailable" : "Version " version
        A_TrayMenu.Add(versionItem, (*) => 0)
        A_TrayMenu.Disable(versionItem)
        A_TrayMenu.Add("Exit", (*) => ExitApp())
    }

    ReleaseMenuFont() {
        if this.MenuFont
            DllCall("Gdi32\DeleteObject", "Ptr", this.MenuFont)
        this.MenuFont := 0
    }

    MeasureTrayColumns(rows) {
        ; Use the actual Windows menu font, not spaces or an assumed character
        ; width. Both columns begin at fixed pixel positions at the current DPI.
        dpi := DllCall("GetDpiForWindow", "Ptr", A_ScriptHwnd, "UInt")
        metrics := Buffer(504, 0)
        NumPut("UInt", metrics.Size, metrics)
        if !DllCall("SystemParametersInfoForDpi", "UInt", 0x29, "UInt", metrics.Size,
            "Ptr", metrics, "UInt", 0, "UInt", dpi)
            throw OSError()
        font := DllCall("Gdi32\CreateFontIndirectW", "Ptr", metrics.Ptr + 224, "Ptr")
        if !font
            throw OSError()
        dc := DllCall("GetDC", "Ptr", 0, "Ptr")
        prior := DllCall("Gdi32\SelectObject", "Ptr", dc, "Ptr", font, "Ptr")
        languageWidth := 0, shortcutWidth := 0, textHeight := 0
        try {
            for row in rows {
                row.ShortcutText := StrReplace(row.Shortcut.Label, "+", " + ")
                for text in [row.Language, row.ShortcutText] {
                    size := Buffer(8, 0)
                    if !DllCall("Gdi32\GetTextExtentPoint32W", "Ptr", dc, "Str", text,
                        "Int", StrLen(text), "Ptr", size)
                        throw OSError()
                    if text = row.Language
                        languageWidth := Max(languageWidth, NumGet(size, 0, "Int"))
                    else
                        shortcutWidth := Max(shortcutWidth, NumGet(size, 0, "Int"))
                    textHeight := Max(textHeight, NumGet(size, 4, "Int"))
                }
            }
        } catch {
            DllCall("Gdi32\SelectObject", "Ptr", dc, "Ptr", prior)
            DllCall("Gdi32\DeleteObject", "Ptr", font)
            throw
        } finally {
            DllCall("Gdi32\SelectObject", "Ptr", dc, "Ptr", prior)
            DllCall("ReleaseDC", "Ptr", 0, "Ptr", dc)
        }
        left := Round(24 * dpi / 96), gap := Round(16 * dpi / 96)
        return {Font: font, LanguageX: left, ShortcutX: left + languageWidth + gap,
            Width: left + languageWidth + gap + shortcutWidth + Round(12 * dpi / 96),
            Height: Max(textHeight + Round(8 * dpi / 96),
                DllCall("GetSystemMetricsForDpi", "Int", 15, "UInt", dpi)), Gap: gap}
    }

    RouteTrayMessage(wParam, lParam, message, hwnd) {
        if message = 0x404
            return this.OnTrayMessage(wParam, lParam)
        if NumGet(lParam, 0, "UInt") != 1 || !this.MenuRows.Has(NumGet(lParam, 8, "UInt"))
            return
        if message = 0x2C {
            NumPut("UInt", this.MenuLayout.Width, "UInt", this.MenuLayout.Height, lParam, 12)
            return true
        }
        return this.DrawTrayRow(lParam)
    }

    DrawTrayRow(data) {
        pointerOffset := A_PtrSize = 8 ? 24 : 20
        if NumGet(data, pointerOffset, "Ptr") != A_TrayMenu.Handle
            return
        dc := NumGet(data, pointerOffset + A_PtrSize, "Ptr")
        rectangle := data + pointerOffset + A_PtrSize * 2
        row := this.MenuRows[NumGet(data, 8, "UInt")]
        selected := NumGet(data, 16, "UInt") & 1
        state := selected ? 2 : 1
        saved := DllCall("Gdi32\SaveDC", "Ptr", dc)
        theme := DllCall("UxTheme\OpenThemeData", "Ptr", A_ScriptHwnd, "Str", "Menu", "Ptr")
        try {
            DllCall("Gdi32\SelectObject", "Ptr", dc, "Ptr", this.MenuFont)
            DllCall("Gdi32\SetBkMode", "Ptr", dc, "Int", 1)
            DllCall("FillRect", "Ptr", dc, "Ptr", rectangle,
                "Ptr", DllCall("GetSysColorBrush", "Int", selected && !theme ? 13 : 4, "Ptr"))
            if theme
                DllCall("UxTheme\DrawThemeBackground", "Ptr", theme, "Ptr", dc,
                    "Int", 14, "Int", state, "Ptr", rectangle, "Ptr", 0)
            else
                DllCall("Gdi32\SetTextColor", "Ptr", dc, "UInt",
                    DllCall("GetSysColor", "Int", selected ? 14 : 7, "UInt"))
            this.DrawTrayColumn(dc, rectangle, row.Language, this.MenuLayout.LanguageX,
                this.MenuLayout.ShortcutX - this.MenuLayout.Gap, theme, state)
            this.DrawTrayColumn(dc, rectangle, row.ShortcutText, this.MenuLayout.ShortcutX,
                this.MenuLayout.Width, theme, state)
        } finally {
            if theme
                DllCall("UxTheme\CloseThemeData", "Ptr", theme)
            DllCall("Gdi32\RestoreDC", "Ptr", dc, "Int", saved)
        }
        return true
    }

    DrawTrayColumn(dc, rowRectangle, text, start, finish, theme, state) {
        rectangle := Buffer(16, 0)
        DllCall("RtlMoveMemory", "Ptr", rectangle, "Ptr", rowRectangle, "UPtr", 16)
        left := NumGet(rectangle, 0, "Int")
        NumPut("Int", left + start, rectangle, 0)
        NumPut("Int", left + finish, rectangle, 8)
        ; DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX keeps the first
        ; symbol fixed even when saved combinations have different lengths.
        if theme
            DllCall("UxTheme\DrawThemeText", "Ptr", theme, "Ptr", dc, "Int", 14,
                "Int", state, "Str", text, "Int", -1, "UInt", 0x824, "UInt", 0, "Ptr", rectangle)
        else
            DllCall("DrawTextW", "Ptr", dc, "Str", text, "Int", -1, "Ptr", rectangle, "UInt", 0x824)
    }

    Refresh() {
        this.Converter.RefreshInstalledLayouts()
        values := this.Settings.Load()
        changed := false
        for name, value in values
            if value != this.Assignments[name]
                changed := true
        if changed {
            this.ReplaceBindings(values)
            this.Assignments := values
        }
        this.RebuildTray()
    }

    OnTrayMessage(wParam, lParam, *) {
        event := lParam & 0xFFFF
        if event = 0x406 || event = 0x407
            return 0 ; NIN_POPUPOPEN/CLOSE: this icon has no hover interface.
        if event = 0x201 {
            this.SuppressLeftUp := false
            return
        }
        if event = 0x203 {
            this.SuppressLeftUp := true
            SetTimer(this.OpenMenu, 0)
            if this.MenuOpen
                DllCall("EndMenu")
            SetTimer(this.OpenSettings, -1)
            return 0
        }
        if event = 0x202 {
            ; The first up precedes a possible double-click. Wait for Windows'
            ; interval, then consume the final up of a double-click so it cannot
            ; schedule a stray popup over the settings window. A new down resets
            ; the flag even when an earlier release occurred outside the icon.
            suppressed := this.SuppressLeftUp
            this.SuppressLeftUp := false
            if !suppressed && !this.MenuOpen
                SetTimer(this.OpenMenu, -DllCall("GetDoubleClickTime", "UInt"))
            return 0
        }
        if event = 0x205 || event = 0x7B || event = 0x400 || event = 0x401 {
            if !this.MenuOpen
                SetTimer(this.OpenMenu, -1)
            return 0
        }
    }

    ShowTrayMenu(*) {
        if this.MenuOpen
            return
        this.MenuOpen := true
        try {
            try this.Refresh()
            catch Error as failure
                TrayTip(failure.Message, "Ceratops Keyboard Layout")
            this.ShowNativeTrayMenu()
        } finally this.MenuOpen := false
    }

    ShowNativeTrayMenu() => A_TrayMenu.Show()

    ShowSettings(*) {
        if this.Dialog {
            this.Dialog.Show()
            return
        }
        try this.Refresh()
        catch Error as failure {
            MsgBox(failure.Message, "Ceratops Keyboard Layout", "Icon!")
            return
        }
        dialog := this.CreateSettingsDialog()
        this.Dialog := dialog, this.Controls := Map()
        dialog.SetFont("s10", "Segoe UI")
        dialog.AddText("w600", "Press a combination in a box. Include Ctrl, Alt or WinKey.`nLeave a box empty to disable that combination.")
        for row in this.InstalledRows() {
            dialog.AddText("xm y+12 w130 h26 +0x200", row.Language)
            ; A narrow caption can leak letter fragments at another DPI. Draw
            ; no caption; annotate its accessible name separately. The visible
            ; label follows the flag, with the same centers and x's in each row.
            winControl := dialog.AddCheckbox("x+10 yp w18 h26")
            this.SetCheckboxAccessibleName(winControl, "WinKey")
            winIcon := dialog.AddText("x+2 yp w22 h26 +0x201", Chr(0xF0FF))
            ; Wingdings ships with Windows and supplies its recognizable flag
            ; glyph. Keep the symbol in its own control and font.
            winIcon.SetFont("s16 cBlack", "Wingdings")
            winIcon.GetPos(&iconX, &iconY)
            winLabel := dialog.AddText("x" (iconX + 26) " y" iconY " w68 h26 +0x200", "WinKey +")
            winIcon.OnEvent("Click", this.ToggleWindowsModifier.Bind(this, winControl))
            winLabel.OnEvent("Click", this.ToggleWindowsModifier.Bind(this, winControl))
            hotkeyControl := dialog.AddHotkey("x+8 yp w235 h26", row.Shortcut.Control)
            winControl.Value := row.Shortcut.Win
            this.Controls[row.Name] := {Hotkey: hotkeyControl, Win: winControl,
                WindowsIcon: winIcon, WindowsLabel: winLabel}
        }
        dialog.AddText("xm y+18 w600", "One press converts the selection after a 350 ms double-tap window.`nHold the modifiers and tap the same key twice to select all`nand convert. Neither action waits for you to release the keys.")
        this.Status := dialog.AddText("xm y+12 w600 cRed", "")
        dialog.AddButton("xm y+8 w130", "Restore defaults").OnEvent("Click", this.RestoreDefaults.Bind(this))
        dialog.AddButton("x+55 w100 Default", "Save").OnEvent("Click", this.SaveDialog.Bind(this))
        dialog.AddButton("x+10 w100", "Cancel").OnEvent("Click", this.CloseDialog.Bind(this))
        dialog.OnEvent("Close", this.CloseDialog.Bind(this))
        dialog.OnEvent("Escape", this.CloseDialog.Bind(this))
        this.ResetTap()
        dialog.Show()
    }

    ToggleWindowsModifier(control, *) => control.Value := !control.Value

    SetCheckboxAccessibleName(control, name := "") {
        ; Windows' dynamic annotation keeps the native checkbox usable by
        ; screen readers without drawing hidden text. This app's x64 runtime
        ; passes the 16-byte by-value GUID indirectly. An empty name removes
        ; our annotation before the owned checkbox HWND is destroyed.
        static service := ComObject("{B5F8350B-0548-48B1-A6EE-88BD00B4A5E7}",
            "{6E26E776-04F0-495D-80E4-3330352E3169}")
        static property := Buffer(16, 0)
        if !NumGet(property, 0, "UInt")
            DllCall("Ole32\CLSIDFromString", "WStr", "{608D3DF8-8128-4AA7-A428-F55E49267291}",
                "Ptr", property, "HResult")
        if name != ""
            ComCall(7, service, "Ptr", control.Hwnd, "UInt", 0xFFFFFFFC, "UInt", 0,
                "Ptr", property, "WStr", name)
        else
            ComCall(9, service, "Ptr", control.Hwnd, "UInt", 0xFFFFFFFC, "UInt", 0,
                "Ptr", property, "Int", 1)
    }

    ; The factory keeps native Show interruption checks out of GUI construction.
    CreateSettingsDialog() => Gui(, "Ceratops Keyboard Layout - Key Combinations")

    RestoreDefaults(*) {
        defaults := KeyboardShortcutSettings.Defaults()
        for name, control in this.Controls {
            control.Hotkey.Value := KeyboardShortcutSettings.Parse(defaults[name]).Control
            control.Win.Value := false
        }
        this.Status.Text := ""
    }

    Apply(values) {
        values := KeyboardShortcutSettings.CheckAssignments(values)
        old := this.Assignments
        this.ReplaceBindings(values)
        try this.Settings.Save(values)
        catch {
            this.ReplaceBindings(old)
            throw
        }
        this.Assignments := values
        this.RebuildTray()
    }

    SaveDialog(*) {
        try {
            this.Converter.RefreshInstalledLayouts()
            values := this.Assignments.Clone()
            for name, control in this.Controls {
                if !this.Converter.Layouts.Has(name)
                    throw Error("The installed keyboards changed. Close this window and open it again.")
                value := control.Hotkey.Value
                values[name] := value = "" ? "" : (control.Win.Value ? "#" : "") value
            }
            this.Apply(values)
            this.CloseDialog()
        } catch Error as failure {
            this.Status.Text := failure.Message
        }
    }

    CloseDialog(*) {
        if this.Dialog {
            for name, control in this.Controls
                this.SetCheckboxAccessibleName(control.Win)
            this.Dialog.Destroy()
        }
        this.Dialog := 0
        this.ResetTap()
    }
}
