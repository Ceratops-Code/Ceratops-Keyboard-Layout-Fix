#Requires AutoHotkey v2.0.19+
#Include ..\CeratopsKeyboardLayout.ahk
#Include ..\CeratopsKeyboardLayout-Service.ahk
; Popup observers are separate workers of this same test file. Each owns a
; PID-specific temp root and must not terminate the parent test process.
#SingleInstance Off
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
class CompanionStopProbe {
    __New(boundary := "") {
        this.Boundary := boundary, this.Running := true, this.Closed := false
        this.Stuck := false
    }
    Wait(handle, milliseconds) => this.Stuck || this.Running ? 0x102 : 0
    Terminate(handle) {
        if this.Boundary = "before"
            throw Error("stop-test-interruption")
        this.Running := false
        if this.Boundary = "after"
            throw Error("stop-test-interruption")
    }
    Close(handle) => this.Closed := true
}

class DailyUpdateProbe {
    __New(effect := "", boundary := "") {
        this.Effect := effect, this.Boundary := boundary, this.Due := "", this.Launches := 0, this.Busy := false
    }
    ReadNextCheck() => this.Due
    InstallationIsBusy() => this.Busy
    At(effect, boundary) {
        if this.Effect = effect && this.Boundary = boundary
            throw Error("daily-update-test-interruption")
    }
    SaveNextCheck(value) {
        this.At("schedule", "before")
        this.Due := value
        this.At("schedule", "after")
    }
    Launch() {
        this.At("launch", "before")
        this.Launches += 1
        this.At("launch", "after")
    }
}

RequireUnlockedTrayDesktop() {
    ; Use the session's lock state rather than racing an ephemeral LockApp HWND.
    session := 0, information := 0, size := 0
    if !DllCall("ProcessIdToSessionId", "UInt", DllCall("GetCurrentProcessId", "UInt"), "UInt*", &session)
        || !DllCall("wtsapi32\WTSQuerySessionInformationW", "Ptr", 0, "UInt", session,
            "Int", 25, "Ptr*", &information, "UInt*", &size)
        throw OSError()
    try {
        ; WTSINFOEXW level 1: Data begins at byte 8; SessionFlags is byte 16.
        if size < 20 || NumGet(information, 0, "UInt") != 1
            throw Error("Windows did not expose a usable session lock state")
        if NumGet(information, 16, "UInt") = 0
            throw Error("Windows is locked; unlock the desktop for the physical hover check", , "LOCKED")
        if NumGet(information, 16, "UInt") != 1
            throw Error("Windows returned an unknown session lock state")
    } finally DllCall("wtsapi32\WTSFreeMemory", "Ptr", information)
    tray := WinExist("ahk_class Shell_TrayWnd")
    if !tray
        throw Error("Windows has no accessible taskbar")
    return tray
}

CaptureTrayHover(path, x, y) {
    ; Capture only the tray region, including layered tooltip windows. All GDI
    ; handles belong to this test; the caller owns the one temporary PNG.
    x := Max(SysGet(76), x - 180), y := Max(SysGet(77), y - 180)
    width := 360, height := 240, token := 0, bitmap := 0, picture := 0, memory := 0
    ; Keep GDI+ loaded until every image and its startup token are released.
    graphicsModule := DllCall("LoadLibraryW", "Str", "gdiplus.dll", "Ptr")
    if !graphicsModule
        throw OSError()
    desktop := DllCall("GetDC", "Ptr", 0, "Ptr")
    try {
        memory := DllCall("gdi32\CreateCompatibleDC", "Ptr", desktop, "Ptr")
        bitmap := DllCall("gdi32\CreateCompatibleBitmap", "Ptr", desktop, "Int", width, "Int", height, "Ptr")
        if !desktop || !memory || !bitmap
            throw OSError()
        previous := DllCall("gdi32\SelectObject", "Ptr", memory, "Ptr", bitmap, "Ptr")
        if !DllCall("gdi32\BitBlt", "Ptr", memory, "Int", 0, "Int", 0, "Int", width,
            "Int", height, "Ptr", desktop, "Int", x, "Int", y, "UInt", 0x40CC0020)
            throw OSError()
        DllCall("gdi32\SelectObject", "Ptr", memory, "Ptr", previous)
        input := Buffer(24, 0), encoder := Buffer(16, 0)
        NumPut("UInt", 1, input)
        status := DllCall("gdiplus\GdiplusStartup", "Ptr*", &token, "Ptr", input, "Ptr", 0)
        if status
            throw Error("GdiplusStartup failed: " status)
        status := DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", bitmap, "Ptr", 0, "Ptr*", &picture)
        if status
            throw Error("GdipCreateBitmapFromHBITMAP failed: " status)
        DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", encoder)
        status := DllCall("gdiplus\GdipSaveImageToFile", "Ptr", picture, "Str", path, "Ptr", encoder, "Ptr", 0)
        if status
            throw Error("GdipSaveImageToFile failed: " status " target=" path)
    } finally {
        if picture
            DllCall("gdiplus\GdipDisposeImage", "Ptr", picture)
        if token
            DllCall("gdiplus\GdiplusShutdown", "Ptr", token)
        if bitmap
            DllCall("gdi32\DeleteObject", "Ptr", bitmap)
        if memory
            DllCall("gdi32\DeleteDC", "Ptr", memory)
        if desktop
            DllCall("ReleaseDC", "Ptr", 0, "Ptr", desktop)
        DllCall("FreeLibrary", "Ptr", graphicsModule)
    }
}

CheckPhysicalTrayHover(root) {
    DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
    if FileExist(root "\_tray-hover.png")
        FileDelete(root "\_tray-hover.png")
    tray := RequireUnlockedTrayDesktop()
    CoordMode("Mouse", "Screen")
    MouseGetPos(&originalX, &originalY)
    opened := false, chevron := 0
    try {
        A_IconTip := "" ; Reproduce the former empty-tooltip input to the shell.
        InitializeAppTray(GetServiceAppDirectory() "\CeratopsKeyboardLayout.ico")
        ; This fixture creates only its own tray icon, without global shortcuts,
        ; shared settings, update workers or changes to the installed service.
        hoverManager := KeyboardShortcutManager(Converter, KeyboardShortcutSettings(root "\_hover-shortcuts.ini"))
        hoverManager.RebuildTray()
        if !WinExist("ahk_class TopLevelWindowForOverflowXamlIsland") {
            trayElement := UIA.ElementFromHandle(tray)
            try chevron := trayElement.FindElement({Name: "Show Hidden Icons", AutomationId: "SystemTrayIcon"})
            catch Error as failure
                throw Error("Tray overflow control unavailable: " failure.Message "`n" trayElement.DumpAll(" ", 6))
            chevron.InvokePattern.Invoke()
            opened := true
            Sleep(300)
        }
        identifier := Buffer(40, 0), rectangle := Buffer(16, 0)
        NumPut("UInt", 40, identifier)
        NumPut("Ptr", A_ScriptHwnd, identifier, 8)
        NumPut("UInt", 0x404, identifier, 16)
        if DllCall("Shell32\Shell_NotifyIconGetRect", "Ptr", identifier, "Ptr", rectangle, "Int")
            throw Error("Windows did not expose the candidate tray icon rectangle")
        x := (NumGet(rectangle, 0, "Int") + NumGet(rectangle, 8, "Int")) // 2
        y := (NumGet(rectangle, 4, "Int") + NumGet(rectangle, 12, "Int")) // 2
        RequireUnlockedTrayDesktop()
        cover := DllCall("WindowFromPoint", "Int64", (x & 0xFFFFFFFF) | (y << 32), "Ptr")
        surface := DllCall("GetAncestor", "Ptr", cover, "UInt", 2, "Ptr")
        overflow := WinExist("ahk_class TopLevelWindowForOverflowXamlIsland")
        if surface != tray && (!overflow || surface != overflow)
            throw Error("The candidate tray icon is not physically visible")
        MouseMove(x, y, 0)
        Sleep(1600)
        RequireUnlockedTrayDesktop()
        CaptureTrayHover(root "\_tray-hover.png", x, y)
        for tooltip in WinGetList("ahk_class tooltips_class32") {
            if !DllCall("IsWindowVisible", "Ptr", tooltip)
                continue
            WinGetPos(&tx, &ty, &tw, &th, "ahk_id " tooltip)
            if Abs(tx - x) < 180 && Abs(ty - y) < 180
                throw Error("A visible tooltip appeared while hovering over the candidate icon")
        }
    } finally {
        A_IconHidden := true
        try {
            RequireUnlockedTrayDesktop()
            if opened
                chevron.InvokePattern.Invoke()
            MouseMove(originalX, originalY, 0)
        }
    }
}

