#Requires AutoHotkey v2.0.19+

; Operational records only. Callers supply fixed event names and numeric/error
; locations, never editor text, clipboard contents, exception messages or stacks.
; Each component owns a current file and two predecessors, all capped at 1 MiB.
; A delete-on-close lock serializes writers; files are never recovery checkpoints.
class AppEventLog {
    static Current := 0

    __New(component, directory := "", maximumBytes := 1048576, observe := unset) {
        if !RegExMatch(component, "^(tray|service|recovery|setup|updater)$")
            throw ValueError("Unknown operational log component.")
        this.Protected := directory = "" && A_IsAdmin
        this.Directory := directory != "" ? directory : AppEventLog.DefaultDirectory()
        this.Component := component, this.MaximumBytes := maximumBytes
        this.Path := this.Directory "\" component ".log"
        this.Observe := IsSet(observe) ? observe : (*) => 0
        this.WithLock(this.CheckRetainedFiles.Bind(this))
    }

    static DefaultDirectory(elevated := A_IsAdmin) {
        return elevated ? A_AppDataCommon "\CeratopsKeyboardLayoutLogs"
            : EnvGet("LOCALAPPDATA") "\CeratopsKeyboardLayout\Logs"
    }

    Write(level, event, fields := "") {
        if !RegExMatch(level, "^(INFO|WARN|ERROR)$")
            || !RegExMatch(event, "^[a-z][a-z0-9.-]{0,63}$")
            || !RegExMatch(fields, "^[A-Za-z0-9_.= :+()/-]{0,512}$")
            throw ValueError("Operational records require fixed names and safe metadata.")
        record := FormatTime(A_NowUTC, "yyyy-MM-dd'T'HH:mm:ss'Z'") " " level
            . " " this.Component " " event " pid=" DllCall("GetCurrentProcessId")
            . (fields = "" ? "" : " " fields) "`r`n"
        bytes := Buffer(StrPut(record, "UTF-8"))
        StrPut(record, bytes, "UTF-8")
        if bytes.Size - 1 > this.MaximumBytes
            throw ValueError("The operational record exceeds its file limit.")
        this.WithLock(this.AppendRecord.Bind(this, bytes))
    }

    Change(name, action) {
        observer := this.Observe
        observer(name, "before")
        action()
        observer(name, "after")
    }

    EnsureDirectory() {
        if DirExist(this.Directory)
            return
        if !this.Protected {
            this.Change("directory.create", (*) => DirCreate(this.Directory))
            return
        }
        ; This root is separate from user-writable shortcut settings. Its owner
        ; and protected ACL prevent an ordinary user from substituting log paths.
        descriptor := AppEventLog.SecurityDescriptor()
        attributes := Buffer(A_PtrSize = 8 ? 24 : 12, 0)
        NumPut("UInt", attributes.Size, attributes)
        NumPut("Ptr", descriptor, attributes, A_PtrSize = 8 ? 8 : 4)
        try this.Change("directory.create", (*) => this.CreateProtectedDirectory(attributes))
        finally DllCall("LocalFree", "Ptr", descriptor)
    }

    CreateProtectedDirectory(attributes) {
        if !DllCall("CreateDirectoryW", "Str", this.Directory, "Ptr", attributes)
            && A_LastError != 183
            throw OSError()
    }

    static SecurityDescriptor() {
        static owner := AppEventLog.IsSystemAccount() ? "SY" : "BA"
        descriptor := 0
        if !DllCall("advapi32\ConvertStringSecurityDescriptorToSecurityDescriptorW",
            "Str", "O:" owner "G:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FRFX;;;BU)",
            "UInt", 1, "Ptr*", &descriptor, "Ptr", 0)
            throw OSError()
        return descriptor
    }

    static IsSystemAccount() {
        token := 0, user := Buffer(256, 0), needed := 0, sid := 0
        if !DllCall("advapi32\OpenProcessToken", "Ptr", -1, "UInt", 8, "Ptr*", &token)
            throw OSError()
        try {
            if !DllCall("advapi32\GetTokenInformation", "Ptr", token, "Int", 1,
                "Ptr", user, "UInt", user.Size, "UInt*", &needed)
                throw OSError()
            if !DllCall("advapi32\ConvertSidToStringSidW", "Ptr", NumGet(user, 0, "Ptr"), "Ptr*", &sid)
                throw OSError()
            return StrGet(sid) = "S-1-5-18"
        } finally {
            if sid
                DllCall("LocalFree", "Ptr", sid)
            DllCall("CloseHandle", "Ptr", token)
        }
    }

