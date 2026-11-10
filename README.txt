工作日 18:20 提醒，18:30 休眠；另附一键休眠（Windows PowerShell 5.1）
===================================================

已于 2026-10-28 在本机启用两个工作日计划任务，并创建桌面“立即休眠”快捷方式。
Check、Preview、Export 均不注册任务或执行休眠。

规则
----
1. 自动任务按 Windows 本地时间每周一至周五执行；日本公众假期仍会执行。
2. 18:20 电脑必须开机且处于唤醒状态，当前用户已登录。锁屏不算注销。
3. 提醒任务在 18:20 开始；给任务调度最多 60 秒启动余量。
   脚本另查最后开机/唤醒时间：18:20 后才开机或唤醒，当天仍会跳过。
4. 倒计时始终以当天 18:30 为截止，不因任务启动稍慢而顺延。
5. 窗口置顶，不显示最小化/关闭按钮；Alt+F4 不会关闭正式窗口。
   重新声明置顶时不抢键盘焦点。预览窗口可随时关闭。
6. 独立的 18:30 任务只接受当天、同一用户、同次启动的有效标记。
   窗口进程出错或被终止，不会取消已经排定的休眠。
7. 使用 shutdown.exe /h 进入真正休眠。它会把内存状态写入磁盘。
   不使用 /f，不强制结束应用程序。
8. 两个任务均不补跑、不唤醒，不要求交流供电、空闲或联网。
   正式倒计时期间临时阻止空闲自动睡眠/灭屏；窗口退出时释放此请求。
   18:30 没在运行则不补跑。强制睡眠后到 18:31 以后才恢复，窗口关闭。
9. 18:20 后重启、异常校时、标记损坏或过期，脚本保守跳过并写日志。
10. 正常任务不会重复休眠；当天标记在发出休眠命令前即作废。
11. 窗口提供“取消 / 推迟休眠”按钮：
    - 点击后可选择“取消今天”（今天不再提醒与自动休眠，清理临时延后任务）。
    - 或选择“推迟到3小时后”（自动注册延后任务，于 3 小时后的前 10 分钟再次倒计时提醒并休眠）。
    - 或选择“返回倒计时”继续当前 18:30 倒计时。
12. 桌面“立即休眠”快捷方式可在任意时间点击，立即休眠，不走倒计时。
    手动休眠后取消当天自动提醒；当天再次开机也不会再弹倒计时。
    若手动休眠命令失败，则恢复此前状态，不会关闭当天自动保护。

使用（在此目录打开 PowerShell）
--------------------------------
检查休眠及最后开机/唤醒时间（不会休眠）：
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\EveningHibernate.ps1 -Mode Check

15 秒窗口预览（不会休眠，不会生成当天标记）：
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\EveningHibernate.ps1 -Mode Preview

创建桌面“立即休眠”快捷方式（创建时不会休眠）：
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Create-Shortcut.ps1

手动立即休眠（本命令会真的休眠）：
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\EveningHibernate.ps1 -Mode Manual

安装并启用两个工作日任务（这一步才开始自动生效）：
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage-Tasks.ps1 -Action Install

查看任务状态：
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage-Tasks.ps1 -Action Status

停止并移除两个任务，取消当天待执行休眠：
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage-Tasks.ps1 -Action Remove

只导出两个可审阅的任务 XML，不安装：
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage-Tasks.ps1 -Action Export

限制
----
Windows 锁屏、安全桌面（UAC）、其他虚拟桌面或某些独占全屏场景下，普通桌面
窗口不能保证显示在最前面。已登录但锁屏时，休眠任务仍可执行。
本版本要求当前用户已登录；开机停在登录界面或已经注销时，当天任务不执行。
工作电脑若通过组策略禁止注册计划任务或休眠，需由管理员放行；脚本不修改策略。
其他任务/设备的唤醒权限不受此脚本控制，因此不承诺休眠后永不被其他来源唤醒。
18:30 是发出休眠请求的时间，写入内存及硬件进入休眠还需要一点时间。

文件
----
EveningHibernate.ps1  倒计时、当天标记检查、休眠命令、安全预览与本机检查
Manage-Tasks.ps1      安装、状态、移除、导出；默认只查看状态
Create-Shortcut.ps1   创建桌面“立即休眠”快捷方式
today.json           正式 18:20 任务运行后生成的当天标记
activity.log         跳过原因、任务启动、休眠命令及错误日志

Microsoft 官方参考
------------------
https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/shutdown
https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-startwhenavailable
https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-waketorun
https://learn.microsoft.com/en-us/windows/win32/taskschd/principal-logontype
https://learn.microsoft.com/en-us/windows/win32/api/powerbase/nf-powerbase-callntpowerinformation