CheckDailyAutomaticUpdates() {
    global ServiceStopRequested
    now := "20261020120000"
    for effect in ["schedule", "launch"] {
        for boundary in ["before", "after"] {
            probe := DailyUpdateProbe(effect, boundary), interrupted := false
            try StartDailyAppUpdateIfDue(now, probe)
            catch Error as failure {
                if failure.Message != "daily-update-test-interruption"
                    throw failure
                interrupted := true
            }
            if !interrupted
                throw Error("The daily update boundary did not interrupt")
            probe.Boundary := ""
            StartDailyAppUpdateIfDue(now, probe)
            StartDailyAppUpdateIfDue(now, probe)
            expected := effect = "schedule" && boundary = "before"
                || effect = "launch" && boundary = "after" ? 1 : 0
            if probe.Launches != expected || probe.Due != "20261021120000"
                throw Error("A daily attempt was repeated or its failure schedule was lost")
            StartDailyAppUpdateIfDue("20261025120000", probe)
            if probe.Launches != expected + 1 || probe.Due != "20261026120000"
                throw Error("A resumed service did not launch exactly one overdue check")
        }
    }
    probe := DailyUpdateProbe()
    StartDailyAppUpdateIfDue("20280228120000", probe)
    if probe.Due != "20280229120000"
        throw Error("The daily check did not preserve a leap-day schedule")
    probe := DailyUpdateProbe(), probe.Busy := true
    StartDailyAppUpdateIfDue(now, probe)
    if probe.Due != "" || probe.Launches
        throw Error("The service checked for updates before setup finished")
    probe.Busy := false
    StartDailyAppUpdateIfDue(, probe)
    if DateDiff(probe.Due, A_NowUTC, "Seconds") < 86395
        throw Error("The real service entry did not schedule its next day using current UTC")
    oldStopRequest := ServiceStopRequested
    ServiceStopRequested := true, stopped := false
    try {
        try DailyAppUpdateOperations().Launch()
        catch Error as failure
            stopped := InStr(failure.Message, "service is stopping")
        if !stopped
            throw Error("A stopped service launched a daily update worker")
    } finally ServiceStopRequested := oldStopRequest
    if !ServiceInstallNeedsDesktopProbe("", [])
        || ServiceInstallNeedsDesktopProbe("owned installation", [])
        || !ServiceInstallNeedsDesktopProbe("owned installation", [1])
        throw Error("An unattended upgrade lost its existing service or a fresh install skipped its probe")
}

CheckCompanionShutdown() {
    global CompanionProcesses
    for boundary in ["before", "after"] {
        probe := CompanionStopProbe(boundary)
        CompanionProcesses[77] := 123
        failureSeen := false
        try StopCompanions(probe.Wait.Bind(probe), probe.Terminate.Bind(probe),
            probe.Close.Bind(probe))
        catch Error as failure {
            failureSeen := true
            if boundary != "before" || !InStr(failure.Message, "session 77")
                throw failure
        }
        if boundary = "before" && !failureSeen
            throw Error("An interrupted shutdown did not report its failure")
        if boundary = "before" && (!probe.Running || !CompanionProcesses.Has(77))
            throw Error("An interrupted shutdown lost its live companion handle")
        probe.Boundary := ""
        StopCompanions(probe.Wait.Bind(probe), probe.Terminate.Bind(probe),
            probe.Close.Bind(probe))
        if probe.Running || !probe.Closed || CompanionProcesses.Has(77)
            throw Error("A fresh shutdown did not finish the owned companion")
    }
    probe := CompanionStopProbe()
    probe.Stuck := true
    CompanionProcesses[77] := 123
    failureSeen := false
    try StopCompanions(probe.Wait.Bind(probe), probe.Terminate.Bind(probe),
        probe.Close.Bind(probe))
    catch Error as failure {
        failureSeen := true
        if !InStr(failure.Message, "session 77") || failure.Extra != 1460
            throw failure
    }
    if !failureSeen || !CompanionProcesses.Has(77)
        throw Error("A timed-out shutdown did not retain and report its failure")
    probe.Stuck := false
    StopCompanions(probe.Wait.Bind(probe), probe.Terminate.Bind(probe),
        probe.Close.Bind(probe))
    if CompanionProcesses.Count || !probe.Closed
        throw Error("A repeated shutdown left a companion handle open")

    child := 0
    try {
        Run('"' A_WinDir '\System32\WindowsPowerShell\v1.0\powershell.exe"'
            . ' -NoProfile -NonInteractive -Command Start-Sleep -Seconds 30', , "Hide", &child)
        handle := DllCall("kernel32\OpenProcess", "UInt", 0x100001,
            "Int", false, "UInt", child, "Ptr")
        if !handle
            throw OSError()
        CompanionProcesses[77] := handle
        StopCompanions()
        if ProcessExist(child)
            throw Error("Shutdown returned before the owned process exited")
    } finally {
        if child && ProcessExist(child)
            ProcessClose(child)
        if CompanionProcesses.Has(77) {
            DllCall("kernel32\CloseHandle", "Ptr", CompanionProcesses[77])
            CompanionProcesses.Delete(77)
        }
    }
}
class RestartOperationProbe {
    __New(effect, boundary) {
        this.Effect := effect, this.Boundary := boundary
        this.Running := true, this.Tray := true, this.Locked := false
    }
    Acquire() => this.Locked := true
    Release(lock) => this.Locked := false
    Open() => this
    Close(target) => 0
    Before(effect) {
        if this.Effect = effect && this.Boundary = "before"
            throw Error("restart-test-interruption")
    }
    After(effect) {
        if this.Effect = effect && this.Boundary = "after"
            throw Error("restart-test-interruption")
    }
    Stop(target) {
        if !this.Running
            return
        this.Before("stop")
        this.Running := false
        this.After("stop")
    }
    StopProcesses() {
        if !this.Tray
            return
        this.Before("kill")
        this.Tray := false
        this.After("kill")
    }
    Start(target) {
        if this.Running
            return
        this.Before("start")
        this.Running := true, this.Tray := true
        this.After("start")
    }
}