    CheckProtectedHandle(handle) {
        owner := 0, security := 0, actualDacl := 0
        code := DllCall("advapi32\GetSecurityInfo", "Ptr", handle, "UInt", 1,
            "UInt", 5, "Ptr*", &owner, "Ptr", 0, "Ptr*", &actualDacl, "Ptr", 0, "Ptr*", &security)
        if code
            throw OSError(code)
        ownerText := 0, descriptor := 0
        try {
            if !DllCall("advapi32\ConvertSidToStringSidW", "Ptr", owner, "Ptr*", &ownerText)
                throw OSError()
            sid := StrGet(ownerText)
            if sid != "S-1-5-18" && sid != "S-1-5-32-544"
                throw Error("The protected operational log has an untrusted owner.")
            descriptor := AppEventLog.SecurityDescriptor()
            present := 0, defaulted := 0, expectedDacl := 0, control := 0, revision := 0
            if !DllCall("advapi32\GetSecurityDescriptorDacl", "Ptr", descriptor,
                "Int*", &present, "Ptr*", &expectedDacl, "Int*", &defaulted)
                || !DllCall("advapi32\GetSecurityDescriptorControl", "Ptr", security,
                    "UShort*", &control, "UInt*", &revision)
                throw OSError()
            ; Existing paths must already have this protected ACL. Refuse an
            ; altered folder/file instead of silently changing its permissions.
            if !actualDacl || !(control & 0x1000)
                || NumGet(actualDacl, 2, "UShort") != NumGet(expectedDacl, 2, "UShort")
                || DllCall("ntdll\RtlCompareMemory", "Ptr", actualDacl, "Ptr", expectedDacl,
                    "UPtr", NumGet(expectedDacl, 2, "UShort"), "UPtr") != NumGet(expectedDacl, 2, "UShort")
                throw Error("The protected operational log has unsafe permissions.")
        } finally {
            if descriptor
                DllCall("LocalFree", "Ptr", descriptor)
            if ownerText
                DllCall("LocalFree", "Ptr", ownerText)
            DllCall("LocalFree", "Ptr", security)
        }
    }

    CheckPlainHandle(handle, directory := false) {
        information := Buffer(52, 0)
        if !DllCall("GetFileInformationByHandle", "Ptr", handle, "Ptr", information)
            throw OSError()
        attributes := NumGet(information, 0, "UInt")
        if attributes & 0x400 || (!directory && (attributes & 0x10
            || NumGet(information, 40, "UInt") != 1))
            throw Error("Operational logs cannot use links or substituted files.")
        if this.Protected
            this.CheckProtectedHandle(handle)
    }

    OpenFile(path, access, creation := 3, flags := 0x00200080) {
        descriptor := 0, attributes := 0
        if this.Protected
            access |= 0x20000 ; READ_CONTROL, without permission-changing rights.
        if this.Protected && creation != 3 {
            descriptor := AppEventLog.SecurityDescriptor()
            attributes := Buffer(A_PtrSize = 8 ? 24 : 12, 0)
            NumPut("UInt", attributes.Size, attributes)
            NumPut("Ptr", descriptor, attributes, A_PtrSize = 8 ? 8 : 4)
        }
        try handle := DllCall("CreateFileW", "Str", path, "UInt", access, "UInt", 1,
            "Ptr", attributes, "UInt", creation, "UInt", flags, "Ptr", 0, "Ptr")
        finally {
            if descriptor
                DllCall("LocalFree", "Ptr", descriptor)
        }
        if handle = -1
            throw OSError()
        try this.CheckPlainHandle(handle)
        catch {
            DllCall("CloseHandle", "Ptr", handle)
            throw
        }
        return handle
    }

    WithLock(action) {
        this.EnsureDirectory()
        directory := DllCall("CreateFileW", "Str", this.Directory,
            "UInt", this.Protected ? 0x20080 : 0x80, "UInt", 3, "Ptr", 0,
            "UInt", 3, "UInt", 0x02200000, "Ptr", 0, "Ptr")
        if directory = -1
            throw OSError()
        lock := 0
        try {
            this.CheckPlainHandle(directory, true)
            deadline := A_TickCount + 2000
            loop {
                try {
                    lock := this.OpenFile(this.Path ".lock", 0xC0010000, 4, 0x04200000)
                    break
                } catch OSError as failure {
                    if failure.Number != 32 || A_TickCount >= deadline
                        throw failure
                    Sleep(20)
                }
            }
            return action()
        } finally {
            if lock
                DllCall("CloseHandle", "Ptr", lock)
            DllCall("CloseHandle", "Ptr", directory)
        }
    }

