#Requires AutoHotkey v2.0.19+
#SingleInstance Off
#NoTrayIcon
#Include Write-AppEventLog.ahk

; Runs only from an administrator-writable installation directory. LocalSystem
; uses a logged-on administrator's linked elevated token to start the Ceratops
; tray script in that user's desktop session. A standard user's desktop gets
; an ordinary token instead. Tokens are closed after process creation; no text
; or credentials are stored.
global ServiceName := "CeratopsKeyboardLayoutService"
global ServiceStopRequested := false
global ServiceStatusHandle := 0
global ServiceControlCallback := 0
global ServiceMainCallback := 0
global CompanionProcesses := Map()
global ServiceAppDirectoryOverride := ""

; The desktop test includes these service functions without running the SCM entry.
if A_LineFile = A_ScriptFullPath {
; The updater reuses the hidden command host and the same bounded writer. This
; command must not create another tray icon or invoke AHK's singleton prompt.
if A_Args.Length = 4 && A_Args[1] = "--write-event" {
    try {
        logger := AppEventLog("updater")
        logger.Write(A_Args[2], A_Args[3], "code=" Integer(A_Args[4]))
        ExitApp(0)
    } catch Error as failure {
        ReportAppLogFailure(failure)
        ExitApp(1)
    }
}
InitializeAppEventLog(A_Args.Length && A_Args[1] = "--service" ? "service"
    : A_Args.Length && A_Args[1] = "--force-restart" ? "recovery" : "setup")
if A_Args.Length = 2 && A_Args[1] = "--prepare-upgrade" {
    try {
        if !A_IsAdmin || !RegExMatch(A_Args[2], "i)^[a-z]:\\")
            throw Error("Upgrade preparation requires an elevated installer and an absolute installation path.")
        fullPath := Buffer(65536, 0)
        if !DllCall("GetFullPathNameW", "Str", A_Args[2], "UInt", 32768,
            "Ptr", fullPath, "Ptr", 0)
            throw OSError()
        ServiceAppDirectoryOverride := RTrim(StrGet(fullPath), "\")
        PrepareOwnedAppUpgrade(ServiceRestartOperations(true, true))
        WriteAppEvent("INFO", "upgrade.prepared")
        ExitApp(0)
    } catch Error as failure {
        WriteAppError("upgrade.prepare-failed", failure)
        FileAppend(failure.Message "`n", "**", "UTF-8")
        ExitApp(1)
    }
}
if A_Args.Length = 1 && A_Args[1] = "--force-restart" {
    if !A_IsAdmin {
        try Run('*RunAs "' A_AhkPath '" /script "' A_ScriptFullPath
            . '" --force-restart', A_ScriptDir, "Hide")
        catch Error as failure
            MsgBox("Could not obtain permission to restart Ceratops.`n`n" failure.Message,
                "Ceratops Keyboard Layout", "Icon!")
        ExitApp()
    }
    try {
        ForceRestartOwnedService()
        ExitApp(0)
    } catch Error as failure {
        WriteAppError("restart.failed", failure)
        MsgBox("Ceratops could not finish the force restart.`n`n" failure.Message,
            "Ceratops Keyboard Layout", "Icon!")
        ExitApp(1)
    }
}
if A_Args.Length = 3 && A_Args[1] = "--preflight" {
    try outcome := PreflightElevatedLaunch(A_Args[2])
    catch Error as failure
        outcome := failure.Message
    try FileAppend(outcome "`n", A_Args[3], "UTF-8-RAW")
    catch Error
        ExitApp(2)
    ExitApp(outcome = "OK" ? 0 : 1)
}
if A_Args.Length = 3 && A_Args[1] = "--install" {
    outcome := InstallElevatedService(A_Args[2])
    WriteAppEvent(outcome = "SERVICE_INSTALLED" ? "INFO" : "WARN",
        outcome = "SERVICE_INSTALLED" ? "setup.service-installed" : "setup.startup-fallback")
    try FileAppend(outcome "`n", A_Args[3], "UTF-8-RAW")
    catch Error
        ExitApp(2)
    ExitApp(outcome = "SERVICE_INSTALLED" ? 0 : 1)
}
if A_Args.Length = 1 && A_Args[1] = "--uninstall" {
    try {
        RemoveOwnedService()
        ExitApp(0)
    } catch Error {
        ExitApp(1)
    }
}
if A_Args.Length = 1 && A_Args[1] = "--stop" {
    try {
        StopOwnedService()
        ExitApp(0)
    } catch Error {
        ExitApp(1)
    }
}
if A_Args.Length = 2 && A_Args[1] = "--probe" {
    result := ProbeElevatedLaunch()
    try FileAppend(result "`n", A_Args[2], "UTF-8-RAW")
    catch Error
        ExitApp(2)
    ExitApp(result = "OK" ? 0 : 1)
}
if A_Args.Length != 1 || A_Args[1] != "--service"
    ExitApp(2)

ServiceMainCallback := CallbackCreate(ServiceMain, , 2)
ServiceControlCallback := CallbackCreate(ServiceControl, , 4)
serviceTable := Buffer(A_PtrSize * 4, 0)
NumPut("Ptr", StrPtr(ServiceName), serviceTable, 0)
NumPut("Ptr", ServiceMainCallback, serviceTable, A_PtrSize)
if !DllCall("advapi32\StartServiceCtrlDispatcherW", "Ptr", serviceTable, "Int")
    ExitApp(3)
CallbackFree(ServiceControlCallback)
CallbackFree(ServiceMainCallback)
ExitApp(0)
}

; Setup calls --install only after copying every executable file to Program
; Files. The one-time task checks the actual SYSTEM token launch before any
; persistent service exists. Every task and probe file is removed on success
; and failure; setup retains only the one-line outcome until it displays it.
InstallElevatedService(tempDirectory) {
    global ServiceName
    if !A_IsAdmin
        return "FALLBACK Installer is not elevated"
    try {
        imagePath := ExpectedServiceImagePath()
        existingPath := RegRead("HKLM\SYSTEM\CurrentControlSet\Services\" ServiceName,
            "ImagePath", "")
        if existingPath != "" && StrLower(existingPath) != StrLower(imagePath)
            return "FALLBACK Service name belongs to another program"

        ; An owned service must remain installed during an unattended upgrade.
        ; With nobody signed in there is no desktop token to probe; the service
        ; starts normally and launches a tray when a user next signs in.
        probeResult := ServiceInstallNeedsDesktopProbe(existingPath, ActiveUserSessions())
            ? PreflightElevatedLaunch(tempDirectory) : "OK"
        if probeResult != "OK" {
            if existingPath != ""
                RemoveOwnedService()
            return "FALLBACK " probeResult
        }
        try {
            RegisterAndStartService(existingPath != "")
            return "SERVICE_INSTALLED"
        } catch Error as failure {
            WriteAppError("service.install-failed", failure)
            RemoveOwnedService()
            return "FALLBACK Service startup: " failure.Message
        }
    } catch Error as failure {
        WriteAppError("service.install-failed", failure)
        return "FALLBACK " failure.Message
    }
}

ServiceInstallNeedsDesktopProbe(existingPath, sessions) => existingPath = "" || sessions.Length > 0

ExpectedServiceImagePath() {
    directory := GetServiceAppDirectory()
    return '"' directory '\CeratopsKeyboardLayout.exe" /script "'
        . directory '\CeratopsKeyboardLayout-Service.ahk" --service'
}

GetServiceAppDirectory() {
    global ServiceAppDirectoryOverride
    if ServiceAppDirectoryOverride != ""
        return ServiceAppDirectoryOverride
    SplitPath(A_LineFile, , &directory)
    return directory
}

; The worker lives outside the tray/service processes it replaces. Each request
; reads current SCM/process state; logs never decide which effects remain.
ForceRestartOwnedService(operations := ServiceRestartOperations()) {
    StopOwnedInstallation(operations, true)
}

PrepareOwnedAppUpgrade(operations := ServiceRestartOperations(true)) {
    StopOwnedInstallation(operations, false)
}

StopOwnedInstallation(operations, restartAfterStop) {
    lock := operations.Acquire()
    phase := "opening the service"
    try {
        target := operations.Open()
        try {
            phase := "stopping the service"
            operations.Stop(target)
            phase := "terminating the previous installation processes"
            operations.StopProcesses()
            if restartAfterStop {
                phase := "starting the replacement service"
                operations.Start(target)
                WriteAppEvent("INFO", "restart.completed")
            }
        } finally operations.Close(target)
    } catch Error as failure {
        failure.Message := (restartAfterStop ? "Force restart" : "Upgrade preparation")
            . " failed while " phase ": " failure.Message
        throw failure
    } finally operations.Release(lock)
}

class ServiceRestartOperations {
    __New(allowMissingService := false, installerOwnsLock := false) {
        this.AllowMissingService := allowMissingService
        this.InstallerOwnsLock := installerOwnsLock
    }

    Acquire() {
        if this.InstallerOwnsLock {
            ; Setup holds this same lock through file replacement and startup.
            ; The extracted worker must not release its parent's lock.
            handle := DllCall("OpenMutexW", "UInt", 0x100001, "Int", false,
                "Str", "Global\CeratopsKeyboardLayout-ForceRestart", "Ptr")
            if !handle
                throw Error("The installer does not hold the restart lock.")
            try {
                state := DllCall("WaitForSingleObject", "Ptr", handle, "UInt", 0, "UInt")
                if state = 0 || state = 0x80
                    DllCall("ReleaseMutex", "Ptr", handle)
            } finally DllCall("CloseHandle", "Ptr", handle)
            if state != 0x102
                throw Error("The installer must own the restart lock before preparing an upgrade.")
            return 0
        }
        handle := DllCall("CreateMutexW", "Ptr", 0, "Int", false,
            "Str", "Global\CeratopsKeyboardLayout-ForceRestart", "Ptr")
        if !handle
            throw OSError()
        state := DllCall("WaitForSingleObject", "Ptr", handle, "UInt", 0, "UInt")
        if state != 0 && state != 0x80 {
            DllCall("CloseHandle", "Ptr", handle)
            throw Error("Another force restart is running, or its lock is inaccessible.")
        }
        return handle
    }

    Release(handle) {
        if !handle
            return
        DllCall("ReleaseMutex", "Ptr", handle)
        DllCall("CloseHandle", "Ptr", handle)
    }

    Open() {
        global ServiceName
        image := RegRead("HKLM\SYSTEM\CurrentControlSet\Services\" ServiceName,
            "ImagePath", "")
        if image = "" && this.AllowMissingService
            return {Manager: 0, Service: 0}
        if image = ""
            throw Error("This installation has no Ceratops service to restart.")
        if StrLower(image) != StrLower(ExpectedServiceImagePath())
            throw Error("The registered service belongs to another installation.")
        manager := OpenServiceManager(1)
        service := DllCall("advapi32\OpenServiceW", "Ptr", manager, "Str", ServiceName,
            "UInt", 0x34, "Ptr") ; QUERY_STATUS | START | STOP.
        if !service {
            code := A_LastError
            DllCall("advapi32\CloseServiceHandle", "Ptr", manager)
            throw OSError(code)
        }
        return {Manager: manager, Service: service}
    }

    Close(target) {
        if target.Service
            DllCall("advapi32\CloseServiceHandle", "Ptr", target.Service)
        if target.Manager
            DllCall("advapi32\CloseServiceHandle", "Ptr", target.Manager)
    }

    Stop(target) {
        service := target.Service
        if !service
            return
        current := QueryServiceStatus(service)
        if current.State = 1
            return
        WriteAppEvent("INFO", "service.stop-requested")
        if current.Type != 0x10
            throw Error("Refusing to terminate a shared service process.")
        if current.State != 3 {
            status := Buffer(28, 0)
            DllCall("advapi32\ControlService", "Ptr", service, "UInt", 1,
                "Ptr", status, "Int")
        }
        deadline := A_TickCount + 2000
        while A_TickCount < deadline {
            current := QueryServiceStatus(service)
            if current.State = 1
                return
            Sleep(100)
        }
        ; A stuck SCM control handler cannot prevent the worker from killing its
        ; exact service process. The opened handle and a fresh SCM PID check
        ; prevent a recycled PID from targeting a different process.
        current := QueryServiceStatus(service)
        if current.State = 1
            return
        identity := 0
        for process in ReadRunningAppProcesses()
            if process.Pid = current.Pid {
                identity := process
                break
            }
        if !identity || StrLower(Trim(identity.Command)) != StrLower(ExpectedServiceImagePath()) {
            if QueryServiceStatus(service).State = 1
                return
            throw Error("Windows could not establish the exact Ceratops service process identity.")
        }
        handle := OpenMatchingAppProcess(current.Pid, identity.Created)
        if !handle {
            if QueryServiceStatus(service).State = 1
                return
            throw Error("The service process disappeared before it could be stopped.")
        }
        try {
            latest := QueryServiceStatus(service)
            if latest.State != 1 && latest.Pid = current.Pid
                StopOwnedProcess(handle, "Ceratops service PID " current.Pid)
        } finally CloseCompanionHandle(handle)
        if !WaitForServiceState(service, 1)
            throw Error("Windows did not mark the terminated Ceratops service as stopped.")
    }

    StopProcesses() {
        ; Older service versions report STOPPED before their process exits.
        ; Wait/terminate that exact command too, before setup replaces its runtime.
        for process in ReadRunningAppProcesses() {
            if StrLower(Trim(process.Command)) != StrLower(ExpectedServiceImagePath())
                continue
            handle := OpenMatchingAppProcess(process.Pid, process.Created)
            if !handle
                continue
            try StopOwnedProcess(handle, "Ceratops service PID " process.Pid)
            finally CloseCompanionHandle(handle)
        }
        ; Terminate the producer first, so it cannot create another tray after
        ; the final snapshot used to clear old desktop companions.
        StopMatchingTrayProcesses()
    }

    Start(target) {
        current := QueryServiceStatus(target.Service)
        if current.State = 4
            return
        if current.State != 1
            throw Error("The Ceratops service is still changing state.")
        if !DllCall("advapi32\StartServiceW", "Ptr", target.Service, "UInt", 0,
            "Ptr", 0, "Int")
            throw OSError()
        if !WaitForServiceState(target.Service, 4)
            throw Error("The replacement Ceratops service did not reach running state.")
    }
}

ReadRunningAppProcesses() {
    result := []
    query := "SELECT ProcessId, ExecutablePath, CommandLine, CreationDate, SessionId"
        . " FROM Win32_Process WHERE Name='CeratopsKeyboardLayout.exe'"
    for process in ComObjGet("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2").ExecQuery(query)
        result.Push({Pid: process.ProcessId, Path: process.ExecutablePath,
            Command: process.CommandLine, Created: process.CreationDate, Session: process.SessionId})
    return result
}

ParseWindowsCommandArguments(command) {
    count := 0
    pointer := DllCall("Shell32\CommandLineToArgvW", "Str", command,
        "Int*", &count, "Ptr")
    if !pointer
        throw OSError()
    result := []
    try {
        Loop count
            result.Push(StrGet(NumGet(pointer, (A_Index - 1) * A_PtrSize, "Ptr")))
    } finally DllCall("LocalFree", "Ptr", pointer)
    return result
}

IsOwnedTrayProcess(process, sessionId := -1) {
    directory := GetServiceAppDirectory()
    if sessionId >= 0 && process.Session != sessionId
        return false
    if process.Command = ""
        return false
    arguments := ParseWindowsCommandArguments(process.Command)
    if !arguments.Length
        return false
    ; WMI can omit ExecutablePath even for a suspended child. Its command line
    ; selects candidates only; the opened process handle proves the image path.
    candidatePath := process.Path = "" ? arguments[1] : process.Path
    if StrLower(candidatePath) != StrLower(directory "\CeratopsKeyboardLayout.exe")
        return false
    if arguments.Length = 1
        return true ; Renamed AutoHotkey runtime's default script in the same folder.
    for index, argument in arguments {
        if index = 1
            continue
        if RegExMatch(argument, "i)^/(?:script|restart|force|ErrorStdOut(?:=.+)?|CP\d+)$")
            continue
        return StrLower(argument) = StrLower(directory "\CeratopsKeyboardLayout.ahk")
    }
    return false
}

ProcessCreationTimeFromWmi(value) {
    if !RegExMatch(value, "^(\d{14})\.(\d{6})([+-]\d{3})$", &parts)
        throw Error("Windows returned an unusable process creation time.")
    utc := DateAdd(parts[1], -Integer(parts[3]), "Minutes")
    systemTime := Buffer(16, 0)
    NumPut("UShort", Integer(SubStr(utc, 1, 4)), "UShort", Integer(SubStr(utc, 5, 2)), systemTime)
    NumPut("UShort", Integer(SubStr(utc, 7, 2)), "UShort", Integer(SubStr(utc, 9, 2)),
        "UShort", Integer(SubStr(utc, 11, 2)), "UShort", Integer(SubStr(utc, 13, 2)), systemTime, 6)
    fileTime := Buffer(8, 0)
    if !DllCall("SystemTimeToFileTime", "Ptr", systemTime, "Ptr", fileTime)
        throw OSError()
    return NumGet(fileTime, 0, "Int64") + Integer(parts[2]) * 10
}

OpenMatchingAppProcess(pid, created := "") {
    if !pid || pid = DllCall("GetCurrentProcessId", "UInt")
        return 0
    handle := DllCall("OpenProcess", "UInt", 0x101001, "Int", false, "UInt", pid, "Ptr")
    if !handle {
        if A_LastError = 87 ; Already exited.
            return 0
        throw OSError()
    }
    try {
        size := 32768, path := Buffer(size * 2, 0)
        if !DllCall("QueryFullProcessImageNameW", "Ptr", handle, "UInt", 0,
            "Ptr", path, "UInt*", &size)
            throw OSError()
        if StrLower(StrGet(path, size)) != StrLower(GetServiceAppDirectory() "\CeratopsKeyboardLayout.exe")
            throw Error("Refusing to terminate PID " pid ": its executable belongs to another app.")
        if created != "" {
            times := Buffer(32, 0)
            if !DllCall("GetProcessTimes", "Ptr", handle, "Ptr", times,
                "Ptr", times.Ptr + 8, "Ptr", times.Ptr + 16, "Ptr", times.Ptr + 24)
                throw OSError()
            ; WMI stores microseconds; FILETIME additionally has 100 ns digits.
            delta := NumGet(times, 0, "Int64") - ProcessCreationTimeFromWmi(created)
            if delta < 0 || delta > 9 {
                CloseCompanionHandle(handle)
                return 0
            }
        }
        return handle
    } catch Error {
        CloseCompanionHandle(handle)
        throw
    }
}

StopOwnedProcess(handle, description) {
    state := WaitForCompanionExit(handle, 0)
    if state = 0
        return
    if state != 0x102
        throw OSError()
    try TerminateCompanion(handle)
    catch Error {
        if WaitForCompanionExit(handle, 0) != 0
            throw
    }
    if WaitForCompanionExit(handle, 5000) != 0
        throw Error(description " did not exit after Windows force termination.")
    WriteAppEvent("WARN", "process.force-terminated")
}

StopMatchingTrayProcesses(sessionId := -1, readProcesses := ReadRunningAppProcesses,
    openProcess := OpenMatchingAppProcess, stopProcess := StopOwnedProcess,
    closeProcess := CloseCompanionHandle) {
    for process in readProcesses() {
        if !IsOwnedTrayProcess(process, sessionId)
            continue
        handle := openProcess(process.Pid, process.Created)
        if !handle
            continue
        try stopProcess(handle, "Ceratops tray PID " process.Pid)
        finally closeProcess(handle)
    }
}

XmlEscape(value) {
    return StrReplace(StrReplace(StrReplace(StrReplace(value, "&", "&amp;"),
        "<", "&lt;"), ">", "&gt;"), '"', "&quot;")
}

PreflightElevatedLaunch(tempDirectory) {
    processId := DllCall("kernel32\GetCurrentProcessId", "UInt")
    taskName := "CeratopsKeyboardLayout-Probe-" processId "-" Random(100000, 999999)
    taskFile := tempDirectory "\" taskName ".xml"
    resultFile := tempDirectory "\" taskName ".txt"
    taskCreated := false
    try {
        executable := XmlEscape(A_ScriptDir "\CeratopsKeyboardLayout.exe")
        arguments := XmlEscape('/script "' A_ScriptFullPath '" --probe "' resultFile '"')
        taskXml := '<?xml version="1.0" encoding="utf-16"?>'
            . '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
            . '<RegistrationInfo><URI>\' taskName '</URI></RegistrationInfo>'
            . '<Triggers><TimeTrigger><StartBoundary>2099-01-01T00:00:00</StartBoundary></TimeTrigger></Triggers>'
            . '<Principals><Principal id="Author"><UserId>S-1-5-18</UserId>'
            . '<RunLevel>HighestAvailable</RunLevel></Principal></Principals>'
            . '<Settings><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
            . '<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
            . '<ExecutionTimeLimit>PT1M</ExecutionTimeLimit></Settings>'
            . '<Actions Context="Author"><Exec><Command>' executable '</Command>'
            . '<Arguments>' arguments '</Arguments></Exec></Actions></Task>'
        FileAppend(taskXml, taskFile, "UTF-16")
        schtasks := '"' A_WinDir '\System32\schtasks.exe"'
        if RunWait(schtasks ' /Create /TN "' taskName '" /XML "' taskFile '"',
            , "Hide") != 0
            return "Temporary SYSTEM task could not be registered"
        taskCreated := true
        if RunWait(schtasks ' /Run /TN "' taskName '"', , "Hide") != 0
            return "Temporary SYSTEM task could not start"
        Loop 50 {
            if FileExist(resultFile) {
                result := Trim(FileRead(resultFile, "UTF-8"), " `t`r`n")
                return result
            }
            Sleep(200)
        }
        return "Temporary SYSTEM launch produced no result"
    } finally {
        taskRemains := false
        if taskCreated {
            deletionResult := RunWait('"' A_WinDir '\System32\schtasks.exe" /Delete /TN "'
                taskName '" /F', , "Hide")
            if deletionResult != 0
                taskRemains := RunWait('"' A_WinDir '\System32\schtasks.exe" /Query /TN "'
                    taskName '"', , "Hide") = 0
        }
        try FileDelete(taskFile)
        try FileDelete(resultFile)
        if taskRemains
            throw Error("Temporary SYSTEM task could not be removed: " taskName)
        if FileExist(taskFile) || FileExist(resultFile)
            throw Error("Temporary SYSTEM probe files could not be removed")
    }
}

OpenServiceManager(access) {
    handle := DllCall("advapi32\OpenSCManagerW", "Ptr", 0, "Ptr", 0,
        "UInt", access, "Ptr")
    if !handle
        throw Error("OpenSCManager " A_LastError)
    return handle
}

QueryServiceStatus(serviceHandle) {
    state := Buffer(36, 0), needed := 0
    if !DllCall("advapi32\QueryServiceStatusEx", "Ptr", serviceHandle,
        "Int", 0, "Ptr", state, "UInt", state.Size, "UInt*", &needed, "Int")
        throw Error("QueryServiceStatusEx " A_LastError)
    return {State: NumGet(state, 4, "UInt"), ExitCode: NumGet(state, 12, "UInt"),
        Type: NumGet(state, 0, "UInt"), Pid: NumGet(state, 28, "UInt")}
}

WaitForServiceState(serviceHandle, expectedState) {
    Loop 50 {
        status := QueryServiceStatus(serviceHandle)
        if status.State = expectedState
            return status
        Sleep(200)
    }
    return false
}

StopService(serviceHandle) {
    current := QueryServiceStatus(serviceHandle)
    if current.State = 1 && current.ExitCode = 0
        return
    if current.State = 1
        throw Error("Service had an incomplete shutdown (exit " current.ExitCode ")")
    status := Buffer(28, 0)
    DllCall("advapi32\ControlService", "Ptr", serviceHandle, "UInt", 1,
        "Ptr", status, "Int")
    stopped := WaitForServiceState(serviceHandle, 1)
    if !stopped
        throw Error("Service did not stop")
    if stopped.ExitCode != 0
        throw Error("Service had an incomplete shutdown (exit " stopped.ExitCode ")")
}

RegisterAndStartService(alreadyExists) {
    global ServiceName
    manager := OpenServiceManager(0x3)
    service := 0
    try {
        if alreadyExists {
            service := DllCall("advapi32\OpenServiceW", "Ptr", manager,
                "Str", ServiceName, "UInt", 0xF01FF, "Ptr")
            if !service
                throw Error("OpenService " A_LastError)
            if QueryServiceStatus(service).State != 1
                StopService(service)
            if !DllCall("advapi32\ChangeServiceConfigW", "Ptr", service,
                "UInt", 0xFFFFFFFF, "UInt", 2, "UInt", 0xFFFFFFFF,
                "Str", ExpectedServiceImagePath(), "Ptr", 0, "Ptr", 0,
                "Ptr", 0, "Str", "LocalSystem", "Ptr", 0,
                "Str", "Ceratops Keyboard Layout", "Int")
                throw Error("ChangeServiceConfig " A_LastError)
        } else {
            service := DllCall("advapi32\CreateServiceW", "Ptr", manager,
                "Str", ServiceName, "Str", "Ceratops Keyboard Layout",
                "UInt", 0xF01FF, "UInt", 0x10, "UInt", 2, "UInt", 1,
                "Str", ExpectedServiceImagePath(), "Ptr", 0, "Ptr", 0,
                "Ptr", 0, "Str", "LocalSystem", "Ptr", 0, "Ptr")
            if !service
                throw Error("CreateService " A_LastError)
        }
        if !DllCall("advapi32\StartServiceW", "Ptr", service,
            "UInt", 0, "Ptr", 0, "Int")
            throw Error("StartService " A_LastError)
        if !WaitForServiceState(service, 4)
            throw Error("Service did not reach running state")
    } finally {
        if service
            DllCall("advapi32\CloseServiceHandle", "Ptr", service)
        DllCall("advapi32\CloseServiceHandle", "Ptr", manager)
    }
}

; Never delete an unrelated service that happens to use the same name.
RemoveOwnedService() {
    global ServiceName
    imagePath := RegRead("HKLM\SYSTEM\CurrentControlSet\Services\" ServiceName,
        "ImagePath", "")
    if imagePath = ""
        return
    if StrLower(imagePath) != StrLower(ExpectedServiceImagePath())
        throw Error("Service name belongs to another program")
    manager := OpenServiceManager(0x1)
    service := 0
    try {
        service := DllCall("advapi32\OpenServiceW", "Ptr", manager,
            "Str", ServiceName, "UInt", 0xF01FF, "Ptr")
        if !service
            throw Error("OpenService " A_LastError)
        StopService(service)
        if !DllCall("advapi32\DeleteService", "Ptr", service, "Int")
            throw Error("DeleteService " A_LastError)
    } finally {
        if service
            DllCall("advapi32\CloseServiceHandle", "Ptr", service)
        DllCall("advapi32\CloseServiceHandle", "Ptr", manager)
    }
}

StopOwnedService() {
    global ServiceName
    imagePath := RegRead("HKLM\SYSTEM\CurrentControlSet\Services\" ServiceName,
        "ImagePath", "")
    if imagePath = ""
        return
    if StrLower(imagePath) != StrLower(ExpectedServiceImagePath())
        throw Error("Service name belongs to another program")
    manager := OpenServiceManager(0x1)
    service := 0
    try {
        service := DllCall("advapi32\OpenServiceW", "Ptr", manager,
            "Str", ServiceName, "UInt", 0xF01FF, "Ptr")
        if !service
            throw Error("OpenService " A_LastError)
        StopService(service)
    } finally {
        if service
            DllCall("advapi32\CloseServiceHandle", "Ptr", service)
        DllCall("advapi32\CloseServiceHandle", "Ptr", manager)
    }
}

ProbeElevatedLaunch() {
    for sessionId in ActiveUserSessions() {
        try {
            companion := LaunchDesktopCompanion(sessionId, true, true)
            DllCall("kernel32\TerminateProcess", "Ptr", companion.handle, "UInt", 0)
            DllCall("kernel32\CloseHandle", "Ptr", companion.handle)
            return "OK"
        } catch Error as failure {
            return "LAUNCH_FAILED " failure.Message
        }
    }
    return "NO_ACTIVE_USER_SESSION"
}

; The SCM calls this entry point on its service thread. It polls active sessions
; so logon and reconnect work without a scheduled task or interactive service.
InitializeServiceThreadCom() {
    ; AutoHotkey initializes its main thread, but SCM creates another native
    ; thread. WMI must have an apartment there before the first process lookup.
    result := DllCall("ole32\CoInitializeEx", "Ptr", 0, "UInt", 0x4, "Int")
    if result = -2147417850 ; RPC_E_CHANGED_MODE: an existing apartment is usable.
        return false ; Its owner must release it, not this service callback.
    if result < 0
        throw OSError(result, "CoInitializeEx")
    return true ; Both S_OK and S_FALSE require a matching CoUninitialize.
}

ServiceMain(argumentCount, arguments) {
    global ServiceName, ServiceStatusHandle, ServiceControlCallback, ServiceStopRequested
    ServiceStatusHandle := DllCall("advapi32\RegisterServiceCtrlHandlerExW",
        "Str", ServiceName, "Ptr", ServiceControlCallback, "Ptr", 0, "Ptr")
    if !ServiceStatusHandle
        return
    SetServiceState(2)
    exitCode := 0, ownsComApartment := false
    try {
        ownsComApartment := InitializeServiceThreadCom()
        SetServiceState(4, 1 | 4)
        WriteAppEvent("INFO", "service.started")
        dailyFailure := ""
        while !ServiceStopRequested {
            try StartMissingCompanions()
            catch Error as failure
                WriteAppError("companion.scan-failed", failure)
            if ServiceStopRequested
                break
            try {
                StartDailyAppUpdateIfDue()
                dailyFailure := ""
            } catch Error as failure {
                identity := Type(failure) ":" failure.Line
                if identity != dailyFailure
                    WriteAppError("update.daily-schedule-failed", failure)
                dailyFailure := identity
            }
            ; AHK Sleep pumps its pseudo-thread scheduler. In the service
            ; callback that can leave the interrupted service loop suspended
            ; after a control callback, so wait on the native thread instead.
            DllCall("kernel32\Sleep", "UInt", 2000)
        }
    } catch Error as failure {
        WriteAppError("service.failed", failure)
        exitCode := 1
    } finally {
        try StopCompanions()
        catch Error as failure {
            WriteAppError("companion.stop-failed", failure)
            exitCode := failure.Extra ? failure.Extra : 1
        }
        WriteAppEvent(exitCode ? "ERROR" : "INFO", "service.stopped", "code=" exitCode)
        SetServiceState(1, 0, exitCode)
        if ownsComApartment
            DllCall("ole32\CoUninitialize")
    }
}

; The schedule is active service configuration, never inferred from log records.
; Claim a daily attempt before launching: interruption or launch failure counts
; for that day and is reported, rather than retrying an unknown failure in a loop.
; A late/resumed service starts one check and skips missed days, without a burst.
StartDailyAppUpdateIfDue(now := A_NowUTC, operations := DailyAppUpdateOperations()) {
    due := operations.ReadNextCheck()
    if due != "" {
        if !RegExMatch(due, "^\d{14}$")
            throw ValueError("The automatic update schedule is not a UTC timestamp.")
        DateDiff(due, now, "Seconds") ; Reject impossible dates before any effect.
        if due > now
            return false
    }
    if operations.InstallationIsBusy()
        return false
    operations.SaveNextCheck(DateAdd(now, 1, "Days"))
    operations.Launch()
    WriteAppEvent("INFO", "update.daily-started")
    return true
}

class DailyAppUpdateOperations {
    InstallationIsBusy() {
        ; Setup retains the restart lock until its registration and copied files
        ; agree. Do not check an old registered version midway through an install.
        handle := DllCall("OpenMutexW", "UInt", 0x100001, "Int", false,
            "Str", "Global\CeratopsKeyboardLayout-ForceRestart", "Ptr")
        if !handle {
            if A_LastError = 2
                return false
            throw OSError()
        }
        try {
            state := DllCall("WaitForSingleObject", "Ptr", handle, "UInt", 0, "UInt")
            if state = 0 || state = 0x80 {
                DllCall("ReleaseMutex", "Ptr", handle)
                return false
            }
            if state != 0x102
                throw OSError()
            return true
        } finally DllCall("CloseHandle", "Ptr", handle)
    }

    ReadNextCheck() {
        global ServiceName
        return RegRead("HKLM\SYSTEM\CurrentControlSet\Services\" ServiceName "\Parameters",
            "NextAutomaticUpdateCheckUtc", "")
    }

    SaveNextCheck(value) {
        global ServiceName
        image := RegRead("HKLM\SYSTEM\CurrentControlSet\Services\" ServiceName, "ImagePath", "")
        if StrLower(image) != StrLower(ExpectedServiceImagePath())
            throw Error("Automatic updates require this installation's registered service.")
        RegWrite(value, "REG_SZ", "HKLM\SYSTEM\CurrentControlSet\Services\" ServiceName
            . "\Parameters", "NextAutomaticUpdateCheckUtc")
    }

    Launch() {
        global ServiceStopRequested
        if ServiceStopRequested
            throw Error("The service is stopping; the daily update worker was not launched.")
        directory := GetServiceAppDirectory()
        Run('"' A_WinDir '\System32\WindowsPowerShell\v1.0\powershell.exe"'
            . ' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'
            . directory '\Update-AppInstall.ps1" -Automatic', directory, "Hide")
    }
}

ServiceControl(control, eventType, eventData, context) {
    global ServiceStopRequested
    if control = 1 || control = 5 {
        ServiceStopRequested := true
        SetServiceState(3)
    }
    return 0
}

SetServiceState(state, acceptedControls := 0, exitCode := 0) {
    global ServiceStatusHandle
    status := Buffer(28, 0) ; SERVICE_STATUS is seven DWORDs.
    NumPut("UInt", 0x10, status, 0) ; SERVICE_WIN32_OWN_PROCESS
    NumPut("UInt", state, status, 4)
    NumPut("UInt", acceptedControls, status, 8)
    NumPut("UInt", exitCode, status, 12)
    if state = 2 || state = 3 {
        NumPut("UInt", 1, status, 20) ; One pending checkpoint.
        NumPut("UInt", state = 3 ? 10000 : 5000, status, 24) ; Stop includes the tray wait.
    }
    DllCall("advapi32\SetServiceStatus", "Ptr", ServiceStatusHandle,
        "Ptr", status, "Int")
}

StartMissingCompanions() {
    global CompanionProcesses
    for sessionId in ActiveUserSessions() {
        if CompanionProcesses.Has(sessionId)
            continue
        try {
            CompanionProcesses[sessionId] := LaunchDesktopCompanion(sessionId,
                false, false, true).handle
            WriteAppEvent("INFO", "companion.started", "session=" sessionId)
        } catch Error as failure
            WriteAppError("companion.launch-failed", failure)
    }
    ; A user Exit is respected for the rest of that sign-in. Once the session
    ; logs off and its token disappears, its id may be used by a future logon.
    forgottenSessions := []
    for sessionId, handle in CompanionProcesses {
        token := 0
        if !DllCall("wtsapi32\WTSQueryUserToken", "UInt", sessionId,
            "Ptr*", &token, "Int") {
            forgottenSessions.Push(sessionId)
        } else {
            DllCall("kernel32\CloseHandle", "Ptr", token)
        }
    }
    for sessionId in forgottenSessions {
        DllCall("kernel32\CloseHandle", "Ptr", CompanionProcesses[sessionId])
        CompanionProcesses.Delete(sessionId)
    }
}

WaitForCompanionExit(handle, milliseconds) => DllCall("kernel32\WaitForSingleObject",
    "Ptr", handle, "UInt", milliseconds, "UInt")

TerminateCompanion(handle) {
    if !DllCall("kernel32\TerminateProcess", "Ptr", handle, "UInt", 0)
        throw OSError()
}

CloseCompanionHandle(handle) {
    if !DllCall("kernel32\CloseHandle", "Ptr", handle)
        throw OSError()
}

StopCompanions(wait := WaitForCompanionExit, terminate := TerminateCompanion,
    close := CloseCompanionHandle) {
    global CompanionProcesses
    stoppedSessions := [], firstFailure := ""
    ; One deadline bounds all desktop sessions within the installer's stop wait.
    deadline := A_TickCount + 5000
    for sessionId, handle in CompanionProcesses {
        try {
            state := wait(handle, 0)
            if state = 0x102 {
                try terminate(handle)
                catch Error as failure {
                    ; A process can exit between the first wait and termination.
                    if wait(handle, 0) != 0
                        throw failure
                }
                state := wait(handle, Max(0, deadline - A_TickCount))
            }
            if state = 0x102
                throw Error("tray process did not exit within five seconds", , 1460)
            if state = 0xFFFFFFFF
                throw OSError()
            if state != 0
                throw Error("unexpected process wait result " state)
            close(handle)
            stoppedSessions.Push(sessionId)
        } catch Error as failure {
            if firstFailure = "" {
                code := failure is OSError ? failure.Number
                    : failure.Extra = 1460 ? 1460 : 1
                firstFailure := Error("Could not stop tray process in session " sessionId
                    . ": " failure.Message, , code ? code : 1)
            }
        }
    }
    for sessionId in stoppedSessions
        CompanionProcesses.Delete(sessionId)
    if firstFailure != ""
        throw firstFailure
}

ActiveUserSessions() {
    sessions := 0, count := 0, result := []
    if !DllCall("wtsapi32\WTSEnumerateSessionsW", "Ptr", 0, "UInt", 0,
        "UInt", 1, "Ptr*", &sessions, "UInt*", &count, "Int")
        throw Error("WTSEnumerateSessions " A_LastError)
    try {
        Loop count {
            entry := sessions + (A_Index - 1) * 24 ; WTS_SESSION_INFOW on x64.
            sessionId := NumGet(entry, 0, "UInt")
            state := NumGet(entry, 16, "UInt")
            if sessionId && state = 0 ; WTSActive
                result.Push(sessionId)
        }
    } finally {
        DllCall("wtsapi32\WTSFreeMemory", "Ptr", sessions)
    }
    return result
}

LaunchDesktopCompanion(sessionId, suspended := false, requireElevation := false,
    skipUpdateCheck := false) {
    userToken := 0, linkedToken := 0, primaryToken := 0, environment := 0
    try {
        if !DllCall("wtsapi32\WTSQueryUserToken", "UInt", sessionId,
            "Ptr*", &userToken, "Int")
            throw Error("WTSQueryUserToken " A_LastError)

        elevationType := Buffer(4, 0), needed := 0
        if !DllCall("advapi32\GetTokenInformation", "Ptr", userToken,
            "Int", 18, "Ptr", elevationType, "UInt", 4, "UInt*", &needed, "Int")
            throw Error("TokenElevationType " A_LastError)
        sourceToken := userToken
        if NumGet(elevationType, 0, "UInt") = 3 { ; Limited token under UAC.
            linked := Buffer(A_PtrSize, 0)
            if DllCall("advapi32\GetTokenInformation", "Ptr", userToken,
                "Int", 19, "Ptr", linked, "UInt", linked.Size,
                "UInt*", &needed, "Int") {
                linkedToken := NumGet(linked, 0, "Ptr")
                sourceToken := linkedToken
            } else if requireElevation {
                throw Error("TokenLinkedToken " A_LastError)
            }
        }
        elevation := Buffer(4, 0)
        if !DllCall("advapi32\GetTokenInformation", "Ptr", sourceToken,
            "Int", 20, "Ptr", elevation, "UInt", 4,
            "UInt*", &needed, "Int")
            throw Error("TokenElevation " A_LastError)
        if requireElevation && !NumGet(elevation, 0, "UInt")
            throw Error("The signed-in account has no elevated token")

        if !DllCall("advapi32\DuplicateTokenEx", "Ptr", sourceToken,
            "UInt", 0xF01FF, "Ptr", 0, "Int", 2, "Int", 1,
            "Ptr*", &primaryToken, "Int")
            throw Error("DuplicateTokenEx " A_LastError)
        if !DllCall("userenv\CreateEnvironmentBlock", "Ptr*", &environment,
            "Ptr", primaryToken, "Int", 0, "Int")
            throw Error("CreateEnvironmentBlock " A_LastError)

        executable := A_ScriptDir "\CeratopsKeyboardLayout.exe"
        script := A_ScriptDir "\CeratopsKeyboardLayout.ahk"
        ; The SYSTEM owner can terminate a stuck prior tray directly. AutoHotkey's
        ; /restart only asks it to close and can strand a "keep waiting" dialog.
        ; Suspended installation probes must never replace a live tray process.
        if !suspended
            StopMatchingTrayProcesses(sessionId)
        command := '"' executable '" /script "' script '"'
        if skipUpdateCheck
            command .= " --skip-update-check"
        commandLine := Buffer(StrPut(command, "UTF-16") * 2, 0)
        StrPut(command, commandLine, "UTF-16")
        desktop := "winsta0\default"
        startup := Buffer(104, 0) ; STARTUPINFOW on x64.
        NumPut("UInt", startup.Size, startup, 0)
        NumPut("Ptr", StrPtr(desktop), startup, 16)
        processInfo := Buffer(24, 0) ; PROCESS_INFORMATION on x64.
        flags := 0x400 | (suspended ? 0x4 : 0) ; Unicode environment.
        if !DllCall("advapi32\CreateProcessAsUserW", "Ptr", primaryToken,
            "Str", executable, "Ptr", commandLine.Ptr, "Ptr", 0, "Ptr", 0,
            "Int", 0, "UInt", flags, "Ptr", environment, "Str", A_ScriptDir,
            "Ptr", startup, "Ptr", processInfo, "Int")
            throw Error("CreateProcessAsUser " A_LastError)
        threadHandle := NumGet(processInfo, 8, "Ptr")
        processHandle := NumGet(processInfo, 0, "Ptr")
        DllCall("kernel32\CloseHandle", "Ptr", threadHandle)
        return {handle: processHandle, pid: NumGet(processInfo, 16, "UInt")}
    } finally {
        if environment
            DllCall("userenv\DestroyEnvironmentBlock", "Ptr", environment)
        for handle in [primaryToken, linkedToken, userToken]
            if handle
                DllCall("kernel32\CloseHandle", "Ptr", handle)
    }
}
