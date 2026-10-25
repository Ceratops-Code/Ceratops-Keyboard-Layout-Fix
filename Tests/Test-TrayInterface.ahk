#Requires AutoHotkey v2.0.19+
; Shared native tray, settings and hover checks. Test-ShortcutKeys.ahk owns
; launch modes, isolated test roots, child observers and cleanup.

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
    DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
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

VisibleTrayOverflow() {
    hwnd := WinExist("ahk_class TopLevelWindowForOverflowXamlIsland")
    if !hwnd || !DllCall("IsWindowVisible", "Ptr", hwnd)
        return 0
    cloaked := 0
    if DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14,
        "UInt*", &cloaked, "UInt", 4, "Int")
        throw Error("Windows could not report the tray overflow's visibility")
    return cloaked ? 0 : hwnd
}

WaitForTrayOverflow(visible) {
    deadline := A_TickCount + 2000
    while !!VisibleTrayOverflow() != visible {
        if A_TickCount >= deadline
            throw Error("The tray overflow did not reach its requested visible state")
        Sleep(25)
    }
}

RequireTrayHoverSurface(x, y) {
    cover := DllCall("WindowFromPoint", "Int64", (x & 0xFFFFFFFF) | (y << 32), "Ptr")
    surface := DllCall("GetAncestor", "Ptr", cover, "UInt", 2, "Ptr")
    overflow := VisibleTrayOverflow()
    if overflow && surface = overflow
        return
    throw Error("The candidate tray icon is not physically visible in overflow: point=" x "," y
        " surface=" surface " class=" (surface ? WinGetClass("ahk_id " surface) : "none"))
}

ReadVisibleTrayHoverPoint(identifier, &x, &y) {
    ; While XAML is opening, GetRect still returns the taskbar chevron's anchor.
    ; Wait for this isolated, unpinned icon's actual overflow rectangle before
    ; moving the pointer; hovering the chevron cannot prove icon behavior.
    deadline := A_TickCount + 3000
    lastX := -1, lastY := -1, stableSince := A_TickCount
    loop {
        rectangle := Buffer(16, 0)
        if DllCall("Shell32\Shell_NotifyIconGetRect", "Ptr", identifier, "Ptr", rectangle, "Int")
            throw Error("Windows did not expose the candidate tray icon rectangle")
        x := (NumGet(rectangle, 0, "Int") + NumGet(rectangle, 8, "Int")) // 2
        y := (NumGet(rectangle, 4, "Int") + NumGet(rectangle, 12, "Int")) // 2
        cover := DllCall("WindowFromPoint", "Int64", (x & 0xFFFFFFFF) | (y << 32), "Ptr")
        overflow := VisibleTrayOverflow()
        if overflow && DllCall("GetAncestor", "Ptr", cover, "UInt", 2, "Ptr") = overflow {
            if x != lastX || y != lastY
                lastX := x, lastY := y, stableSince := A_TickCount
            else if A_TickCount - stableSince >= 500
                return
        } else
            stableSince := A_TickCount
        if A_TickCount >= deadline
            throw Error("The candidate tray rectangle did not settle: point=" x "," y
                " surface=" DllCall("GetAncestor", "Ptr", cover, "UInt", 2, "Ptr")
                " class=" WinGetClass("ahk_id " DllCall("GetAncestor", "Ptr", cover, "UInt", 2, "Ptr"))
                " overflow=" overflow " stable_ms=" (A_TickCount - stableSince))
        Sleep(25)
    }
}

