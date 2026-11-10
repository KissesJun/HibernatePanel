# -*- coding: utf-8 -*-
import sys
import os
import json
import datetime
import subprocess
import ctypes
from ctypes import c_int, c_uint, byref, Structure, sizeof

from PyQt6.QtCore import (Qt, QTimer, QPoint, QRectF, pyqtSignal, 
                          QPropertyAnimation, QEasingCurve, pyqtProperty)
from PyQt6.QtGui import (QColor, QFont, QPainter, QPen, QBrush, 
                         QMouseEvent)
from PyQt6.QtWidgets import (QApplication, QWidget, QVBoxLayout, QHBoxLayout, 
                             QLabel, QPushButton, QFrame)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, "config.json")
TODAY_PATH = os.path.join(SCRIPT_DIR, "today.json")


def get_owner_sid():
    # 优先秒读本地已有标记（0.1毫秒，消除所有启动卡顿）
    if os.path.exists(TODAY_PATH):
        try:
            with open(TODAY_PATH, "r", encoding="utf-8") as f:
                sid = json.load(f).get("OwnerSid")
                if sid:
                    return sid
        except Exception:
            pass
    # 备用轻量秒级获取，绝不拉起耗时的 powershell.exe
    try:
        out = subprocess.check_output(["whoami", "/user"], creationflags=subprocess.CREATE_NO_WINDOW)
        lines = out.decode("gbk", errors="ignore").strip().splitlines()
        if lines:
            parts = lines[-1].split()
            if len(parts) >= 2:
                return parts[-1]
    except Exception:
        pass
    return ""


OWNER_SID = get_owner_sid()


def load_config():
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {"Version": 1, "PermanentDisabled": False, "PauseUntil": None}


def save_config(cfg):
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    os.replace(tmp, CONFIG_PATH)


def load_today():
    if os.path.exists(TODAY_PATH):
        try:
            with open(TODAY_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return None


def save_today(status):
    today_str = datetime.date.today().strftime("%Y-%m-%d")
    data = {
        "Version": 1,
        "Date": today_str,
        "OwnerSid": OWNER_SID,
        "Status": status
    }
    tmp = TODAY_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, TODAY_PATH)


def get_this_sunday_end():
    today = datetime.date.today()
    days_until_sunday = (6 - today.weekday()) % 7
    sunday = today + datetime.timedelta(days=days_until_sunday)
    return datetime.datetime.combine(sunday, datetime.time(23, 59, 59))


def ensure_tasks_installed():
    """新电脑开箱即用自检：若未注册计划任务，自动静默补全注册"""
    try:
        res = subprocess.run(["schtasks", "/Query", "/TN", "Junmo-EveningHibernate-Hibernate"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             creationflags=subprocess.CREATE_NO_WINDOW)
        if res.returncode != 0:
            manage_script = os.path.join(SCRIPT_DIR, "Manage-Tasks.ps1")
            subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", manage_script, "-Action", "Install"],
                           creationflags=subprocess.CREATE_NO_WINDOW)
    except Exception:
        pass


# ================== Windows 11 原生白色亚克力毛玻璃注入 ==================

class MARGINS(Structure):
    _fields_ = [("cxLeftWidth", c_int), ("cxRightWidth", c_int),
                ("cyTopHeight", c_int), ("cyBottomHeight", c_int)]

class ACCENT_POLICY(Structure):
    _fields_ = [
        ("AccentState", c_int),
        ("AccentFlags", c_int),
        ("GradientColor", c_uint),
        ("AnimationId", c_int)
    ]

class WINDOWCOMPOSITIONATTRIBDATA(Structure):
    _fields_ = [
        ("Attribute", c_int),
        ("Data", ctypes.c_void_p),
        ("SizeOfData", ctypes.c_size_t)
    ]