    FileSize(path) {
        if !FileExist(path)
            return 0
        handle := this.OpenFile(path, 0x80000000)
        try {
            size := 0
            if !DllCall("GetFileSizeEx", "Ptr", handle, "Int64*", &size)
                throw OSError()
            return size
        } finally DllCall("CloseHandle", "Ptr", handle)
    }

    CheckRetainedFiles() {
        ; No glob deletions: only this component's fixed history slots are owned.
        for path in [this.Path ".2", this.Path ".1", this.Path] {
            if this.FileSize(path) > this.MaximumBytes
                this.Change("oversized.delete", FileDelete.Bind(path))
        }
    }

    Rotate() {
        if FileExist(this.Path ".2")
            this.Change("oldest.delete", (*) => FileDelete(this.Path ".2"))
        if FileExist(this.Path ".1")
            this.Change("predecessor.move", (*) => FileMove(this.Path ".1", this.Path ".2", true))
        if FileExist(this.Path)
            this.Change("current.move", (*) => FileMove(this.Path, this.Path ".1", true))
    }

    AppendRecord(bytes) {
        this.CheckRetainedFiles()
        if this.FileSize(this.Path) + bytes.Size - 1 > this.MaximumBytes
            this.Rotate()
        handle := 0
        try {
            missing := !FileExist(this.Path)
            observer := this.Observe
            if missing
                observer("current.create", "before")
            handle := this.OpenFile(this.Path, 0xC0000000, missing ? 4 : 3)
            if missing
                observer("current.create", "after")
            this.RepairPartialRecord(handle)
            if !DllCall("SetFilePointerEx", "Ptr", handle, "Int64", 0, "Ptr", 0, "UInt", 2)
                throw OSError()
            this.Change("record.append", (*) => this.WriteBytes(handle, bytes))
            this.Change("record.flush", (*) => this.Flush(handle))
        } finally {
            if handle
                DllCall("CloseHandle", "Ptr", handle)
        }
    }

    RepairPartialRecord(handle) {
        size := 0
        if !DllCall("GetFileSizeEx", "Ptr", handle, "Int64*", &size)
            throw OSError()
        if !size
            return
        data := Buffer(size), read := 0
        if !DllCall("ReadFile", "Ptr", handle, "Ptr", data, "UInt", size, "UInt*", &read, "Ptr", 0)
            || read != size
            throw OSError()
        if NumGet(data, size - 1, "UChar") = 10
            return
        while size && NumGet(data, size - 1, "UChar") != 10
            size -= 1
        this.Change("partial.truncate", (*) => this.Truncate(handle, size))
    }

    Truncate(handle, size) {
        if !DllCall("SetFilePointerEx", "Ptr", handle, "Int64", size, "Ptr", 0, "UInt", 0)
            || !DllCall("SetEndOfFile", "Ptr", handle)
            throw OSError()
    }

    WriteBytes(handle, data) {
        written := 0
        if !DllCall("WriteFile", "Ptr", handle, "Ptr", data, "UInt", data.Size - 1,
            "UInt*", &written, "Ptr", 0) || written != data.Size - 1
            throw OSError()
    }

    Flush(handle) {
        if !DllCall("FlushFileBuffers", "Ptr", handle)
            throw OSError()
    }
}

GetDiagnosticUptimeMilliseconds() => DllCall("GetTickCount64", "UInt64")

class AppConversionDiagnostics {
    ; Observations only: never use these counters or logs to resume or skip work.
    ; Fixed stage names, numeric window/process/layout IDs and language labels
    ; cannot contain editor text, titles, clipboard data or pressed characters.
    static Request := 0
    static StartedAt := 0
    static Stage := "idle"
    static Completed := 0
    static Failed := 0