CheckPhysicalTrayHover(root, legacyProtocol := false) {
    DetectHiddenWindows(false)
    DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
    if FileExist(root "\_tray-hover.png")
        FileDelete(root "\_tray-hover.png")
    tray := RequireUnlockedTrayDesktop()
    CoordMode("Mouse", "Screen")
    MouseGetPos(&originalX, &originalY)
    originalFocus := WinExist("A")
    opened := false, chevron := 0
    try {
        InitializeAppTray(GetServiceAppDirectory() "\CeratopsKeyboardLayout.ico")
        if legacyProtocol {
            ; Every new shell registration starts with version 0. Hover must be
            ; empty even before recovery selects version 4, without a NIF_TIP.
            data := AppTrayNotificationData()
            if !DllCall("Shell32\Shell_NotifyIconW", "UInt", 4, "Ptr", data, "Int")
                throw Error("Windows rejected the legacy hover fixture")
        }
        ; This fixture creates only its own tray icon, without global shortcuts,
        ; shared settings, update workers or changes to the installed service.
        hoverManager := KeyboardShortcutManager(Converter, KeyboardShortcutSettings(root "\_hover-shortcuts.ini"))
        hoverManager.RebuildTray()
        if !VisibleTrayOverflow() {
            trayElement := UIA.ElementFromHandle(tray)
            try chevron := trayElement.FindElement({Name: "Show Hidden Icons", AutomationId: "SystemTrayIcon"})
            catch Error as failure
                throw Error("Tray overflow control unavailable: " failure.Message "`n" trayElement.DumpAll(" ", 6))
            ; A physical click gives the native popup focus. InvokePattern can
            ; open it while another app remains foreground and later dismisses it.
            chevron.Click("left")
            opened := true
            WaitForTrayOverflow(true)
        }
        identifier := Buffer(A_PtrSize = 8 ? 40 : 28, 0)
        NumPut("UInt", identifier.Size, identifier)
        NumPut("Ptr", A_ScriptHwnd, identifier, A_PtrSize = 8 ? 8 : 4)
        NumPut("UInt", 0x404, identifier, A_PtrSize = 8 ? 16 : 8)
        ReadVisibleTrayHoverPoint(identifier, &x, &y)
        RequireUnlockedTrayDesktop()
        RequireTrayHoverSurface(x, y)
        if !DllCall("SetCursorPos", "Int", x, "Int", y)
            throw OSError()
        Sleep(2600)
        DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
        RequireUnlockedTrayDesktop()
        RequireTrayHoverSurface(x, y)
        currentRectangle := Buffer(16, 0), cursor := Buffer(8, 0)
        if DllCall("Shell32\Shell_NotifyIconGetRect", "Ptr", identifier, "Ptr", currentRectangle, "Int")
            || !DllCall("GetCursorPos", "Ptr", cursor)
            || x != (NumGet(currentRectangle, 0, "Int") + NumGet(currentRectangle, 8, "Int")) // 2
            || y != (NumGet(currentRectangle, 4, "Int") + NumGet(currentRectangle, 12, "Int")) // 2
            || x != NumGet(cursor, 0, "Int") || y != NumGet(cursor, 4, "Int")
            throw Error("The icon or pointer moved during the physical hover: expected=" x "," y
                " rectangle=" ((NumGet(currentRectangle, 0, "Int") + NumGet(currentRectangle, 8, "Int")) // 2)
                "," ((NumGet(currentRectangle, 4, "Int") + NumGet(currentRectangle, 12, "Int")) // 2)
                " cursor=" NumGet(cursor, 0, "Int") "," NumGet(cursor, 4, "Int"))
        CaptureTrayHover(root "\_tray-hover.png", x, y)
        tooltipWindows := WinGetList("ahk_class tooltips_class32")
        tooltipWindows.Push(WinGetList("ahk_class Xaml_WindowedPopupClass")*)
        for tooltip in tooltipWindows {
            if !DllCall("IsWindowVisible", "Ptr", tooltip)
                continue
            ; Windows retains an empty XAML host after its tooltip disappears.
            if WinGetClass("ahk_id " tooltip) = "Xaml_WindowedPopupClass"
                && !UIA.ElementFromHandle(tooltip).ElementExist({Type: "ToolTip", IsOffscreen: false})
                continue
            WinGetPos(&tx, &ty, &tw, &th, "ahk_id " tooltip)
            if Abs(tx - x) < 180 && Abs(ty - y) < 180
                throw Error("Hover popup class=" WinGetClass("ahk_id " tooltip) "`n" UIA.ElementFromHandle(tooltip).DumpAll(" ", 4))
        }
    } finally {
        SetAppTrayIconHidden(true)
        try {
            RequireUnlockedTrayDesktop()
            if opened && VisibleTrayOverflow() {
                chevron.Click("left")
                WaitForTrayOverflow(false)
            }
            MouseMove(originalX, originalY, 0)
            if originalFocus && WinExist("ahk_id " originalFocus)
                WinActivate("ahk_id " originalFocus)
        }
    }
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
    ; A missing initial icon must be registered without AutoHotkey's tooltip.
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
            setIcon := InterruptInterfaceEffect.Bind(LoadAppTrayArtwork, "icon", selectedEffect, boundary)
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
    logsText := Buffer(128, 0)
    if !DllCall("GetMenuStringW", "Ptr", A_TrayMenu.Handle, "UInt", count - 6,
        "Ptr", logsText, "Int", 64, "UInt", 0x400, "Int")
        || StrGet(logsText, "UTF-16") != "Open logs location"
        || DllCall("GetMenuState", "Ptr", A_TrayMenu.Handle, "UInt", count - 6, "UInt", 0x400, "UInt") & 3
        throw Error("The tray menu has no enabled Open logs location item")
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