def apply_light_acrylic(hwnd):
    dwmapi = ctypes.windll.dwmapi
    user32 = ctypes.windll.user32

    # 1. 明确浅色主题
    light_mode = c_int(0)
    dwmapi.DwmSetWindowAttribute(hwnd, 20, byref(light_mode), 4)

    # 2. 原生系统圆角
    corner = c_int(2)
    dwmapi.DwmSetWindowAttribute(hwnd, 33, byref(corner), 4)

    # 3. 边框扩展到客户区，使 DWM 透视生效
    margins = MARGINS(-1, -1, -1, -1)
    dwmapi.DwmExtendFrameIntoClientArea(hwnd, byref(margins))

    # 4. 开启 Windows 11 原生白色亚克力模糊
    try:
        accent = ACCENT_POLICY()
        accent.AccentState = 4       # ACCENT_ENABLE_ACRYLICBLURBEHIND
        accent.AccentFlags = 2       # Draw borders
        accent.GradientColor = 0x99F6F6F6
        accent.AnimationId = 0

        data = WINDOWCOMPOSITIONATTRIBDATA()
        data.Attribute = 19
        data.Data = ctypes.cast(byref(accent), ctypes.c_void_p)
        data.SizeOfData = sizeof(accent)

        user32.SetWindowCompositionAttribute(hwnd, byref(data))
    except Exception:
        pass


# ================== Windows 11 浅色 Toggle Switch ==================

class Win11LightToggleSwitch(QWidget):
    toggled = pyqtSignal(bool)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedSize(40, 20)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self._checked = False
        self._offset = 4.0
        self._is_hovered = False

        self._anim = QPropertyAnimation(self, b"offset", self)
        self._anim.setDuration(130)
        self._anim.setEasingCurve(QEasingCurve.Type.OutCubic)

    @pyqtProperty(float)
    def offset(self):
        return self._offset

    @offset.setter
    def offset(self, val):
        self._offset = val
        self.update()

    def isChecked(self):
        return self._checked

    def setChecked(self, checked, animate=True):
        if self._checked != checked:
            self._checked = checked
            target = 24.0 if checked else 4.0
            if animate:
                self._anim.stop()
                self._anim.setStartValue(self._offset)
                self._anim.setEndValue(target)
                self._anim.start()
            else:
                self._offset = target
                self.update()
            self.toggled.emit(self._checked)

    def enterEvent(self, e):
        self._is_hovered = True
        self.update()

    def leaveEvent(self, e):
        self._is_hovered = False
        self.update()

    def mousePressEvent(self, e):
        if e.button() == Qt.MouseButton.LeftButton and self.isEnabled():
            self.setChecked(not self._checked)

    def paintEvent(self, e):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)

        rect = QRectF(0.5, 0.5, 39.0, 19.0)
        radius = 9.5

        if not self.isEnabled():
            bg_color = QColor(245, 245, 245, 140)
            border_color = QColor(210, 210, 210)
            thumb_color = QColor(180, 180, 180)
        elif self._checked:
            accent = QColor(0, 103, 192) if not self._is_hovered else QColor(15, 116, 200)
            bg_color = accent
            border_color = accent
            thumb_color = QColor(255, 255, 255)
        else:
            bg_color = QColor(255, 255, 255, 180) if not self._is_hovered else QColor(243, 243, 243, 220)
            border_color = QColor(135, 135, 135) if not self._is_hovered else QColor(90, 90, 90)
            thumb_color = QColor(90, 90, 90) if not self._is_hovered else QColor(30, 30, 30)

        p.setPen(QPen(border_color, 1.0))
        p.setBrush(QBrush(bg_color))
        p.drawRoundedRect(rect, radius, radius)

        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QBrush(thumb_color))
        p.drawEllipse(QRectF(self._offset, 4.0, 12.0, 12.0))


# ================== 主窗口 ==================