CheckForceRestartTransitions() {
    for effect in ["stop", "kill", "start"] {
        for boundary in ["before", "after"] {
            probe := RestartOperationProbe(effect, boundary)
            interrupted := false
            try ForceRestartOwnedService(probe)
            catch Error as failure {
                if !InStr(failure.Message, "restart-test-interruption")
                    || !InStr(failure.Message, "Force restart failed while")
                    throw failure
                interrupted := true
            }
            if !interrupted || probe.Locked
                throw Error("Restart did not report an interruption and release its worker lock")
            probe.Boundary := ""
            ForceRestartOwnedService(probe)
            ForceRestartOwnedService(probe)
            if !probe.Running || !probe.Tray || probe.Locked
                throw Error("A fresh repeated restart did not leave one running service and tray")
        }
    }
    ; Upgrades use the same stop/kill path, but replacement starts only after
    ; setup copies the new files. Fresh calls must remain stopped after failure.
    for effect in ["stop", "kill"] {
        for boundary in ["before", "after"] {
            probe := RestartOperationProbe(effect, boundary)
            interrupted := false
            try PrepareOwnedAppUpgrade(probe)
            catch Error as failure {
                if !InStr(failure.Message, "Upgrade preparation failed while")
                    throw failure
                interrupted := true
            }
            if !interrupted || probe.Locked
                throw Error("Upgrade preparation lost its interruption or lock release")
            probe.Boundary := ""
            PrepareOwnedAppUpgrade(probe)
            PrepareOwnedAppUpgrade(probe)
            if probe.Running || probe.Tray || probe.Locked
                throw Error("Upgrade preparation restarted an old process before file replacement")
        }
    }
}

class LogInterruptionProbe {
    __New(effect, boundary) {
        this.Effect := effect, this.Boundary := boundary, this.Seen := false
    }
    Observe(effect, boundary) {
        if this.Effect = effect && this.Boundary = boundary {
            this.Seen := true
            throw Error("log-test-interruption")
        }
    }
}

class ProtectedLogDirectoryProbe extends AppEventLog {
    EnsureDirectory() {
        this.Protected := true
        super.EnsureDirectory()
    }
}

CheckOperationalLogs(root) {
    directory := root "\_operational-logs-" DllCall("GetCurrentProcessId")
    try {
        for effect in ["directory.create", "current.create", "record.append", "record.flush",
            "oldest.delete", "predecessor.move", "current.move", "partial.truncate", "oversized.delete"] {
            for boundary in ["before", "after"] {
                path := directory "\" StrReplace(effect, ".", "-") "-" boundary
                probe := LogInterruptionProbe(effect, boundary)
                if effect != "directory.create" {
                    DirCreate(path)
                    if InStr(effect, ".move") || effect = "oldest.delete" {
                        for suffix in ["", ".1", ".2"]
                            FileAppend(StrReplace(Format("{:0255}", 0), "0", "x") "`n",
                                path "\tray.log" suffix, "UTF-8-RAW")
                    } else if effect = "partial.truncate"
                        FileAppend("partial", path "\tray.log", "UTF-8-RAW")
                    else if effect = "oversized.delete"
                        FileAppend(StrReplace(Format("{:0300}", 0), "0", "x"), path "\tray.log.2", "UTF-8-RAW")
                }
                failed := false
                try {
                    logger := AppEventLog("tray", path, 256, probe.Observe.Bind(probe))
                    logger.Write("INFO", "test.started")
                } catch Error as failure {
                    if failure.Message != "log-test-interruption"
                        throw failure
                    failed := true
                }
                if !failed || !probe.Seen
                    throw Error("The log boundary was not interrupted: " effect " " boundary)
                ; No recovery checkpoints are supplied to a fresh writer.
                logger := AppEventLog("tray", path, 256)
                Loop 12
                    logger.Write("INFO", "test.repeated", "code=" A_Index)
                CheckLogFiles(path, 256)
            }
        }
        path := directory "\metadata"
        logger := AppEventLog("tray", path, 512)
        previous := AppEventLog.Current
        AppEventLog.Current := logger
        try WriteAppError("test.failure", Error("PRIVATE_EDITOR_TEXT", , "PRIVATE_CLIPBOARD_TEXT"))
        finally AppEventLog.Current := previous
        content := FileRead(path "\tray.log", "UTF-8")
        if InStr(content, "PRIVATE_") || !InStr(content, "test.failure") || !InStr(content, "type=Error")
            throw Error("Error logging stored content or omitted useful error metadata")
        ; Existing hardlinks must be refused before any write or truncation.
        sentinel := directory "\_sentinel"
        FileAppend("unchanged", sentinel, "UTF-8-RAW")
        FileDelete(path "\tray.log")
        if !DllCall("CreateHardLinkW", "Str", path "\tray.log", "Str", sentinel, "Ptr", 0)
            throw OSError()
        rejected := false
        try AppEventLog("tray", path, 512)
        catch Error
            rejected := true
        if !rejected || FileRead(sentinel, "UTF-8") != "unchanged"
            throw Error("The logger wrote through a substituted hardlink")
        FileDelete(path "\tray.log")
        ; A directory junction must be rejected while its target is untouched.
        target := directory "\_junction-target"
        DirCreate(target)
        shell := ComObject("WScript.Shell")
        if shell.Run('cmd.exe /d /c mklink /J "' directory '\_junction" "' target '"', 0, true) != 0
            throw Error("Could not create the log junction fixture")
        rejected := false
        try AppEventLog("tray", directory "\_junction", 512)
        catch Error
            rejected := true
        DirDelete(directory "\_junction")
        if !rejected || FileExist(target "\tray.log.lock")
            throw Error("The logger followed a substituted log directory")
        if A_IsAdmin {
            ; Exercise the production SYSTEM/admin ACL path inside this test's
            ; private root, without creating or changing shared application logs.
            protected := ProtectedLogDirectoryProbe("service", directory "\_protected", 512)
            protected.Write("INFO", "test.protected")
            protected := ProtectedLogDirectoryProbe("service", directory "\_protected", 512)
            protected.Write("INFO", "test.reopened")
            if !InStr(FileRead(protected.Path, "UTF-8"), "test.reopened")
                throw Error("The protected operational log could not be reopened")
        }
        concurrent := directory "\_concurrent"
        workers := []
        try {
            Loop 2 {
                workers.Push(StartAppProcessFixture(A_ScriptFullPath,
                    '"' concurrent '" --emit-test-events', false))
            }
            for worker in workers
                if WaitForCompanionExit(worker.handle, 10000) != 0
                    throw Error("A concurrent log writer timed out")
                else {
                    code := 0
                    if !DllCall("GetExitCodeProcess", "Ptr", worker.handle, "UInt*", &code) || code != 0
                        throw Error("A concurrent log writer failed with exit " code)
                }
            CheckLogFiles(concurrent, 2048)
            if !InStr(FileRead(concurrent "\tray.log", "UTF-8"), "test.concurrent")
                throw Error("Concurrent writers did not finish their records")
        } finally {
            for worker in workers
                try {
                    if WaitForCompanionExit(worker.handle, 0) != 0
                        StopOwnedProcess(worker.handle, "test log writer")
                } finally CloseCompanionHandle(worker.handle)
        }
    } finally {
        if DirExist(directory)
            DirDelete(directory, true)
    }
}

