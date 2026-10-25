#Requires AutoHotkey v2.0.19+
#Include ..\CeratopsKeyboardLayout.ahk
#Include ..\CeratopsKeyboardLayout-Service.ahk
#Include Test-TrayInterface.ahk
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

class HourlyUpdateProbe {
    __New(effect := "", boundary := "") {
        this.Effect := effect, this.Boundary := boundary, this.Due := "", this.Launches := 0
        this.Saves := 0, this.Busy := false
    }
    ReadNextCheck() => this.Due
    InstallationIsBusy() => this.Busy
    At(effect, boundary) {
        if this.Effect = effect && this.Boundary = boundary
            throw Error("hourly-update-test-interruption")
    }
    SaveNextCheck(value) {
        this.At("schedule", "before")
        this.Due := value
        this.Saves += 1
        this.At("schedule", "after")
    }
    Launch() {
        this.At("launch", "before")
        this.Launches += 1
        this.At("launch", "after")
    }
}

CheckHourlyAutomaticUpdates() {
    global ServiceStopRequested
    now := "20261020120000"
    for effect in ["schedule", "launch"] {
        for boundary in ["before", "after"] {
            probe := HourlyUpdateProbe(effect, boundary), interrupted := false
            try StartHourlyAppUpdateIfDue(now, probe)
            catch Error as failure {
                if failure.Message != "hourly-update-test-interruption"
                    throw failure
                interrupted := true
            }
            if !interrupted
                throw Error("The hourly update boundary did not interrupt")
            probe.Boundary := ""
            StartHourlyAppUpdateIfDue(now, probe)
            StartHourlyAppUpdateIfDue(now, probe)
            expected := effect = "schedule" && boundary = "before"
                || effect = "launch" && boundary = "after" ? 1 : 0
            if probe.Launches != expected || probe.Due != "20261020130000" || probe.Saves != 1
                throw Error("An hourly attempt was repeated or its failure schedule was lost")
            StartHourlyAppUpdateIfDue("20261025120000", probe)
            if probe.Launches != expected + 1 || probe.Due != "20261025130000"
                throw Error("A resumed service did not launch exactly one overdue check")
        }
    }
    ; Fresh workers read the saved deadline; neither restart nor early polling
    ; claims another attempt. Reaching the exact deadline claims one new hour.
    probe := HourlyUpdateProbe(), probe.Due := "20261020130000"
    if StartHourlyAppUpdateIfDue("20261020125959", probe) || probe.Launches || probe.Saves
        throw Error("The saved hourly deadline was ignored after a restart")
    if !StartHourlyAppUpdateIfDue("20261020130000", probe)
        || probe.Due != "20261020140000" || probe.Launches != 1
        throw Error("The next hourly check did not start at its deadline")
    StartHourlyAppUpdateIfDue("20261020130000", probe)
    if probe.Launches != 1 || probe.Saves != 1
        throw Error("The same hourly deadline launched twice")
    for timestamp, expected in Map("20280228233000", "20280229003000",
        "20261231233000", "20270101003000") {
        probe := HourlyUpdateProbe()
        StartHourlyAppUpdateIfDue(timestamp, probe)
        if probe.Due != expected
            throw Error("The hourly UTC schedule lost its calendar rollover")
    }
    ; Every current schedule must fit within one hour. Shrinking a later saved
    ; deadline is itself repeatable across interruption, without starting a check.
    for boundary in ["before", "after"] {
        probe := HourlyUpdateProbe("schedule", boundary), probe.Due := "20261021120000"
        interrupted := false
        try StartHourlyAppUpdateIfDue(now, probe)
        catch Error as failure {
            if failure.Message != "hourly-update-test-interruption"
                throw failure
            interrupted := true
        }
        if !interrupted
            throw Error("The later-deadline boundary did not interrupt")
        probe.Boundary := ""
        StartHourlyAppUpdateIfDue(now, probe)
        StartHourlyAppUpdateIfDue(now, probe)
        if probe.Due != "20261020130000" || probe.Launches || probe.Saves != 1
            throw Error("A later deadline was not shortened exactly once")
    }
    probe := HourlyUpdateProbe(), probe.Due := "20261020123000"
    StartHourlyAppUpdateIfDue(now, probe)
    if probe.Due != "20261020123000" || probe.Launches || probe.Saves
        throw Error("A nearer saved deadline was needlessly postponed")
    for due in ["", "20261021120000"] {
        probe := HourlyUpdateProbe(), probe.Busy := true, probe.Due := due
        StartHourlyAppUpdateIfDue(now, probe)
        if probe.Due != due || probe.Launches || probe.Saves
            throw Error("Setup's lock did not protect the hourly schedule")
    }
    probe := HourlyUpdateProbe(), probe.Busy := true
    StartHourlyAppUpdateIfDue(now, probe)
    if probe.Due != "" || probe.Launches
        throw Error("The service checked for updates before setup finished")
    probe.Busy := false
    StartHourlyAppUpdateIfDue(, probe)
    if DateDiff(probe.Due, A_NowUTC, "Seconds") < 3595
        throw Error("The real service entry did not schedule its next hour using current UTC")
    oldStopRequest := ServiceStopRequested
    ServiceStopRequested := true, stopped := false
    try {
        try HourlyAppUpdateOperations().Launch()
        catch Error as failure
            stopped := InStr(failure.Message, "service is stopping")
        if !stopped
            throw Error("A stopped service launched an hourly update worker")
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

CheckOpenLogsLocation(logger) {
    if AppEventLog.DefaultDirectory(false) != EnvGet("LOCALAPPDATA") "\CeratopsKeyboardLayout\Logs"
        || AppEventLog.DefaultDirectory(true) != A_AppDataCommon "\CeratopsKeyboardLayoutLogs"
        throw Error("The logs menu lost the ordinary or elevated writer's location")
    launches := [], reports := []
    launch := (command) => launches.Push(command)
    report := (failure) => reports.Push(failure.Message)
    for boundary in ["before", "after"] {
        launches.Length := 0, reports.Length := 0
        interrupted := InterruptInterfaceEffect.Bind(launch, "folder", "folder", boundary)
        if OpenAppLogsLocation(interrupted, report) || reports.Length != 1
            || launches.Length != (boundary = "after" ? 1 : 0)
            throw Error("An interrupted logs-folder request lost its failure or effect")
        Loop 2
            if !OpenAppLogsLocation(launch, report)
                throw Error("A fresh logs-folder request did not succeed")
        if reports.Length != 1
            throw Error("A successful logs-folder request reported a failure")
        for command in launches
            if command != '"' logger.Directory '"'
                throw Error("The logs menu opened a different folder from the active writer")
    }
}

class DiagnosticShortcutProbe extends KeyboardShortcutManager {
    AcceptPress(*) => 0 ; Exercise receipt/latch observations without conversion.
}

CheckRuntimeDiagnostics(root) {
    logger := AppEventLog("tray", root "\_runtime-diagnostics", 2048)
    previous := AppEventLog.Current
    AppEventLog.Current := logger
    try {
        manager := DiagnosticShortcutProbe(NoInstalledLayouts(), KeyboardShortcutSettings(logger.Directory "\_keys.ini"))
        manager.OnPress("en", "vk45")
        manager.HeldKeys["vk45"] := GetDiagnosticUptimeMilliseconds() - 60000
        Loop 3
            manager.OnPress("en", "vk45")
        if manager.PressCount != 4 || manager.IgnoredHeldCount != 3 || manager.HeldKeys.Count != 1
            throw Error("Shortcut diagnostics changed held-key behavior")
        AppConversionDiagnostics.Begin("PRIVATE_EDITOR_TEXT", 0, "PRIVATE_CLIPBOARD_TEXT")
        AppConversionDiagnostics.Mark("field-discovery")
        manager.WriteHealth(GetDiagnosticUptimeMilliseconds() + 5000)
        AppConversionDiagnostics.Finish("failed")
        content := FileRead(logger.Path, "UTF-8")
        if InStr(content, "PRIVATE_") || InStr(content, "vk45")
            || !InStr(content, "received=4 ignored=3 held=1")
            || !InStr(content, "stage=field-discovery") || !InStr(content, "result=failed")
            throw Error("Runtime diagnostics omitted state or recorded private input")
        if StrSplit(content, "shortcut.held-suppressed").Length != 2
            throw Error("A held key flooded its warning instead of reporting once per minute")
        manager.OnRelease("vk45")
        if manager.HeldKeys.Count
            throw Error("Diagnostic tracking prevented key release")
        Loop 40 {
            AppConversionDiagnostics.Begin("en", 0, "selected")
            AppConversionDiagnostics.Mark("text-conversion")
            AppConversionDiagnostics.Finish("completed")
        }
        CheckLogFiles(logger.Directory, 2048)
        if AppConversionDiagnostics.Stage != "idle" || AppConversionDiagnostics.StartedAt
            throw Error("A completed conversion left its diagnostic stage active")
    } finally AppEventLog.Current := previous

    events := [], processes := Map(9, 71)
    state := {Pid: 123, State: "alive", ExitCode: 0, Code: 0}
    readState := (handle) => state
    emit := (level, event, fields) => events.Push({Level: level, Event: event, Fields: fields})
    health := CompanionHealthDiagnostics()
    health.Record(processes, 0, readState, emit)
    health.Record(processes, 1, readState, emit)
    if events.Length != 2
        throw Error("Unchanged service health was logged more than once per ten minutes")
    state.State := "exited", state.ExitCode := 9
    health.Record(processes, 2, readState, emit)
    health.Record(processes, 3, readState, emit)
    if events.Length != 3 || events[3].Level != "WARN" || !InStr(events[3].Fields, "exit_code=9")
        throw Error("The service lost or repeated a companion exit diagnostic")
    health.Record(processes, 600000, readState, emit)
    if events.Length != 5
        throw Error("The service heartbeat did not remain periodic")
    health.Record(Map(), 600001, readState, emit)
    if health.Observed.Count
        throw Error("Logged-off sessions left unbounded diagnostic state")
    actual := ReadCompanionDiagnosticState(-1)
    if actual.State != "alive" || actual.Pid != DllCall("GetCurrentProcessId", "UInt")
        throw Error("The service could not inspect a live process handle")
    actual := ReadCompanionDiagnosticState(0)
    if actual.State != "query-failed" || !actual.Code
        throw Error("The service discarded the native failure code")
    for boundary in ["before", "after"] {
        interrupted := CompanionHealthDiagnostics()
        observed := InterruptInterfaceEffect.Bind(emit, "record", "record", boundary)
        ExpectInterfaceInterruption(interrupted.Record.Bind(interrupted, processes, 0, readState, observed))
        Loop 2
            interrupted.Record(processes, 0, readState, emit)
        if interrupted.Observed.Count != 1 || interrupted.LastReport != 0
            throw Error("A fresh health observation did not finish after an interruption")
    }
}

CheckOperationalLogs(root) {
    directory := root "\_operational-logs-" DllCall("GetCurrentProcessId")
    try {
        CheckRuntimeDiagnostics(directory)
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
        try {
            CheckOpenLogsLocation(logger)
            WriteAppError("test.failure", Error("PRIVATE_EDITOR_TEXT", , "PRIVATE_CLIPBOARD_TEXT"))
        } finally AppEventLog.Current := previous
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
if A_Args.Length && A_Args[A_Args.Length] = "--update-schedule-only" {
    try {
        CheckHourlyAutomaticUpdates()
        FileAppend("PASS hourly update deadlines, restarts, setup locks and interrupted/fresh effects`n", "*")
        ExitApp(0)
    } catch Error as failure {
        FileAppend("FAIL: " failure.Message " (line " failure.Line ")`n", "*")
        ExitApp(1)
    }
}
if A_Args.Length && A_Args[A_Args.Length] = "--dispatch-only" {
    try {
        CheckDispatchInterruptions()
        CheckCompanionShutdown()
        CheckForceRestartTransitions()
        CheckOwnedTrayProcessTermination()
        CheckHourlyAutomaticUpdates()
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
        for legacyProtocol in [false, true]
            CheckPhysicalTrayHover(A_Args[1], legacyProtocol)
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