class HibernateMenuWindow(QWidget):
    def __init__(self):
        super().__init__()
        self._drag_pos = None
        self.remaining_seconds = 600
        self.is_countdown_paused = False
        self.is_updating_ui = False

        self.cfg = load_config()
        self.today_state = load_today()

        ensure_tasks_installed()
        self.init_ui()
        self.sync_state_to_ui()
        self.init_timer()

    def init_ui(self):
        self.setWindowFlags(Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.resize(380, 395)

        root_layout = QVBoxLayout(self)
        root_layout.setContentsMargins(0, 0, 0, 0)
        root_layout.setSpacing(0)

        self.shell = QFrame(self)
        self.shell.setObjectName("AcrylicShell")
        self.shell.setStyleSheet("""
            #AcrylicShell {
                background-color: rgba(246, 246, 246, 0.78);
                border: 1px solid rgba(0, 0, 0, 0.09);
                border-radius: 10px;
            }
            QLabel {
                color: #1a1a1a;
                font-family: "Segoe UI Variable Text", "Segoe UI", "Microsoft YaHei UI";
            }
            QPushButton#PrimaryBtn {
                background-color: #0067c0;
                color: #ffffff;
                border: 1px solid rgba(0, 0, 0, 0.12);
                border-radius: 4px;
                font-family: "Segoe UI Variable Text", "Segoe UI", "Microsoft YaHei UI";
                font-size: 12px;
                font-weight: 600;
                padding: 6px 16px;
            }
            QPushButton#PrimaryBtn:hover {
                background-color: #1975c5;
            }
            QPushButton#PrimaryBtn:pressed {
                background-color: #005fb8;
                color: rgba(255, 255, 255, 0.85);
            }
            QPushButton#SecondaryBtn {
                background-color: rgba(255, 255, 255, 0.75);
                color: #242424;
                border: 1px solid rgba(0, 0, 0, 0.12);
                border-radius: 4px;
                font-family: "Segoe UI Variable Text", "Segoe UI", "Microsoft YaHei UI";
                font-size: 12px;
                padding: 6px 16px;
            }
            QPushButton#SecondaryBtn:hover {
                background-color: rgba(255, 255, 255, 0.95);
                border-color: rgba(0, 0, 0, 0.20);
            }
            QPushButton#SecondaryBtn:pressed {
                background-color: rgba(240, 240, 240, 0.90);
            }
            QPushButton#TitleBtn {
                background: transparent;
                border: none;
                color: #555555;
                border-radius: 4px;
                font-size: 12px;
                font-family: "Segoe UI Variable Text", "Segoe UI", "Microsoft YaHei UI";
                min-width: 32px;
                min-height: 26px;
            }
            QPushButton#TitleBtn:hover {
                background-color: rgba(0, 0, 0, 0.06);
                color: #111111;
            }
            QPushButton#CloseBtn:hover {
                background-color: #c42b1c;
                color: #ffffff;
            }
        """)

        # 紧凑内边距：顶部收紧为 10px，左右 20px，底部 14px
        shell_layout = QVBoxLayout(self.shell)
        shell_layout.setContentsMargins(20, 10, 20, 14)
        shell_layout.setSpacing(0)

        # 1. 顶部标题栏（纯文本、黑色、13.5px Semibold、无 Emoji）
        title_bar = QHBoxLayout()
        title_bar.setContentsMargins(0, 0, 0, 0)
        
        lbl_app = QLabel("休眠控制中心")
        lbl_app.setStyleSheet("font-size: 13.5px; color: #111111; font-weight: 600;")
        title_bar.addWidget(lbl_app)
        title_bar.addStretch()

        btn_min = QPushButton("—")
        btn_min.setObjectName("TitleBtn")
        btn_min.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_min.clicked.connect(self.showMinimized)
        title_bar.addWidget(btn_min)

        btn_close = QPushButton("✕")
        btn_close.setObjectName("CloseBtn")
        btn_close.setStyleSheet("QPushButton#CloseBtn { background: transparent; border: none; color: #555555; border-radius: 4px; font-size: 11px; min-width: 32px; min-height: 26px; } QPushButton#CloseBtn:hover { background-color: #c42b1c; color: white; }")
        btn_close.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_close.clicked.connect(self.close)
        title_bar.addWidget(btn_close)

        shell_layout.addLayout(title_bar)

        # 间距收紧（与标题间隙 8px）
        shell_layout.addSpacing(8)

        # ================== 上面两行 ==================

        # 上面第一行：H3 唯一大字状态
        top_status_layout = QVBoxLayout()
        top_status_layout.setContentsMargins(0, 0, 0, 0)
        top_status_layout.setSpacing(2)

        self.lbl_schedule_h3 = QLabel("计划休眠：今天 18:30")
        self.lbl_schedule_h3.setStyleSheet("font-family: 'Segoe UI Variable Display', 'Segoe UI', 'Microsoft YaHei UI'; font-size: 20px; font-weight: bold; color: #0d8a43;")
        top_status_layout.addWidget(self.lbl_schedule_h3)

        self.lbl_schedule_sub = QLabel("● 工作日定时保护正常生效中")
        self.lbl_schedule_sub.setStyleSheet("font-size: 11px; color: #666666;")
        top_status_layout.addWidget(self.lbl_schedule_sub)

        shell_layout.addLayout(top_status_layout)

        shell_layout.addSpacing(10)

        # 上面第二行：手动休眠与倒计时控制（无 Emoji）
        manual_layout = QVBoxLayout()
        manual_layout.setContentsMargins(0, 0, 0, 0)
        manual_layout.setSpacing(7)

        self.lbl_manual = QLabel("若无操作，电脑将在 10:00 后自动进入休眠")
        self.lbl_manual.setStyleSheet("font-size: 12px; color: #424242;")
        manual_layout.addWidget(self.lbl_manual)

        btn_layout = QHBoxLayout()
        btn_layout.setSpacing(10)

        self.btn_hibernate_now = QPushButton("立即休眠")
        self.btn_hibernate_now.setObjectName("PrimaryBtn")
        self.btn_hibernate_now.setCursor(Qt.CursorShape.PointingHandCursor)
        self.btn_hibernate_now.clicked.connect(self.action_hibernate_now)
        btn_layout.addWidget(self.btn_hibernate_now)

        self.btn_pause_countdown = QPushButton("暂停倒计时")
        self.btn_pause_countdown.setObjectName("SecondaryBtn")
        self.btn_pause_countdown.setCursor(Qt.CursorShape.PointingHandCursor)
        self.btn_pause_countdown.clicked.connect(self.toggle_countdown_pause)
        btn_layout.addWidget(self.btn_pause_countdown)

        manual_layout.addLayout(btn_layout)
        shell_layout.addLayout(manual_layout)

        shell_layout.addSpacing(12)

        # ================== 唯一且极其微弱的段落灰色分割线 ==================
        divider = QFrame()
        divider.setFixedHeight(1)
        divider.setStyleSheet("background-color: rgba(0, 0, 0, 0.08); border: none;")
        shell_layout.addWidget(divider)

        shell_layout.addSpacing(10)

        # ================== 下面三行（纯平无一圈外框线） ==================
        sw_layout = QVBoxLayout()
        sw_layout.setContentsMargins(0, 0, 0, 0)
        sw_layout.setSpacing(7)

        # Row 1: 今日
        self.sw_today = Win11LightToggleSwitch()
        self.sw_today.toggled.connect(self.on_today_toggled)
        self.lbl_today_title = QLabel("暂停今日休眠")
        self.lbl_today_title.setStyleSheet("font-size: 12px; font-weight: 600; color: #1a1a1a;")
        self.lbl_today_desc = QLabel("仅今天跳过 18:20 与 18:30，明天自动恢复")
        self.lbl_today_desc.setStyleSheet("font-size: 11px; color: #6b7280;")
        sw_layout.addLayout(self.create_flat_row(self.lbl_today_title, self.lbl_today_desc, self.sw_today))

        # Row 2: 本周
        self.sw_week = Win11LightToggleSwitch()
        self.sw_week.toggled.connect(self.on_week_toggled)
        self.lbl_week_title = QLabel("暂停本周休眠")
        self.lbl_week_title.setStyleSheet("font-size: 12px; font-weight: 600; color: #1a1a1a;")
        self.lbl_week_desc = QLabel("跳过至本周日 23:59，下周一自动恢复")
        self.lbl_week_desc.setStyleSheet("font-size: 11px; color: #6b7280;")
        sw_layout.addLayout(self.create_flat_row(self.lbl_week_title, self.lbl_week_desc, self.sw_week))

        # Row 3: 永久
        self.sw_perm = Win11LightToggleSwitch()
        self.sw_perm.toggled.connect(self.on_perm_toggled)
        self.lbl_perm_title = QLabel("永久停用计划")
        self.lbl_perm_title.setStyleSheet("font-size: 12px; font-weight: 600; color: #1a1a1a;")
        self.lbl_perm_desc = QLabel("停用所有工作日自动休眠计划任务")
        self.lbl_perm_desc.setStyleSheet("font-size: 11px; color: #6b7280;")
        sw_layout.addLayout(self.create_flat_row(self.lbl_perm_title, self.lbl_perm_desc, self.sw_perm))

        shell_layout.addLayout(sw_layout)

        shell_layout.addSpacing(12)

        # 5. 底部超淡微提示（无 Emoji、超淡小字）
        lbl_hint = QLabel("点击任意开关或按钮将自动暂停 10 分钟倒计时")
        lbl_hint.setStyleSheet("font-size: 10.5px; color: rgba(0, 0, 0, 0.38);")
        lbl_hint.setAlignment(Qt.AlignmentFlag.AlignCenter)
        shell_layout.addWidget(lbl_hint)

        root_layout.addWidget(self.shell)

    def create_flat_row(self, title_lbl, desc_lbl, switch_widget):
        row = QHBoxLayout()
        row.setContentsMargins(0, 2, 0, 2)
        text_col = QVBoxLayout()
        text_col.setSpacing(1)
        text_col.addWidget(title_lbl)
        text_col.addWidget(desc_lbl)
        row.addLayout(text_col)
        row.addStretch()
        row.addWidget(switch_widget)
        return row

    def mousePressEvent(self, event: QMouseEvent):
        if event.button() == Qt.MouseButton.LeftButton and event.position().y() < 45:
            self._drag_pos = event.globalPosition().toPoint() - self.frameGeometry().topLeft()
            event.accept()

    def mouseMoveEvent(self, event: QMouseEvent):
        if event.buttons() == Qt.MouseButton.LeftButton and self._drag_pos is not None:
            self.move(event.globalPosition().toPoint() - self._drag_pos)
            event.accept()

    def mouseReleaseEvent(self, event: QMouseEvent):
        self._drag_pos = None

    def init_timer(self):
        self.timer = QTimer(self)
        self.timer.setInterval(1000)
        self.timer.timeout.connect(self.on_timer_tick)
        self.timer.start()

    def on_timer_tick(self):
        if self.is_countdown_paused:
            return
        self.remaining_seconds -= 1
        if self.remaining_seconds <= 0:
            self.timer.stop()
            self.lbl_manual.setText("倒计时结束，正在休眠...")
            self.execute_hibernate()
        else:
            m = self.remaining_seconds // 60
            s = self.remaining_seconds % 60
            self.lbl_manual.setText(f"若无操作，电脑将在 {m:02d}:{s:02d} 后自动进入休眠")

    def pause_countdown(self, reason):
        if not self.is_countdown_paused:
            self.is_countdown_paused = True
            self.timer.stop()
            self.lbl_manual.setText(f"自动倒计时已暂停（{reason}）")
            self.lbl_manual.setStyleSheet("font-size: 12px; color: #d97706; font-weight: 500;")
            self.btn_pause_countdown.setText("继续倒计时")

    def resume_countdown(self):
        self.is_countdown_paused = False
        self.timer.start()
        self.lbl_manual.setStyleSheet("font-size: 12px; color: #424242;")
        self.btn_pause_countdown.setText("暂停倒计时")

    def toggle_countdown_pause(self):
        if self.is_countdown_paused:
            self.resume_countdown()
        else:
            self.pause_countdown("用户手动暂停")

    def action_hibernate_now(self):
        self.pause_countdown("触发立即休眠")
        save_today("manual")
        self.execute_hibernate()

    def execute_hibernate(self):
        try:
            subprocess.Popen(["shutdown.exe", "/h"])
        except Exception:
            pass
        self.close()

    def on_today_toggled(self, checked):
        if self.is_updating_ui:
            return
        self.pause_countdown("已调整今日计划")
        save_today("cancelled" if checked else "normal")
        self.today_state = load_today()
        self.update_schedule_header()

    def on_week_toggled(self, checked):
        if self.is_updating_ui:
            return
        self.pause_countdown("已调整本周计划")
        if checked:
            sun_end = get_this_sunday_end()
            self.cfg["PauseUntil"] = sun_end.strftime("%Y-%m-%dT%H:%M:%S")
        else:
            self.cfg["PauseUntil"] = None
        save_config(self.cfg)
        self.update_schedule_header()

    def on_perm_toggled(self, checked):
        if self.is_updating_ui:
            return
        self.pause_countdown("已调整永久停用状态")
        self.cfg["PermanentDisabled"] = checked
        save_config(self.cfg)

        action = "/Disable" if checked else "/Enable"
        try:
            subprocess.Popen(["schtasks", "/Change", "/TN", "Junmo-EveningHibernate-Countdown", action],
                             creationflags=subprocess.CREATE_NO_WINDOW)
            subprocess.Popen(["schtasks", "/Change", "/TN", "Junmo-EveningHibernate-Hibernate", action],
                             creationflags=subprocess.CREATE_NO_WINDOW)
        except Exception:
            pass

        self.sync_state_to_ui()

    def sync_state_to_ui(self):
        self.is_updating_ui = True
        try:
            perm_disabled = bool(self.cfg.get("PermanentDisabled", False))
            self.sw_perm.setChecked(perm_disabled, animate=False)

            week_paused = False
            pause_until = self.cfg.get("PauseUntil")
            if pause_until:
                try:
                    dt = datetime.datetime.fromisoformat(pause_until)
                    if datetime.datetime.now() <= dt:
                        week_paused = True
                except Exception:
                    pass
            self.sw_week.setChecked(week_paused, animate=False)

            today_str = datetime.date.today().strftime("%Y-%m-%d")
            today_paused = False
            if self.today_state and self.today_state.get("Date") == today_str:
                if self.today_state.get("Status") == "cancelled":
                    today_paused = True
            self.sw_today.setChecked(today_paused, animate=False)

            self.sw_today.setEnabled(not perm_disabled)
            self.sw_week.setEnabled(not perm_disabled)
            title_color = "#9e9e9e" if perm_disabled else "#1a1a1a"
            self.lbl_today_title.setStyleSheet(f"font-size: 12px; font-weight: 600; color: {title_color};")
            self.lbl_week_title.setStyleSheet(f"font-size: 12px; font-weight: 600; color: {title_color};")
        finally:
            self.is_updating_ui = False

        self.update_schedule_header()

    def update_schedule_header(self):
        # 1. 永久停用
        if self.sw_perm.isChecked():
            self.lbl_schedule_h3.setText("计划休眠：已永久停用")
            self.lbl_schedule_h3.setStyleSheet("font-family: 'Segoe UI Variable Display', 'Segoe UI', 'Microsoft YaHei UI'; font-size: 20px; font-weight: bold; color: #dc2626;")
            self.lbl_schedule_sub.setText("● 工作日定时任务已停用，不会自动休眠")
            return

        # 2. 本周暂停
        if self.sw_week.isChecked():
            now = datetime.datetime.now()
            days_until_sunday = (6 - now.weekday()) % 7
            next_monday = (now + datetime.timedelta(days=days_until_sunday + 1)).strftime("%m月%d日 (周一)")
            self.lbl_schedule_h3.setText(f"计划休眠：{next_monday} 18:30")
            self.lbl_schedule_h3.setStyleSheet("font-family: 'Segoe UI Variable Display', 'Segoe UI', 'Microsoft YaHei UI'; font-size: 20px; font-weight: bold; color: #d97706;")
            self.lbl_schedule_sub.setText("● 本周已暂停跳过，下周一自动恢复")
            return

        # 3. 今日暂停
        if self.sw_today.isChecked():
            now = datetime.datetime.now()
            next_day = now + datetime.timedelta(days=1)
            while next_day.weekday() in (5, 6):
                next_day += datetime.timedelta(days=1)
            day_text = "明天" if next_day.date() == (now + datetime.timedelta(days=1)).date() else next_day.strftime("%m月%d日")
            self.lbl_schedule_h3.setText(f"计划休眠：{day_text} 18:30 (今天已跳过)")
            self.lbl_schedule_h3.setStyleSheet("font-family: 'Segoe UI Variable Display', 'Segoe UI', 'Microsoft YaHei UI'; font-size: 20px; font-weight: bold; color: #d97706;")
            self.lbl_schedule_sub.setText("● 今天 18:20 与 18:30 已跳过，明天恢复正常")
            return

        # 4. 正常生效
        self.lbl_schedule_h3.setText("计划休眠：今天 18:30")
        self.lbl_schedule_h3.setStyleSheet("font-family: 'Segoe UI Variable Display', 'Segoe UI', 'Microsoft YaHei UI'; font-size: 20px; font-weight: bold; color: #0d8a43;")
        self.lbl_schedule_sub.setText("● 工作日定时保护正常生效中")


if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = HibernateMenuWindow()
    # 内存中构建完毕后再瞬间显示并挂载亚克力，告别白屏闪烁
    window.show()
    apply_light_acrylic(int(window.winId()))
    sys.exit(app.exec())
