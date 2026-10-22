"""Transparent, always-on-top, click-through PySide6 instructional overlay with guide cursor."""
import math
import time

from PySide6.QtCore import QPointF, QRectF, Qt, QTimer
from PySide6.QtGui import (
    QBrush, QColor, QCursor, QFont, QFontMetrics, QGuiApplication, QPainter,
    QPainterPath, QPen,
)
from PySide6.QtWidgets import QWidget


class GuidanceOverlay(QWidget):
    """Transparent click-through overlay showing a distinct Laptop Bridge guide cursor,
    an animated target ring, and an optional instructional text bubble."""

    STATE_IDLE = 0
    STATE_MOVING = 1
    STATE_PAUSE = 2
    STATE_TRAILING = 3

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.WindowTransparentForInput
            | Qt.WindowType.Tool
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating, True)

        self.is_active = False
        self.state = self.STATE_IDLE

        self.target_pt = QPointF(0, 0)
        self.start_pt = QPointF(0, 0)
        self.current_cursor_pt = QPointF(0, 0)

        self.label = "Laptop Bridge"
        self.message = ""
        self.target_display_id = 0

        self.anim_start_time = 0.0
        self.anim_duration = 0.6  # 600ms smooth movement
        self.pause_start_time = 0.0
        self.pulse_phase = 0.0

        # Animation timer (approx 60 FPS)
        self.anim_timer = QTimer(self)
        self.anim_timer.setInterval(16)
        self.anim_timer.timeout.connect(self._on_tick)

        # Timeout timer for auto-dismiss
        self.timeout_timer = QTimer(self)
        self.timeout_timer.setSingleShot(True)
        self.timeout_timer.timeout.connect(self.clear_guidance)

    def is_guidance_active(self) -> bool:
        return self.is_active

    def show_guidance(
        self,
        display_id: int = 0,
        x: float = 200,
        y: float = 200,
        label: str = "Laptop Bridge",
        message: str = "",
        timeout_seconds: int | None = 15,
    ):
        """Display visual guidance on the specified display."""
        screens = QGuiApplication.screens()
        if not screens:
            return

        if 0 <= display_id < len(screens):
            screen = screens[display_id]
            self.target_display_id = display_id
        else:
            screen = QGuiApplication.primaryScreen() or screens[0]
            self.target_display_id = 0

        geo = screen.geometry()
        self.setGeometry(geo)

        # Map coordinates to overlay local coordinates
        if geo.x() <= x <= geo.x() + geo.width() and geo.y() <= y <= geo.y() + geo.height():
            local_x = x - geo.x()
            local_y = y - geo.y()
        else:
            local_x = max(20.0, min(float(x), float(geo.width() - 20)))
            local_y = max(20.0, min(float(y), float(geo.height() - 20)))

        self.target_pt = QPointF(local_x, local_y)

        # Start position is the user's current cursor mapped to overlay coords
        cur = QCursor.pos()
        self.start_pt = QPointF(cur.x() - geo.x(), cur.y() - geo.y())
        self.current_cursor_pt = QPointF(self.start_pt)

        self.label = label or "Laptop Bridge"
        self.message = message or ""
        self.is_active = True
        self.state = self.STATE_MOVING
        self.anim_start_time = time.monotonic()
        self.pulse_phase = 0.0

        self.timeout_timer.stop()
        if timeout_seconds and timeout_seconds > 0:
            self.timeout_timer.start(int(timeout_seconds * 1000))

        if not self.anim_timer.isActive():
            self.anim_timer.start()

        self.show()
        self._setup_macos_window()
        self.raise_()
        self.update()

    def _setup_macos_window(self):
        """Configure macOS native NSWindow to remain visible across all spaces and apps."""
        try:
            import ctypes
            import ctypes.util

            objc_path = ctypes.util.find_library("objc")
            if not objc_path:
                return
            objc = ctypes.cdll.LoadLibrary(objc_path)

            sel_fn = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_char_p)(("sel_registerName", objc))
            msg_send = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(("objc_msgSend", objc))
            msg_send_bool = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_bool)(("objc_msgSend", objc))
            msg_send_long = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long)(("objc_msgSend", objc))

            win_id = int(self.winId())
            nswindow = msg_send(win_id, sel_fn(b"window"))
            if nswindow:
                # Keep overlay visible even when companion loses focus to other apps
                msg_send_bool(nswindow, sel_fn(b"setHidesOnDeactivate:"), False)
                # Level 25 = kCGStatusWindowLevel (floats above all regular windows)
                msg_send_long(nswindow, sel_fn(b"setLevel:"), 25)
                # Native OS click-through
                msg_send_bool(nswindow, sel_fn(b"setIgnoresMouseEvents:"), True)
                # Appear on all macOS Spaces without entering window cycle
                msg_send_long(nswindow, sel_fn(b"setCollectionBehavior:"), 1 | 16 | 64)
                # Force window to the front above active applications without taking focus
                msg_send(nswindow, sel_fn(b"orderFrontRegardless"))
        except Exception:
            pass

    def clear_guidance(self):
        """Immediately hide and clear the guidance overlay."""
        self.is_active = False
        self.state = self.STATE_IDLE
        self.anim_timer.stop()
        self.timeout_timer.stop()
        self.hide()
        self.update()

    def _on_tick(self):
        if not self.is_active:
            self.anim_timer.stop()
            return

        now = time.monotonic()
        self.pulse_phase += 0.08

        geo = self.geometry()
        cur_global = QCursor.pos()
        cur_local = QPointF(cur_global.x() - geo.x(), cur_global.y() - geo.y())

        if self.state == self.STATE_MOVING:
            elapsed = now - self.anim_start_time
            progress = min(1.0, elapsed / self.anim_duration)
            # Smooth ease-out cubic
            ease = 1.0 - math.pow(1.0 - progress, 3)
            self.current_cursor_pt = QPointF(
                self.start_pt.x() + (self.target_pt.x() - self.start_pt.x()) * ease,
                self.start_pt.y() + (self.target_pt.y() - self.start_pt.y()) * ease,
            )
            if progress >= 1.0:
                self.state = self.STATE_PAUSE
                self.pause_start_time = now

        elif self.state == self.STATE_PAUSE:
            self.current_cursor_pt = QPointF(self.target_pt)
            if now - self.pause_start_time >= 0.4:
                self.state = self.STATE_TRAILING

        elif self.state == self.STATE_TRAILING:
            # Trailing mode: follow user's real cursor with smooth lag and offset
            trailing_target = cur_local + QPointF(24, 24)
            dx = trailing_target.x() - self.current_cursor_pt.x()
            dy = trailing_target.y() - self.current_cursor_pt.y()
            self.current_cursor_pt = QPointF(
                self.current_cursor_pt.x() + dx * 0.18,
                self.current_cursor_pt.y() + dy * 0.18,
            )

        self.update()

    def paintEvent(self, event):
        if not self.is_active:
            return

        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        # 1. Draw Target Ring & Pulse
        self._draw_target_ring(painter)

        # 2. Draw Instructional Bubble (if message or label present)
        self._draw_bubble(painter)

        # 3. Draw Distinct "Laptop Bridge" Guide Cursor
        self._draw_guide_cursor(painter)

    def _draw_target_ring(self, painter: QPainter):
        pulse = math.sin(self.pulse_phase)
        ring_radius = 22.0 + 6.0 * pulse

        # Outer glowing ring
        outer_pen = QPen(QColor(6, 182, 212, int(180 + 70 * pulse)), 2.5)
        painter.setPen(outer_pen)
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawEllipse(self.target_pt, ring_radius, ring_radius)

        # Inner ring
        inner_pen = QPen(QColor(56, 189, 248, 220), 1.5)
        painter.setPen(inner_pen)
        painter.drawEllipse(self.target_pt, 8.0, 8.0)

        # Center dot
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QBrush(QColor(6, 182, 212, 255)))
        painter.drawEllipse(self.target_pt, 3.5, 3.5)

        # Target crosshair ticks
        tick_pen = QPen(QColor(56, 189, 248, 200), 1.5)
        painter.setPen(tick_pen)
        painter.drawLine(
            QPointF(self.target_pt.x() - ring_radius - 6, self.target_pt.y()),
            QPointF(self.target_pt.x() - ring_radius + 2, self.target_pt.y()),
        )
        painter.drawLine(
            QPointF(self.target_pt.x() + ring_radius - 2, self.target_pt.y()),
            QPointF(self.target_pt.x() + ring_radius + 6, self.target_pt.y()),
        )
        painter.drawLine(
            QPointF(self.target_pt.x(), self.target_pt.y() - ring_radius - 6),
            QPointF(self.target_pt.x(), self.target_pt.y() - ring_radius + 2),
        )
        painter.drawLine(
            QPointF(self.target_pt.x(), self.target_pt.y() + ring_radius - 2),
            QPointF(self.target_pt.x(), self.target_pt.y() + ring_radius + 6),
        )

    def _draw_bubble(self, painter: QPainter):
        if not self.label and not self.message:
            return

        title_font = QFont("Helvetica Neue", 11, QFont.Weight.Bold)
        body_font = QFont("Helvetica Neue", 10)

        metrics_title = QFontMetrics(title_font)
        metrics_body = QFontMetrics(body_font)

        title_width = metrics_title.horizontalAdvance(self.label)
        body_width = metrics_body.horizontalAdvance(self.message) if self.message else 0
        content_width = max(title_width, body_width, 140)

        padding_x = 14
        padding_y = 10
        bubble_w = content_width + padding_x * 2
        bubble_h = padding_y * 2 + metrics_title.height() + (metrics_body.height() + 4 if self.message else 0)

        # Position bubble next to the target ring
        bx = self.target_pt.x() + 32
        by = self.target_pt.y() - bubble_h / 2

        # Clamp inside window geometry
        if bx + bubble_w > self.width() - 10:
            bx = self.target_pt.x() - bubble_w - 32
        if by < 10:
            by = 10
        if by + bubble_h > self.height() - 10:
            by = self.height() - bubble_h - 10

        bubble_rect = QRectF(bx, by, bubble_w, bubble_h)

        # Draw dark glass card background
        painter.setPen(QPen(QColor(56, 189, 248, 200), 1.5))
        painter.setBrush(QBrush(QColor(15, 23, 42, 235)))
        painter.drawRoundedRect(bubble_rect, 10.0, 10.0)

        # Title text
        painter.setFont(title_font)
        painter.setPen(QColor(56, 189, 248, 255))
        painter.drawText(
            QRectF(bx + padding_x, by + padding_y, content_width, metrics_title.height()),
            Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
            self.label,
        )

        # Message body text
        if self.message:
            painter.setFont(body_font)
            painter.setPen(QColor(241, 245, 249, 255))
            painter.drawText(
                QRectF(
                    bx + padding_x,
                    by + padding_y + metrics_title.height() + 4,
                    content_width,
                    metrics_body.height(),
                ),
                Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
                self.message,
            )

    def _draw_guide_cursor(self, painter: QPainter):
        cx = self.current_cursor_pt.x()
        cy = self.current_cursor_pt.y()

        # Build distinct arrow path
        path = QPainterPath()
        path.moveTo(cx, cy)
        path.lineTo(cx, cy + 22)
        path.lineTo(cx + 6, cy + 17)
        path.lineTo(cx + 12, cy + 26)
        path.lineTo(cx + 16, cy + 24)
        path.lineTo(cx + 10, cy + 15)
        path.lineTo(cx + 17, cy + 15)
        path.closeSubpath()

        # Outer halo glow
        painter.setPen(QPen(QColor(6, 182, 212, 120), 4))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawPath(path)

        # Main cursor body (electric cyan / deep dark outline)
        painter.setPen(QPen(QColor(15, 23, 42, 240), 2))
        painter.setBrush(QBrush(QColor(6, 182, 212, 255)))
        painter.drawPath(path)

        # Small "Laptop Bridge" badge attached to guide cursor
        badge_font = QFont("Helvetica Neue", 8, QFont.Weight.Bold)
        painter.setFont(badge_font)
        badge_text = "Laptop Bridge"
        metrics = QFontMetrics(badge_font)
        badge_w = metrics.horizontalAdvance(badge_text) + 10
        badge_h = 16
        badge_x = cx + 18
        badge_y = cy + 12

        badge_rect = QRectF(badge_x, badge_y, badge_w, badge_h)
        painter.setPen(QPen(QColor(56, 189, 248, 180), 1))
        painter.setBrush(QBrush(QColor(15, 23, 42, 220)))
        painter.drawRoundedRect(badge_rect, 4.0, 4.0)

        painter.setPen(QColor(56, 189, 248, 255))
        painter.drawText(
            badge_rect,
            Qt.AlignmentFlag.AlignCenter,
            badge_text,
        )