CheckLogFiles(path, maximumBytes) {
    count := 0
    Loop Files path "\*", "F" {
        count += 1
        if !RegExMatch(A_LoopFileName, "^tray\.log(?:\.[12])?$") || A_LoopFileSize > maximumBytes
            throw Error("Operational logs exceeded their fixed size/count or retained a lock")
        content := FileRead(A_LoopFileFullPath, "UTF-8")
        if content != "" && SubStr(content, -1) != "`n"
            throw Error("A fresh writer did not remove a partial log record")
    }
    if count > 3 || !FileExist(path "\tray.log")
        throw Error("Operational log retention lost the current file or exceeded three files")
}

StartAppProcessFixture(script, arguments := "--skip-update-check", suspended := true) {
    command := '"' A_AhkPath '" /script "' script '" ' arguments
    commandBuffer := Buffer((StrLen(command) + 1) * 2, 0)
    StrPut(command, commandBuffer, "UTF-16")
    startup := Buffer(104, 0), process := Buffer(24, 0)
    NumPut("UInt", startup.Size, startup)
    if !DllCall("CreateProcessW", "Str", A_AhkPath, "Ptr", commandBuffer,
        "Ptr", 0, "Ptr", 0, "Int", false, "UInt", suspended ? 4 : 0x08000000, "Ptr", 0,
        "Str", A_ScriptDir, "Ptr", startup, "Ptr", process)
        throw OSError()
    DllCall("CloseHandle", "Ptr", NumGet(process, 8, "Ptr"))
    return {Handle: NumGet(process, 0, "Ptr"), Pid: NumGet(process, 16, "UInt")}
}