    static Begin(target, window, behavior) {
        this.Request += 1, this.StartedAt := GetDiagnosticUptimeMilliseconds(), this.Stage := "layouts"
        pid := 0
        try pid := WinGetPID("ahk_id " window)
        language := RegExMatch(target, "^(en|he|ru)$") ? target : "unknown"
        mode := behavior = "all" ? "all" : behavior = "selected" ? "selected" : "unknown"
        WriteAppEvent("INFO", "conversion.started", "request=" this.Request
            " target=" language " mode=" mode " hwnd=" window " target_pid=" pid
            " elevated=" (A_IsAdmin ? 1 : 0))
    }

    static Mark(stage) {
        if !RegExMatch(stage, "^(field-discovery|text-conversion|keyboard-switch)$")
            throw ValueError("Unknown conversion diagnostic stage.")
        this.Stage := stage
        WriteAppEvent("INFO", "conversion.stage", "request=" this.Request " stage=" stage)
    }

    static Finish(result) {
        result := result = "completed" ? "completed" : result = "focus-changed" ? "focus-changed" : "failed"
        this.Completed += result = "completed", this.Failed += result = "failed"
        WriteAppEvent(result = "failed" ? "WARN" : "INFO", "conversion.finished",
            "request=" this.Request " result=" result " stage=" this.Stage
            " elapsed_ms=" Max(0, GetDiagnosticUptimeMilliseconds() - this.StartedAt))
        this.StartedAt := 0, this.Stage := "idle"
    }

    static Snapshot(now := GetDiagnosticUptimeMilliseconds()) {
        return ("request=" this.Request " stage=" this.Stage
            " active_ms=" (this.Stage = "idle" ? 0 : Max(0, now - this.StartedAt))
            " completed=" this.Completed " failed=" this.Failed)
    }
}

OpenAppLogsLocation(launch := Run, report := ReportAppLogsLocationFailure) {
    ; The active writer owns the location; opening it never creates another log
    ; root or changes privileges. Included tests can supply their private logger.
    try {
        directory := AppEventLog.Current ? AppEventLog.Current.Directory : AppEventLog.DefaultDirectory()
        if !DirExist(directory)
            throw Error("The logs folder does not exist yet: " directory)
        launch('"' directory '"')
        return true
    } catch Error as failure {
        WriteAppError("logs.open-failed", failure)
        report(failure)
        return false
    }
}

ReportAppLogsLocationFailure(failure) {
    MsgBox("Could not open the logs folder.`n`n" failure.Message,
        "Ceratops Keyboard Layout", "Icon!")
}

InitializeAppEventLog(component) {
    try AppEventLog.Current := AppEventLog(component)
    catch Error as failure {
        ReportAppLogFailure(failure)
        if component = "tray"
            TrayTip("Operational logs could not be opened. Check Windows Application events.",
                "Ceratops Keyboard Layout")
    }
    OnError((failure, mode) => WriteAppError("unhandled-error", failure))
    OnExit((reason, code) => WriteAppEvent("INFO", "process.stopped", "reason=" reason " code=" code))
    WriteAppEvent("INFO", "process.started")
}

WriteAppEvent(level, event, fields := "") {
    if !AppEventLog.Current
        return 0 ; Included test scripts do not create application logs.
    try AppEventLog.Current.Write(level, event, fields)
    catch Error as failure
        ReportAppLogFailure(failure)
    return 0 ; Error/exit callbacks retain AutoHotkey's normal behavior.
}

WriteAppError(event, failure) {
    SplitPath(failure.File, &fileName)
    fields := "type=" Type(failure) " file=" fileName " line=" failure.Line
    if failure is OSError
        fields .= " code=" failure.Number
    return WriteAppEvent("ERROR", event, fields)
}

ReportAppLogFailure(failure) {
    ; An unwritable/full log must not disable conversion or recursively log itself.
    ; Windows Application events retain the failure even for the SYSTEM service.
    message := "Ceratops operational log unavailable: " Type(failure)
        . (failure is OSError ? " code=" failure.Number : "")
    OutputDebug(message)
    source := DllCall("advapi32\RegisterEventSourceW", "Ptr", 0, "Str", "CeratopsKeyboardLayout", "Ptr")
    if !source
        return
    strings := Buffer(A_PtrSize)
    NumPut("Ptr", StrPtr(message), strings)
    try DllCall("advapi32\ReportEventW", "Ptr", source, "UShort", 1, "UShort", 0,
        "UInt", 0, "Ptr", 0, "UShort", 1, "UInt", 0, "Ptr", strings, "Ptr", 0)
    finally DllCall("advapi32\DeregisterEventSource", "Ptr", source)
}
