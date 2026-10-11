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
    __New(converter, settings := unset) {
        this.Converter := converter
        this.Settings := IsSet(settings) ? settings : KeyboardShortcutSettings()
        this.Assignments := KeyboardShortcutSettings.Defaults()
        this.Registered := Map(), this.HeldKeys := Map(), this.Pending := 0
        this.Requests := [], this.Processing := false, this.Dialog := 0
        this.Dispatch := this.ProcessRequests.Bind(this)
        this.SingleTap := this.ExpireSingleTap.Bind(this)
        this.Context := this.CanHandleShortcut.Bind(this)
    }

    Start() {
        warning := ""
        try this.Assignments := this.Settings.Load()
        catch Error as failure
            warning := "Using default shortcuts. " failure.Message
        this.ReplaceBindings(this.Assignments)
        this.RebuildTray()
        ; AutoHotkey's tray callback precedes its standard context menu.
        this.TrayCallback := this.OnTrayMessage.Bind(this)
        OnMessage(0x404, this.TrayCallback)
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
        A_TrayMenu.Delete()
        ; A native tab separates the language and accelerator columns, so
        ; proportional characters and custom combinations cannot shift names.
        for row in this.InstalledRows()
            A_TrayMenu.Add(row.Language "`t" StrReplace(row.Shortcut.Label, "+", " + "),
                this.ShowSettings.Bind(this))
        if !this.Converter.Layouts.Count {
            A_TrayMenu.Add("No supported keyboards installed", (*) => 0)
            A_TrayMenu.Disable("No supported keyboards installed")
        }
        A_TrayMenu.Add()
        A_TrayMenu.Add("Single tap: convert selected text", (*) => 0)
        A_TrayMenu.Disable("Single tap: convert selected text")
        A_TrayMenu.Add("Double tap: select all and convert", (*) => 0)
        A_TrayMenu.Disable("Double tap: select all and convert")
        settingsItem := "Change key combinations..."
        A_TrayMenu.Add(settingsItem, this.ShowSettings.Bind(this))
        if !this.Converter.Layouts.Count
            A_TrayMenu.Disable(settingsItem)
        A_TrayMenu.Default := settingsItem
        A_TrayMenu.ClickCount := 2
        A_TrayMenu.Add("Check for updates", (*) => StartAppUpdateCheck(true))
        A_TrayMenu.Add()
        A_TrayMenu.Add("Exit Ceratops Keyboard Layout", (*) => ExitApp())
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
        if (lParam & 0xFFFF) = 0x205 || (lParam & 0xFFFF) = 0x7B {
            try this.Refresh()
            catch Error as failure
                TrayTip(failure.Message, "Ceratops Keyboard Layout")
        }
    }

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
            ; Keep a checkbox name for accessibility; its visible label follows
            ; the Windows symbol. All rows use the same vertical center and x's.
            winControl := dialog.AddCheckbox("x+10 yp w18 h26", "WinKey")
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
        if this.Dialog
            this.Dialog.Destroy()
        this.Dialog := 0
        this.ResetTap()
    }
}
