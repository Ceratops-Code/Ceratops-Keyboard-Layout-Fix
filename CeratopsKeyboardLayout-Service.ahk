#Requires AutoHotkey v2.0.19+
#SingleInstance Off
#NoTrayIcon

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
global SkipInitialUpdateCheck := false

if A_Args.Length = 3 && A_Args[1] = "--preflight" {
    try outcome := PreflightElevatedLaunch(A_Args[2])
    catch Error as failure
        outcome := failure.Message
    try FileAppend(outcome "`n", A_Args[3], "UTF-8-RAW")
    catch Error
        ExitApp(2)
    ExitApp(outcome = "OK" ? 0 : 1)
}
if (A_Args.Length = 3 || A_Args.Length = 4) && A_Args[1] = "--install" {
    skipUpdateCheck := A_Args.Length = 4 && A_Args[4] = "--skip-update-check"
    outcome := InstallElevatedService(A_Args[2], skipUpdateCheck)
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

; Setup calls --install only after copying every executable file to Program
; Files. The one-time task checks the actual SYSTEM token launch before any
; persistent service exists. Every task and probe file is removed on success
; and failure; setup retains only the one-line outcome until it displays it.
InstallElevatedService(tempDirectory, skipUpdateCheck := false) {
    global ServiceName
    if !A_IsAdmin
        return "FALLBACK Installer is not elevated"
    try {
        imagePath := ExpectedServiceImagePath()
        existingPath := RegRead("HKLM\SYSTEM\CurrentControlSet\Services\" ServiceName,
            "ImagePath", "")
        if existingPath != "" && StrLower(existingPath) != StrLower(imagePath)
            return "FALLBACK Service name belongs to another program"

        probeResult := PreflightElevatedLaunch(tempDirectory)
        if probeResult != "OK" {
            if existingPath != ""
                RemoveOwnedService()
            return "FALLBACK " probeResult
        }
        try {
            RegisterAndStartService(existingPath != "", skipUpdateCheck)
            return "SERVICE_INSTALLED"
        } catch Error as failure {
            RemoveOwnedService()
            return "FALLBACK Service startup: " failure.Message
        }
    } catch Error as failure {
        return "FALLBACK " failure.Message
    }
}

ExpectedServiceImagePath() {
    return '"' A_ScriptDir '\CeratopsKeyboardLayout.exe" /script "'
        . A_ScriptFullPath '" --service'
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

QueryServiceState(serviceHandle) {
    state := Buffer(36, 0), needed := 0
    if !DllCall("advapi32\QueryServiceStatusEx", "Ptr", serviceHandle,
        "Int", 0, "Ptr", state, "UInt", state.Size, "UInt*", &needed, "Int")
        throw Error("QueryServiceStatusEx " A_LastError)
    return NumGet(state, 4, "UInt")
}

WaitForServiceState(serviceHandle, expectedState) {
    Loop 50 {
        if QueryServiceState(serviceHandle) = expectedState
            return true
        Sleep(200)
    }
    return false
}

StopService(serviceHandle) {
    if QueryServiceState(serviceHandle) = 1
        return
    status := Buffer(28, 0)
    DllCall("advapi32\ControlService", "Ptr", serviceHandle, "UInt", 1,
        "Ptr", status, "Int")
    if !WaitForServiceState(serviceHandle, 1)
        throw Error("Service did not stop")
}

RegisterAndStartService(alreadyExists, skipUpdateCheck := false) {
    global ServiceName
    manager := OpenServiceManager(0x3)
    service := 0
    try {
        if alreadyExists {
            service := DllCall("advapi32\OpenServiceW", "Ptr", manager,
                "Str", ServiceName, "UInt", 0xF01FF, "Ptr")
            if !service
                throw Error("OpenService " A_LastError)
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
        ; SCM start arguments are temporary, unlike ImagePath. An upgrade must
        ; not prompt again when its replacement tray instance starts.
        startArgument := "--skip-update-check"
        startArguments := Buffer(A_PtrSize, 0)
        NumPut("Ptr", StrPtr(startArgument), startArguments)
        if !DllCall("advapi32\StartServiceW", "Ptr", service,
            "UInt", skipUpdateCheck ? 1 : 0,
            "Ptr", skipUpdateCheck ? startArguments.Ptr : 0, "Int")
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
ServiceMain(argumentCount, arguments) {
    global ServiceName, ServiceStatusHandle, ServiceControlCallback, ServiceStopRequested
    global SkipInitialUpdateCheck
    ; The first SCM argument is the service name; the remainder belong only to
    ; this start. Never persist the updater's suppression in service settings.
    Loop Max(0, argumentCount - 1)
        if StrGet(NumGet(arguments, A_Index * A_PtrSize, "Ptr")) = "--skip-update-check"
            SkipInitialUpdateCheck := true
    ServiceStatusHandle := DllCall("advapi32\RegisterServiceCtrlHandlerExW",
        "Str", ServiceName, "Ptr", ServiceControlCallback, "Ptr", 0, "Ptr")
    if !ServiceStatusHandle
        return
    SetServiceState(2)
    exitCode := 0
    try {
        SetServiceState(4, 1 | 4)
        while !ServiceStopRequested {
            try StartMissingCompanions()
            ; AHK Sleep pumps its pseudo-thread scheduler. In the service
            ; callback that can leave the interrupted service loop suspended
            ; after a control callback, so wait on the native thread instead.
            DllCall("kernel32\Sleep", "UInt", 2000)
        }
    } catch Error {
        exitCode := 1
    } finally {
        StopCompanions()
        SetServiceState(1, 0, exitCode)
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
        NumPut("UInt", 5000, status, 24) ; Five-second start/stop hint.
    }
    DllCall("advapi32\SetServiceStatus", "Ptr", ServiceStatusHandle,
        "Ptr", status, "Int")
}

StartMissingCompanions() {
    global CompanionProcesses, SkipInitialUpdateCheck
    for sessionId in ActiveUserSessions() {
        if CompanionProcesses.Has(sessionId)
            continue
        try CompanionProcesses[sessionId] := LaunchDesktopCompanion(sessionId,
            false, false, SkipInitialUpdateCheck).handle
    }
    SkipInitialUpdateCheck := false
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

StopCompanions() {
    global CompanionProcesses
    for sessionId, handle in CompanionProcesses {
        if DllCall("kernel32\WaitForSingleObject", "Ptr", handle, "UInt", 0,
            "UInt") = 0x102
            DllCall("kernel32\TerminateProcess", "Ptr", handle, "UInt", 0)
        DllCall("kernel32\CloseHandle", "Ptr", handle)
    }
    CompanionProcesses.Clear()
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
