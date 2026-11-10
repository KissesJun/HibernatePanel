@echo off
chcp 65001 >nul
title 休眠控制中心 - 一键安装与初始化
echo ========================================================
echo   正在为当前电脑配置自动休眠计划任务与桌面控制中心...
echo ========================================================

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0Manage-Tasks.ps1' -Action Install; & '%~dp0Create-Shortcut.ps1'"

if %errorlevel% equ 0 (
    echo.
    echo [成功] 工作日计划任务已注册 (18:20 提醒 / 18:30 休眠)
    echo [成功] 桌面快捷方式「休眠控制中心」已生成
    echo.
    echo 正在启动休眠控制中心...
    start "" "%~dp0Run-Menu.bat"
) else (
    echo.
    echo [失败] 安装遇到问题，请检查是否具备权限或休眠功能是否开启。
    pause
)
