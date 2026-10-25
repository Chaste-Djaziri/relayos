"""On-demand display capture for the visible desktop companion."""
import ctypes
import ctypes.util
import os
import time

from PySide6.QtCore import QBuffer, QIODevice, QPoint
from PySide6.QtGui import QCursor, QGuiApplication


def _is_windows() -> bool:
    return os.name == "nt"


def has_screen_recording_permission() -> bool:
    """Check platform capture availability without starting a capture."""
    if _is_windows():
        # Desktop Win32 applications do not have a per-app screen-recording
        # consent dialog. Actual access is still verified by grabWindow below.
        return True
    try:
        cg_path = ctypes.util.find_library("CoreGraphics")
        if not cg_path:
            return False
        cg = ctypes.cdll.LoadLibrary(cg_path)
        if hasattr(cg, "CGPreflightScreenCaptureAccess"):
            return bool(cg.CGPreflightScreenCaptureAccess())
    except Exception:
        pass
    return False


def request_screen_recording_permission() -> bool:
    """Prompt macOS for Screen Recording permission if not yet determined."""
    if _is_windows():
        return has_screen_recording_permission()
    try:
        cg_path = ctypes.util.find_library("CoreGraphics")
        if not cg_path:
            return False
        cg = ctypes.cdll.LoadLibrary(cg_path)
        if hasattr(cg, "CGRequestScreenCaptureAccess"):
            return bool(cg.CGRequestScreenCaptureAccess())
    except Exception:
        pass
    return False


def has_accessibility_permission() -> bool:
    """Check whether macOS Accessibility access is available to the app."""
    if _is_windows():
        # Low-level mouse observation is started only during an active,
        # explicitly requested guidance session and does not need elevation.
        return True
    if __import__("sys").platform != "darwin":
        return True
    try:
        app_services = ctypes.util.find_library("ApplicationServices")
        if not app_services:
            return False
        services = ctypes.cdll.LoadLibrary(app_services)
        services.AXIsProcessTrusted.restype = ctypes.c_bool
        return bool(services.AXIsProcessTrusted())
    except Exception:
        return False


