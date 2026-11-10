#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$shell = New-Object -ComObject WScript.Shell
$desktopPath = [Environment]::GetFolderPath('DesktopDirectory')
$shortcutPath = Join-Path $desktopPath '休眠控制中心.lnk'
$shortcut = $shell.CreateShortcut($shortcutPath)
$pythonw = "C:\Users\Junmo\AppData\Local\Python\pythoncore-3.14-64\pythonw.exe"
if (-not (Test-Path $pythonw)) {
    $pythonw = (Get-Command pythonw -ErrorAction SilentlyContinue).Source
}
$shortcut.TargetPath = $pythonw
$shortcut.Arguments = '"{0}"' -f (Join-Path $PSScriptRoot 'hibernate_menu.py')
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.WindowStyle = 1
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,27"
$shortcut.Description = '休眠控制中心：Fluent UI 风格，支持 10 分钟自动倒计时与计划调整。'
$shortcut.Save()
Write-Output $shortcutPath