CheckOwnedTrayProcessTermination() {
    ; Suspended workers cannot respond to a graceful close. They never execute
    ; app code, register hotkeys, or touch user text. A different script using
    ; the same runtime is the sentinel which recovery must leave alone.
    directory := GetServiceAppDirectory()
    owned := StartAppProcessFixture(directory "\CeratopsKeyboardLayout.ahk")
    sentinel := StartAppProcessFixture(A_ScriptFullPath)
    try {
        found := false, evidence := "No WMI record"
        for process in ReadRunningAppProcesses() {
            if process.Pid = owned.Pid {
                evidence := process.Path " | " process.Command " | " process.Created
                found := IsOwnedTrayProcess(process)
                if IsOwnedTrayProcess(process, process.Session + 1)
                    throw Error("Recovery accepted a different desktop session")
            }
            if process.Pid = sentinel.Pid && IsOwnedTrayProcess(process)
                throw Error("Recovery accepted an unrelated script using the same runtime")
        }
        if !found
            throw Error("Recovery did not identify its exact suspended tray worker: " evidence)
        StopMatchingTrayProcesses()
        StopMatchingTrayProcesses()
        if WaitForCompanionExit(owned.Handle, 0) != 0
            throw Error("Force recovery left the unresponsive owned tray process alive")
        if WaitForCompanionExit(sentinel.Handle, 0) != 0x102
            throw Error("Force recovery terminated an unrelated script")
    } finally {
        for fixture in [owned, sentinel] {
            if WaitForCompanionExit(fixture.Handle, 0) = 0x102
                TerminateCompanion(fixture.Handle)
            WaitForCompanionExit(fixture.Handle, 5000)
            CloseCompanionHandle(fixture.Handle)
        }
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

class InterruptedSettingsWindow {
    __New(window, owner) {
        this.Window := window, this.Owner := owner
    }
    Hwnd => this.Window.Hwnd
    __Call(name, parameters) => this.Window.%name%(parameters*)
    Show(options := "") {
        if this.Owner.FaultBoundary = "before"
            throw Error("interface-test-interruption")
        this.Window.Show(options)
        if this.Owner.FaultBoundary = "after"
            throw Error("interface-test-interruption")
    }
}
class InterruptedShortcutInterface extends KeyboardShortcutManager {
    FaultBoundary := ""
    CreateSettingsDialog() => InterruptedSettingsWindow(super.CreateSettingsDialog(), this)
}

class ObservedTrayMenu extends KeyboardShortcutManager {
    static CurrentObserver := 0
    FaultBoundary := ""
    OpenCount := 0
    ObservePath := ""

    ShowNativeTrayMenu() {
        if this.FaultBoundary = "before"
            throw Error("interface-test-interruption")
        if FileExist(this.ObservePath)
            FileDelete(this.ObservePath)
        command := '"' A_AhkPath '" /ErrorStdOut=UTF-8 "' A_ScriptFullPath
            . '" --observe-menu ' DllCall("GetCurrentProcessId", "UInt") " " A_ScriptHwnd
            . " " A_TrayMenu.Handle " " this.Converter.Layouts.Count ' "' this.ObservePath '"'
        Run(command, , "Hide", &observer)
        ObservedTrayMenu.CurrentObserver := observer
        try {
            super.ShowNativeTrayMenu()
            if ProcessWaitClose(observer, 8)
                throw Error("The menu observer did not finish")
            result := FileRead(this.ObservePath, "UTF-8")
            if SubStr(result, 1, 5) != "PASS|"
                throw Error(result)
            this.OpenCount += 1
        } finally {
            if ProcessExist(observer)
                ProcessClose(observer)
            ObservedTrayMenu.CurrentObserver := 0
            if FileExist(this.ObservePath)
                FileDelete(this.ObservePath)
        }
        if this.FaultBoundary = "after"
            throw Error("interface-test-interruption")
    }
}

ObserveNativeTrayMenu(parentPid, parentWindow, menuHandle, languageCount, output) {
    try {
        hwnd := WinWait("ahk_class #32768 ahk_pid " parentPid, , 5)
        if !hwnd
            throw Error("The tray click did not display a native popup")
        WinGetPos(&x, &y, &width, &height, "ahk_id " hwnd)
        dpi := DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt")
        if width > Round(330 * dpi / 96)
            throw Error("The default tray menu is still unnecessarily wide: " width)
        ; Use the existing UIA client, including its COM lifetime handling,
        ; against the real cross-process Windows popup, not our item buffers.
        children := UIA.ElementFromHandle(hwnd, , 0).GetChildren()
        expected := KeyboardShortcutManager(Converter).InstalledRows()
        if expected.Length != languageCount || children.Length < languageCount
            throw Error("The popup exposed the wrong number of installed languages")
        Loop languageCount {
            if children[A_Index].Name != expected[A_Index].Language
                throw Error("Windows accessibility lost a language row's name")
        }
        FileOpen(output, "w", "UTF-8").Write("PASS|" width "|" height)
    } catch Error as failure {
        FileOpen(output, "w", "UTF-8").Write("FAIL: " failure.Message " (observer line " failure.Line "; " failure.Extra ")")
    } finally {
        DllCall("PostMessageW", "Ptr", parentWindow, "UInt", 0x1F, "Ptr", 0, "Ptr", 0)
    }
}

PostTestTrayNotification(event) {
    ; Version 4 packs the icon ID above the notification code.
    if !DllCall("PostMessageW", "Ptr", A_ScriptHwnd, "UInt", 0x404,
        "UPtr", 0, "Ptr", (0x404 << 16) | event)
        throw OSError()
}

CheckTrayDoubleClickSequence(menu) {
    ; Use Windows' down/up/double-click/up sequence through the script's native
    ; shell callback. Posting the double-click alone misses a premature popup.
    interval := DllCall("GetDoubleClickTime", "UInt")
    Loop 2 {
        before := menu.OpenCount
        hwnd := menu.Dialog.Hwnd
        menu.Dialog.Hide()
        for event in [0x201, 0x202]
            PostTestTrayNotification(event)
        Sleep(Max(1, Min(50, interval // 4)))
        if menu.MenuOpen || menu.OpenCount != before
            throw Error("The first left click opened a popup before double-click detection finished")
        for event in [0x203, 0x202]
            PostTestTrayNotification(event)
        deadline := A_TickCount + 1000
        while !DllCall("IsWindowVisible", "Ptr", hwnd) && A_TickCount < deadline
            Sleep(10)
        if !DllCall("IsWindowVisible", "Ptr", hwnd) || menu.Dialog.Hwnd != hwnd
            throw Error("The complete double-click sequence did not show the current settings window")
        Sleep(interval + 50)
        if menu.MenuOpen || menu.OpenCount != before
            throw Error("The final release of a double-click opened a stray popup")
    }
}

CheckTrayClicksAndInterruptions(shortcuts, directory) {
    if !DirExist(directory)
        DirCreate(directory)
    menu := ObservedTrayMenu(shortcuts.Converter, shortcuts.Settings)
    menu.ObservePath := directory "\menu-observation.txt"
    menu.RebuildTray()
    ; Keep an owned foreground window while observing the popup. No keys or
    ; mouse clicks are injected into the user's applications.
    menu.ShowSettings()
    try {
        for event in [0x406, 0x407]
            PostTestTrayNotification(event)
        Sleep(50)
        if menu.OpenCount || menu.MenuOpen
            throw Error("A hover notification opened a tray popup")
        CheckTrayDoubleClickSequence(menu)
        for event in [0x202, 0x205] {
            before := menu.OpenCount
            if event = 0x202
                PostTestTrayNotification(0x201)
            PostTestTrayNotification(event)
            deadline := A_TickCount + 8000
            while menu.OpenCount = before && A_TickCount < deadline
                Sleep(10)
            if menu.OpenCount != before + 1 || menu.MenuOpen
                throw Error("A left/right tray click did not open and close exactly one menu")
        }
        for boundary in ["before", "after"] {
            menu.FaultBoundary := boundary
            ExpectInterfaceInterruption(menu.ShowTrayMenu.Bind(menu))
            if menu.MenuOpen
                throw Error("An interrupted popup stranded the menu-open flag")
            menu.FaultBoundary := ""
            before := menu.OpenCount
            menu.ShowTrayMenu()
            menu.ShowTrayMenu()
            if menu.OpenCount != before + 2
                throw Error("Fresh repeated menu requests did not display their current menu")
        }
    } finally {
        menu.CloseDialog()
        shortcuts.RebuildTray()
    }
}

CheckRenderedTrayColumns(shortcuts) {
    layout := shortcuts.MenuLayout
    dc := DllCall("Gdi32\CreateCompatibleDC", "Ptr", 0, "Ptr")
    screen := DllCall("GetDC", "Ptr", 0, "Ptr")
    bitmap := DllCall("Gdi32\CreateCompatibleBitmap", "Ptr", screen,
        "Int", layout.Width, "Int", layout.Height, "Ptr")
    prior := DllCall("Gdi32\SelectObject", "Ptr", dc, "Ptr", bitmap, "Ptr")
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", screen)
    firstInk := -1
    try {
        for itemId, row in shortcuts.MenuRows {
            measure := Buffer(A_PtrSize = 8 ? 32 : 24, 0)
            NumPut("UInt", 1, measure)
            NumPut("UInt", itemId, measure, 8)
            if !DllCall("SendMessageW", "Ptr", A_ScriptHwnd, "UInt", 0x2C, "Ptr", 0, "Ptr", measure)
                throw Error("The real native measurement message was not handled")
            if NumGet(measure, 12, "UInt") > layout.Width || NumGet(measure, 16, "UInt") <= 0
                throw Error("The language row has an invalid native size")
            draw := Buffer(A_PtrSize = 8 ? 64 : 48, 0)
            NumPut("UInt", 1, draw)
            NumPut("UInt", itemId, "UInt", 1, draw, 8)
            offset := A_PtrSize = 8 ? 24 : 20
            NumPut("Ptr", A_TrayMenu.Handle, "Ptr", dc, draw, offset)
            NumPut("Int", 0, "Int", 0, "Int", layout.Width, "Int", layout.Height,
                draw, offset + A_PtrSize * 2)
            if !DllCall("SendMessageW", "Ptr", A_ScriptHwnd, "UInt", 0x2B, "Ptr", 0, "Ptr", draw)
                throw Error("The real native draw message was not handled")
            ; Read actual ink from the rendered bitmap. Different final keys
            ; must not move the first C of these default Ctrl combinations.
            ink := -1
            Loop layout.Width - layout.ShortcutX {
                x := layout.ShortcutX + A_Index - 1
                Loop layout.Height {
                    color := DllCall("Gdi32\GetPixel", "Ptr", dc, "Int", x, "Int", A_Index - 1, "UInt")
                    if (color & 255) < 100 && ((color >> 8) & 255) < 100 && ((color >> 16) & 255) < 100 {
                        ink := x
                        break
                    }
                }
                if ink >= 0
                    break
            }
            if ink < 0 || (firstInk >= 0 && ink != firstInk)
                throw Error("Rendered shortcut text does not share its first-symbol position")
            firstInk := ink
        }
    } finally {
        DllCall("Gdi32\SelectObject", "Ptr", dc, "Ptr", prior)
        DllCall("Gdi32\DeleteObject", "Ptr", bitmap)
        DllCall("Gdi32\DeleteDC", "Ptr", dc)
    }
}

StopUiCheck(failure, *) {
    global uiManager, uiDirectory, originalWindow
    try FileAppend("FAIL: " failure.Message " (line " failure.Line ")`n", "*")
    if ObservedTrayMenu.CurrentObserver && ProcessExist(ObservedTrayMenu.CurrentObserver)
        try ProcessClose(ObservedTrayMenu.CurrentObserver)
    if IsSet(uiManager)
        try uiManager.CloseDialog()
    if IsSet(uiDirectory) && DirExist(uiDirectory)
        try DirDelete(uiDirectory, true)
    try WinActivate("ahk_id " originalWindow)
    ExitApp(1)
}

StopMenuObserver(failure, *) {
    try FileOpen(A_Args[6], "w", "UTF-8").Write("FAIL: " failure.Message " (observer line " failure.Line "; " failure.Extra ")")
    DllCall("PostMessageW", "Ptr", A_Args[3], "UInt", 0x1F, "Ptr", 0, "Ptr", 0)
    ExitApp(1)
}
InterruptInterfaceEffect(operation, effect, selectedEffect, boundary, parameters*) {
    if effect = selectedEffect && boundary = "before"
        throw Error("interface-test-interruption")
    result := operation(parameters*)
    if effect = selectedEffect && boundary = "after"
        throw Error("interface-test-interruption")
    return result
}
ExpectInterfaceInterruption(operation) {
    try operation()
    catch Error as failure {
        if failure.Message = "interface-test-interruption"
            return
        throw failure
    }
    throw Error("The interface interruption boundary was not exercised")
}
InterruptTrayVisibility(selectedEffect, boundary, hidden) {
    return InterruptInterfaceEffect(SetAppTrayIconHidden, hidden ? "hide" : "show",
        selectedEffect, boundary, hidden)
}
CheckTrayRestorationInterruptions() {
    ; A missing initial icon leaves AutoHotkey's internal tray handle empty.
    ; Repeated fresh calls must add it back after each native effect is interrupted.
    for boundary in ["before", "after"] {
        for selectedEffect in ["hide", "show", "tooltip"] {
            SetAppTrayIconHidden(true)
            if AppTrayIconIsRegistered()
                throw Error("The tray fixture still has an icon")
            setHidden := InterruptTrayVisibility.Bind(selectedEffect, boundary)
            suppressHover := InterruptInterfaceEffect.Bind(SuppressAppTrayHover,
                "tooltip", selectedEffect, boundary)
            ExpectInterfaceInterruption(RestoreAppTrayIcon.Bind(setHidden, suppressHover))
            if !RestoreAppTrayIcon() || !AppTrayIconIsRegistered()
                throw Error("A fresh tray request did not restore the missing icon")
        }
    }
    SetAppTrayIconHidden(true)
    if RestoreAppTrayIcon(SetAppTrayIconHidden, SuppressAppTrayHover, (*) => false)
        throw Error("A rejected tray registration was reported as complete")
    CheckAndRestoreAppTrayIcon()
    if !AppTrayIconIsRegistered()
        throw Error("The tray retry did not restore the icon")
}
CheckInterfaceInterruptions(shortcuts) {
    ; The only visible settings effect is Show: controls are built in a hidden
    ; window first. Faults surround real Show calls, and fresh calls use the
    ; ordinary entrypoint, the current window and current settings, no recovery
    ; checkpoint. Menu preparation and each native tray effect are repeated too.
    static boundaries := ["before", "after"]
    iconFile := A_ScriptDir "\..\CeratopsKeyboardLayout.ico"
    for boundary in boundaries {
        for selectedEffect in ["icon", "tooltip"] {
            setIcon := InterruptInterfaceEffect.Bind(TraySetIcon, "icon", selectedEffect, boundary)
            suppressHover := InterruptInterfaceEffect.Bind(SuppressAppTrayHover, "tooltip", selectedEffect, boundary)
            ExpectInterfaceInterruption(InitializeAppTray.Bind(iconFile, setIcon, suppressHover))
            InitializeAppTray(iconFile)
            if !SuppressAppTrayHover()
                throw Error("A fresh tray setup did not suppress hover popups")
        }
        ExpectInterfaceInterruption(InterruptInterfaceEffect.Bind(shortcuts.RebuildTray.Bind(shortcuts),
            "menu", "menu", boundary))
        shortcuts.RebuildTray()
        if A_TrayMenu.Default != "Change key combinations..."
            throw Error("A fresh menu build did not restore the double-click action")
        fixture := InterruptedShortcutInterface(shortcuts.Converter, shortcuts.Settings)
        try {
            fixture.FaultBoundary := boundary
            ExpectInterfaceInterruption(fixture.ShowSettings.Bind(fixture))
            hwnd := fixture.Dialog.Hwnd
            fixture.FaultBoundary := ""
            fixture.ShowSettings()
            if fixture.Dialog.Hwnd != hwnd || !DllCall("IsWindowVisible", "Ptr", hwnd)
                throw Error("A fresh settings request did not reuse and show its current window")
            fixture.ShowSettings()
            if fixture.Dialog.Hwnd != hwnd
                throw Error("Repeated settings requests created duplicate windows")
            for name, control in fixture.Controls {
                ; Repeat naming and removal around their real Windows effects.
                ; A fresh call restores the screen-reader name without putting
                ; caption text back into the narrow drawing rectangle.
                for caption in ["WinKey", ""] {
                    operation := fixture.SetCheckboxAccessibleName.Bind(fixture, control.Win, caption)
                    ExpectInterfaceInterruption(InterruptInterfaceEffect.Bind(
                        operation, "name", "name", boundary))
                    fixture.SetCheckboxAccessibleName(control.Win, "WinKey")
                    CheckWindowsModifierCaption(control.Win)
                }
                before := control.Win.Value
                ExpectInterfaceInterruption(InterruptInterfaceEffect.Bind(
                    fixture.ToggleWindowsModifier.Bind(fixture, control.Win), "toggle", "toggle", boundary))
                if control.Win.Value != (boundary = "after" ? !before : before)
                    throw Error("The interrupted Windows modifier changed the wrong state")
                current := control.Win.Value
                fixture.ToggleWindowsModifier(control.Win)
                if control.Win.Value != !current
                    throw Error("A fresh Windows modifier click did not toggle its current state")
            }
        } finally fixture.CloseDialog()
    }
    CheckTrayRestorationInterruptions()
}

CheckWindowsModifierCaption(control) {
    ; Inspect the native control, not source text or an app-owned label. Even
    ; when the checkbox is wider on another display, it must have no caption
    ; to leak beside its check mark, and must retain its accessible name.
    if DllCall("GetWindowTextLengthW", "Ptr", control.Hwnd)
        throw Error("The Windows-key checkbox can draw stray caption fragments")
    if UIA.ElementFromHandle(control.Hwnd).Name != "WinKey"
        throw Error("The captionless Windows-key checkbox lost its accessible name")
}

CheckSmallIconVisibility() {
    ; Alpha touching each edge missed the small-looking face. Check what Windows
    ; actually draws on a dark tray at 100%, 150% and 200% display scale instead.
    ; Both runtime routes must retain enough bright artwork and green face area.
    for file in [A_ScriptDir "\..\CeratopsKeyboardLayout.ico", A_ScriptDir "\..\CeratopsKeyboardLayout.exe"] {
        for size in [16, 24, 32] {
            icon := 0, dc := 0, bitmap := 0, previous := 0
            try {
                if SubStr(file, -3) = "ico"
                    icon := DllCall("LoadImageW", "Ptr", 0, "Str", file, "UInt", 1,
                        "Int", size, "Int", size, "UInt", 0x10, "Ptr")
                else {
                    iconId := 0
                    if DllCall("PrivateExtractIconsW", "Str", file, "Int", 0,
                        "Int", size, "Int", size, "Ptr*", &icon, "UInt*", &iconId,
                        "UInt", 1, "UInt", 0, "UInt") != 1
                        throw Error("Windows could not extract the program icon")
                }
                if !icon
                    throw OSError()
                dc := DllCall("Gdi32\CreateCompatibleDC", "Ptr", 0, "Ptr")
                header := Buffer(40, 0), pixels := 0
                NumPut("UInt", 40, "Int", size, "Int", -size,
                    "UShort", 1, "UShort", 32, header)
                bitmap := DllCall("Gdi32\CreateDIBSection", "Ptr", dc, "Ptr", header,
                    "UInt", 0, "Ptr*", &pixels, "Ptr", 0, "UInt", 0, "Ptr")
                if !dc || !bitmap
                    throw OSError()
                previous := DllCall("Gdi32\SelectObject", "Ptr", dc, "Ptr", bitmap, "Ptr")
                Loop size * size
                    NumPut("UInt", 0x002B2B2B, pixels, (A_Index - 1) * 4)
                if !DllCall("DrawIconEx", "Ptr", dc, "Int", 0, "Int", 0, "Ptr", icon,
                    "Int", size, "Int", size, "UInt", 0, "Ptr", 0, "UInt", 3)
                    throw OSError()
                DllCall("Gdi32\GdiFlush")
                bright := 0, green := 0
                Loop size * size {
                    colour := NumGet(pixels, (A_Index - 1) * 4, "UInt")
                    red := (colour >> 16) & 255, g := (colour >> 8) & 255, blue := colour & 255
                    bright += Max(red, g, blue) >= 93
                    green += g >= 90 && g - red >= 10 && g - blue >= 10
                }
                if bright < Ceil(size * size * 0.45) || green < Ceil(size * size * 0.35)
                    throw Error("Trixie's face is too small against the dark tray at " size " pixels: "
                        bright " bright and " green " green pixels in " file)
            } finally {
                if previous
                    DllCall("Gdi32\SelectObject", "Ptr", dc, "Ptr", previous)
                if bitmap
                    DllCall("Gdi32\DeleteObject", "Ptr", bitmap)
                if dc
                    DllCall("Gdi32\DeleteDC", "Ptr", dc)
                if icon
                    DllCall("DestroyIcon", "Ptr", icon)
            }
        }
    }
}

CheckKeyCombinationInterface(shortcuts) {
    CheckSmallIconVisibility()
    InitializeAppTray(A_ScriptDir "\..\CeratopsKeyboardLayout.ico")
    version := GetAppVersionText()
    if version = "" || !SuppressAppTrayHover()
        throw Error("The tray has no version or rejected hover suppression")
    shortcuts.RebuildTray()
    if A_TrayMenu.Default != "Change key combinations..." || A_TrayMenu.ClickCount != 2
        throw Error("The tray default does not open key combinations on a double-click")
    count := DllCall("GetMenuItemCount", "Ptr", A_TrayMenu.Handle, "Int")
    versionText := Buffer(128, 0)
    if !DllCall("GetMenuStringW", "Ptr", A_TrayMenu.Handle, "UInt", count - 2,
        "Ptr", versionText, "Int", 64, "UInt", 0x400, "Int")
        || StrGet(versionText, "UTF-16") != "Version " version
        throw Error("The tray menu does not show the current app version")
    for index, row in shortcuts.InstalledRows() {
        item := Buffer(A_PtrSize = 8 ? 80 : 48, 0)
        NumPut("UInt", item.Size, "UInt", 0x120, item)
        if !DllCall("GetMenuItemInfoW", "Ptr", A_TrayMenu.Handle, "UInt", index - 1,
            "Int", true, "Ptr", item)
            throw OSError()
        accessible := NumGet(item, A_PtrSize = 8 ? 48 : 32, "Ptr")
        if NumGet(item, 8, "UInt") != 0x100 || NumGet(accessible, 0, "UInt") != 0xAA0DF00D
            throw Error("The language row lost its native text and accessibility data")
        label := StrGet(NumGet(accessible, 8, "Ptr"), "UTF-16")
        if label != row.Language "`t" StrReplace(row.Shortcut.Label, "+", " + ")
            throw Error("Tray languages and combinations are not in separate native columns")
    }
    CheckRenderedTrayColumns(shortcuts)
    originalAssignments := shortcuts.Assignments
    try {
        shortcuts.Assignments := originalAssignments.Clone()
        custom := ["^!F1", "^!F12", "^+!PgUp"]
        for index, row in shortcuts.InstalledRows()
            shortcuts.Assignments[row.Name] := custom[index]
        shortcuts.RebuildTray()
        CheckRenderedTrayColumns(shortcuts)
    } finally {
        shortcuts.Assignments := originalAssignments
        shortcuts.RebuildTray()
    }
    ; Deliver the shell's double-click message to our own script window. This
    ; exercises AHK's default-item dispatch without moving the user's mouse.
    PostTestTrayNotification(0x203)
    deadline := A_TickCount + 1000
    while !shortcuts.Dialog && A_TickCount < deadline
        Sleep(10)
    if !shortcuts.Dialog
        throw Error("A tray double-click did not open the key combinations window")
    hwnd := shortcuts.Dialog.Hwnd
    if WinGetTitle("ahk_id " hwnd) != "Ceratops Keyboard Layout - Key Combinations"
        throw Error("The settings window has the wrong title")
    if shortcuts.Controls.Count != shortcuts.Converter.Layouts.Count
        throw Error("The key combinations window shows an uninstalled keyboard")
    previousX := -1
    for name, control in shortcuts.Controls {
        control.Win.GetPos(&checkX, &checkY, &checkWidth)
        control.WindowsIcon.GetPos(&iconX, &iconY, &iconWidth)
        control.WindowsLabel.GetPos(&labelX, &labelY, &labelWidth)
        control.Hotkey.GetPos(&keyX, &keyY)
        if checkX + checkWidth > iconX || iconX + iconWidth > labelX || labelX + labelWidth > keyX
            throw Error("The row is not checkbox, Windows symbol, WinKey +, then combination")
        if checkY != iconY || iconY != labelY || labelY != keyY || (previousX >= 0 && keyX != previousX)
            throw Error("Key combination controls are not aligned across rows")
        if control.WindowsIcon.Text != Chr(0xF0FF) || control.WindowsLabel.Text != "WinKey +"
            throw Error("The Windows modifier label is missing")
        CheckWindowsModifierCaption(control.Win)
        ; Inspect the selected native font and actual glyph coverage, so a
        ; missing-font box cannot satisfy the Windows-logo check.
        dc := DllCall("GetDC", "Ptr", control.WindowsIcon.Hwnd, "Ptr")
        font := SendMessage(0x31, 0, 0, control.WindowsIcon.Hwnd)
        prior := DllCall("Gdi32\SelectObject", "Ptr", dc, "Ptr", font, "Ptr")
        try {
            face := Buffer(128, 0), glyph := Buffer(2, 0)
            DllCall("Gdi32\GetTextFaceW", "Ptr", dc, "Int", 64, "Ptr", face)
            DllCall("Gdi32\GetGlyphIndicesW", "Ptr", dc, "Str", Chr(0xF0FF),
                "Int", 1, "Ptr", glyph, "UInt", 1)
            if StrGet(face) != "Wingdings" || NumGet(glyph, 0, "UShort") = 0xFFFF
                throw Error("Windows did not supply the Windows-key logo glyph")
        } finally {
            DllCall("Gdi32\SelectObject", "Ptr", dc, "Ptr", prior)
            DllCall("ReleaseDC", "Ptr", control.WindowsIcon.Hwnd, "Ptr", dc)
        }
        previousX := keyX
        before := control.Win.Value
        for clickable in [control.WindowsIcon, control.WindowsLabel] {
            ControlClick(clickable.Hwnd, , , , , "NA")
            Sleep(10)
            if control.Win.Value != !before
                throw Error("Clicking the Windows-key logo or label did not toggle its own checkbox")
            control.Win.Value := before
        }
    }
    PostTestTrayNotification(0x203)
    Sleep(30)
    if shortcuts.Dialog.Hwnd != hwnd
        throw Error("A second tray double-click created a duplicate window")
    shortcuts.CloseDialog()
}

; Inject a queued shortcut exactly before/after the dispatcher observes an
; empty queue. Real one-shot timers must drain it without another key press.
; Window zero makes conversion leave the user's editor and clipboard alone.
class InterruptedDispatchQueue {
    __New(boundary, callback) {
        this.Items := [], this.Removed := [], this.Boundary := boundary
        this.Interrupt := callback
    }
    Length {
        get {
            count := this.Items.Length
            if !count && this.Interrupt {
                callback := this.Interrupt
                this.Interrupt := 0
                callback()
                if this.Boundary = "before"
                    count := this.Items.Length
            }
            return count
        }
    }
    Push(request) => this.Items.Push(request)
    RemoveAt(index) {
        request := this.Items.RemoveAt(index)
        this.Removed.Push(request.Sequence)
        return request
    }
}
CheckDispatchInterruptions() {
    global Converter
    target := ""
    for name in Converter.Layouts {
        target := name
        break
    }
    if target = ""
        throw Error("The dispatch check needs one supported installed keyboard.")
    for boundary in ["before", "after"] {
        Loop 5 {
            manager := KeyboardShortcutManager(Converter)
            request := {Target: target, Window: 0, Behavior: "selected", Sequence: 2}
            queue := InterruptedDispatchQueue(boundary, manager.QueueRequest.Bind(manager, request))
            manager.Requests := queue
            manager.QueueRequest({Target: target, Window: 0, Behavior: "selected", Sequence: 1})
            WaitForDispatch(manager, queue, 2)
            manager.QueueRequest({Target: target, Window: 0, Behavior: "selected", Sequence: 3})
            WaitForDispatch(manager, queue, 3)
            for index, sequence in queue.Removed
                if index != sequence
                    throw Error("Interrupted dispatch changed request order or repeated a request.")
            SetTimer(manager.Dispatch, 0)
        }
    }
}
WaitForDispatch(manager, queue, count) {
    deadline := A_TickCount + 1000
    while (queue.Removed.Length < count || manager.Processing) && A_TickCount < deadline
        Sleep(5)
    if queue.Removed.Length != count || queue.Items.Length || manager.Processing
        throw Error("A shortcut queued " queue.Boundary " the empty check was stranded.")
}
if A_Args.Length && A_Args[1] = "--observe-menu" {
    OnError(StopMenuObserver)
    ObserveNativeTrayMenu(A_Args[2], A_Args[3], A_Args[4], A_Args[5], A_Args[6])
    ExitApp()
}
if A_Args.Length && A_Args[A_Args.Length] = "--dispatch-only" {
    try {
        CheckDispatchInterruptions()
        CheckCompanionShutdown()
        CheckForceRestartTransitions()
        CheckOwnedTrayProcessTermination()
        CheckDailyAutomaticUpdates()
        try FileAppend("PASS dispatcher, shutdown, interrupted/fresh force restart and exact-path unresponsive-process termination`n", "*")
        dispatchCode := 0
    } catch Error as failure {
        try FileAppend("FAIL: " failure.Message " (line " failure.Line ")`n", "*")
        dispatchCode := 1
    }
    ExitApp(dispatchCode)
}

if A_Args.Length = 2 && A_Args[2] = "--diagnostics-only" {
    try {
        CheckOperationalLogs(A_Args[1])
        FileAppend("PASS bounded logs, private error metadata, unsafe paths and interrupted/fresh writes`n", "*")
        ExitApp(0)
    } catch Error as failure {
        FileAppend("FAIL: " failure.Message " (" failure.File ":" failure.Line ")`n" failure.Stack "`n", "*")
        ExitApp(1)
    }
}

if A_Args.Length = 2 && A_Args[2] = "--physical-hover" {
    try {
        CheckPhysicalTrayHover(A_Args[1])
        FileAppend("PASS physical pointer hover with no nearby tooltip; inspect _tray-hover.png`n", "*")
        ExitApp(0)
    } catch Error as failure {
        FileAppend("FAIL physical hover: " failure.Message " (line " failure.Line ")`n", "*")
        ExitApp(failure.Extra = "LOCKED" ? 2 : 1)
    }
}

if A_Args.Length = 2 && A_Args[2] = "--emit-test-events" {
    try {
        logger := AppEventLog("tray", A_Args[1], 2048)
        Loop 30
            logger.Write("INFO", "test.concurrent", "code=" A_Index)
        ExitApp(0)
    } catch Error as failure {
        FileAppend("FAIL concurrent log writer: " failure.Message "`n", "*")
        ExitApp(1)
    }
}

; UI-only checks do not register global keys, send keyboard input, change the
; shared settings, or stop an installed service. The full desktop suite also
; uses these same checks before testing real key capture and conversion.
if A_Args.Length >= 2 && A_Args[2] = "--ui-only" {
    OnError(StopUiCheck)
    uiDirectory := A_Args[1] "\shortcut-interface-" DllCall("GetCurrentProcessId")
    try {
        uiManager := KeyboardShortcutManager(Converter, KeyboardShortcutSettings(uiDirectory "\Shortcuts.ini"))
        CheckKeyCombinationInterface(uiManager)
        CheckInterfaceInterruptions(uiManager)
        CheckTrayClicksAndInterruptions(uiManager, uiDirectory)
        try FileAppend("PASS compact native menu, first-symbol column alignment, both tray buttons, settings, accessibility and interrupted/fresh UI requests`n", "*")
        uiCode := 0
    } catch Error as failure {
        try FileAppend("FAIL: " failure.Message " (line " failure.Line "; " failure.Extra ")`n", "*")
        uiCode := 1
    } finally {
        if IsSet(uiManager)
            uiManager.CloseDialog()
        if DirExist(uiDirectory)
            DirDelete(uiDirectory, true)
        try WinActivate("ahk_id " originalWindow)
    }
    ExitApp(uiCode)
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
    CheckDispatchInterruptions()
    shortcuts := KeyboardShortcutManager(Converter, settings)
    shortcuts.Start()
    CheckKeyCombinationInterface(shortcuts)
    CheckInterfaceInterruptions(shortcuts)
    if DllCall("GetMenuItemCount", "Ptr", A_TrayMenu.Handle) != Converter.Layouts.Count + 9
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