def open_permission_settings(kind="screen"):
    """Open the relevant operating-system privacy/settings page."""
    if _is_windows():
        try:
            os.startfile("ms-settings:privacy")  # type: ignore[attr-defined]
        except OSError:
            return False
        return True
    import subprocess
    url = (
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if kind == "screen"
        else "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    try:
        subprocess.Popen(["/usr/bin/open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return False
    return True


def get_frontmost_app_pid() -> int | None:
    """Query AppKit for the PID of the frontmost application."""
    try:
        appkit_path = ctypes.util.find_library("AppKit")
        objc_path = ctypes.util.find_library("objc")
        if not appkit_path or not objc_path:
            return None
        ctypes.cdll.LoadLibrary(appkit_path)
        objc = ctypes.cdll.LoadLibrary(objc_path)

        objc.objc_getClass.restype = ctypes.c_void_p
        objc.objc_getClass.argtypes = [ctypes.c_char_p]
        objc.sel_registerName.restype = ctypes.c_void_p
        objc.sel_registerName.argtypes = [ctypes.c_char_p]
        objc.objc_msgSend.restype = ctypes.c_void_p
        objc.objc_msgSend.argtypes = [ctypes.c_void_p, ctypes.c_void_p]

        ns_workspace = objc.objc_getClass(b"NSWorkspace")
        shared_workspace = objc.sel_registerName(b"sharedWorkspace")
        frontmost_app = objc.sel_registerName(b"frontmostApplication")
        process_identifier = objc.sel_registerName(b"processIdentifier")

        ws = objc.objc_msgSend(ns_workspace, shared_workspace)
        if not ws:
            return None
        app = objc.objc_msgSend(ws, frontmost_app)
        if not app:
            return None
        pid = ctypes.cast(objc.objc_msgSend(app, process_identifier), ctypes.c_void_p).value
        return pid
    except Exception:
        return None


def _windows_foreground_center() -> QPoint | None:
    """Return the center of the foreground Win32 window, when available."""
    if not _is_windows() or not hasattr(ctypes, "windll"):
        return None
    try:
        from ctypes import wintypes

        class RECT(ctypes.Structure):
            _fields_ = [("left", wintypes.LONG), ("top", wintypes.LONG), ("right", wintypes.LONG), ("bottom", wintypes.LONG)]

        hwnd = ctypes.windll.user32.GetForegroundWindow()
        rect = RECT()
        if not hwnd or not ctypes.windll.user32.GetWindowRect(hwnd, ctypes.byref(rect)):
            return None
        if rect.right <= rect.left or rect.bottom <= rect.top:
            return None
        return QPoint((rect.left + rect.right) // 2, (rect.top + rect.bottom) // 2)
    except Exception:
        return None


def get_active_display():
    """Find the display containing the focused app, falling back to the pointer's display."""
    screens = QGuiApplication.screens()
    if not screens:
        return None

    # Fallback screen: the display containing the pointer
    cursor_pos = QCursor.pos()
    pointer_screen = QGuiApplication.screenAt(cursor_pos) or QGuiApplication.primaryScreen() or screens[0]

    if _is_windows():
        center = _windows_foreground_center()
        return QGuiApplication.screenAt(center) if center is not None else pointer_screen

    # Attempt to locate the focused app window display on macOS.
    pid = get_frontmost_app_pid()
    if pid is not None:
        try:
            cg_path = ctypes.util.find_library("CoreGraphics")
            cf_path = ctypes.util.find_library("CoreFoundation")
            if cg_path and cf_path:
                cg = ctypes.cdll.LoadLibrary(cg_path)
                cf = ctypes.cdll.LoadLibrary(cf_path)

                cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
                cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
                cf.CFArrayGetCount.restype = ctypes.c_long
                cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
                cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
                cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
                cf.CFStringCreateWithCString.restype = ctypes.c_void_p
                cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
                cf.CFDictionaryGetValue.restype = ctypes.c_void_p
                cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
                cf.CFNumberGetValue.restype = ctypes.c_bool
                cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
                cf.CFRelease.restype = None
                cf.CFRelease.argtypes = [ctypes.c_void_p]

                # 1 = kCGWindowListOptionOnScreenOnly
                window_list = cg.CGWindowListCopyWindowInfo(1, 0)
                if window_list:
                    try:
                        count = cf.CFArrayGetCount(window_list)
                        k_pid = cf.CFStringCreateWithCString(None, b"kCGWindowOwnerPID", 0x08000100)
                        k_bounds = cf.CFStringCreateWithCString(None, b"kCGWindowBounds", 0x08000100)
                        k_x = cf.CFStringCreateWithCString(None, b"X", 0x08000100)
                        k_y = cf.CFStringCreateWithCString(None, b"Y", 0x08000100)
                        k_w = cf.CFStringCreateWithCString(None, b"Width", 0x08000100)
                        k_h = cf.CFStringCreateWithCString(None, b"Height", 0x08000100)

                        for i in range(count):
                            win_dict = cf.CFArrayGetValueAtIndex(window_list, i)
                            pid_ref = cf.CFDictionaryGetValue(win_dict, k_pid)
                            if not pid_ref:
                                continue
                            win_pid = ctypes.c_int()
                            cf.CFNumberGetValue(pid_ref, 9, ctypes.byref(win_pid))
                            if win_pid.value == pid:
                                bounds_ref = cf.CFDictionaryGetValue(win_dict, k_bounds)
                                if bounds_ref:
                                    bx, by, bw, bh = ctypes.c_double(), ctypes.c_double(), ctypes.c_double(), ctypes.c_double()
                                    cf.CFNumberGetValue(cf.CFDictionaryGetValue(bounds_ref, k_x), 12, ctypes.byref(bx))
                                    cf.CFNumberGetValue(cf.CFDictionaryGetValue(bounds_ref, k_y), 12, ctypes.byref(by))
                                    cf.CFNumberGetValue(cf.CFDictionaryGetValue(bounds_ref, k_w), 12, ctypes.byref(bw))
                                    cf.CFNumberGetValue(cf.CFDictionaryGetValue(bounds_ref, k_h), 12, ctypes.byref(bh))
                                    if bw.value > 10 and bh.value > 10:
                                        center_point = QPoint(int(bx.value + bw.value / 2), int(by.value + bh.value / 2))
                                        screen = QGuiApplication.screenAt(center_point)
                                        if screen:
                                            return screen
                        for key_ref in (k_pid, k_bounds, k_x, k_y, k_w, k_h):
                            if key_ref:
                                cf.CFRelease(key_ref)
                    finally:
                        cf.CFRelease(window_list)
        except Exception:
            pass

    return pointer_screen


def capture_snapshot(display_id: int | None = None) -> tuple[dict, bytes]:
    """Capture a single display snapshot on explicit MCP request.
    
    Returns (metadata, png_bytes). Does not persist bytes to disk.
    """
    if not has_screen_recording_permission():
        raise PermissionError(
            "Screen Recording permission is required. Please grant Screen Recording "
            "permission to Laptop Bridge in macOS System Settings > Privacy & Security > Screen Recording."
        )

    screens = QGuiApplication.screens()
    if not screens:
        raise RuntimeError("No displays detected")

    if display_id is not None and 0 <= display_id < len(screens):
        target_screen = screens[display_id]
    else:
        target_screen = get_active_display() or screens[0]

    pixmap = target_screen.grabWindow(0)
    if pixmap.isNull():
        raise RuntimeError("Failed to capture display image")

    buffer = QBuffer()
    buffer.open(QIODevice.OpenModeFlag.WriteOnly)
    if not pixmap.save(buffer, "PNG"):
        raise RuntimeError("Failed to encode capture as PNG")
    png_bytes = bytes(buffer.data())

    geo = target_screen.geometry()
    actual_id = screens.index(target_screen) if target_screen in screens else 0
    metadata = {
        "display_id": actual_id,
        "bounds": {
            "x": geo.x(),
            "y": geo.y(),
            "width": geo.width(),
            "height": geo.height(),
        },
        "scale": float(target_screen.devicePixelRatio()),
        "capture_time": time.time(),
    }
    return metadata, png_bytes
