# HibernatePanel (休眠控制中心)

适用于 Windows 11 的极简 Fluent UI 亚克力休眠控制面板与工作日自动休眠系统。

![Windows 11 Fluent](https://img.shields.io/badge/Style-Windows%2011%20Fluent%20Acrylic-0078D4)
![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011-blue)
![Python](https://img.shields.io/badge/Python-3.10%2B%20%7C%20PyQt6-brightgreen)

---

## 核心特性

- **Windows 11 Fluent 亚克力质感**：原生调用 DWM 亚克力（Acrylic）毛玻璃磨砂效果，透光自然。
- **纯粹字阶排版**：第一行唯一 H3 大字醒目状态，其余所有文字均为系统级精致小字。
- **三级休眠计划调度**：
  - **暂停今日休眠**：仅今天跳过 18:20 提醒与 18:30 休眠，次日自动恢复。
  - **暂停本周休眠**：跳过至本周日 23:59，下周一工作日自动恢复。
  - **永久停用计划**：一键停用底层所有自动任务。
- **10 分钟防误触离机倒计时**：
  - 双击打开窗口自动开始 10 分钟倒计时，无人操作自动休眠；
  - 随时点击「暂停倒计时」或切换任意开关，倒计时立即暂停；
  - 关闭窗口即销毁倒计时，绝不后台偷跑。
- **倒计时中途即时干预**：
  - 即使 18:20 屏幕已弹出倒计时窗口，在控制中心开启暂停后，原倒计时窗口将在 1 秒内自动退出，今晚安全跳过休眠。
- **秒级启动**：无白屏、无等待，直接调动系统本地配置。

---

## 一键安装与迁移（新电脑部署）

在新电脑上克隆或解压本仓库后，**双击运行 `Setup.bat`** 即可：
1. 自动校验系统休眠支持；
2. 自动注册 Windows 工作日计划任务（18:20 倒计时，18:30 休眠）；
3. 自动在桌面生成「休眠控制中心」快捷方式；
4. 自动拉起控制中心。

```bash
# 克隆仓库
git clone https://github.com/KissesJun/HibernatePanel.git
cd HibernatePanel

# 运行一键配置
./Setup.bat
```

---

## 项目结构

```text
HibernatePanel/
├── hibernate_menu.py    # Windows 11 Fluent 亚克力控制中心主程序 (PyQt6)
├── EveningHibernate.ps1 # 任务计划程序后台执行引擎 (18:20/18:30 调度检查)
├── Manage-Tasks.ps1     # 底层计划任务安装、移除与导出脚本
├── Create-Shortcut.ps1  # 桌面快捷方式生成脚本
├── Setup.bat            # 新设备一键安装配置批处理
├── Run-Menu.bat         # 桌面控制中心静默启动器
├── config.json          # 全局配置 (本周暂停截止时间 / 永久停用开关)
├── today.json           # 单日状态标记 (cancelled / armed / manual)
├── Countdown.xml        # 18:20 倒计时任务定义
├── Hibernate.xml        # 18:30 休眠任务定义
└── README.md            # 项目说明文档
```

---

## 运行环境要求

- Windows 10 (1809+) 或 Windows 11 (推荐，支持完整亚克力效果)
- Python 3.10+ 并安装 `PyQt6`：
  ```bash
  pip install PyQt6
  ```
- 启用系统休眠支持（可在管理员终端运行 `powercfg /h on`）
