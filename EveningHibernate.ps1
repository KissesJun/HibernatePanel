#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Countdown', 'Hibernate', 'Manual', 'Preview', 'Check', 'Library', 'PostponedCountdown', 'PostponedHibernate')]
    [string]$Mode = 'Preview',
    [ValidateRange(3, 600)]
    [int]$PreviewSeconds = 15,
    [string]$TargetDeadline = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:StatePath = Join-Path $PSScriptRoot 'today.json'
$script:LogPath = Join-Path $PSScriptRoot 'activity.log'
$script:OwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

if (-not ('EveningHibernate.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace EveningHibernate {
    public static class Native {
        [DllImport("kernel32.dll")]
        public static extern ulong GetTickCount64();
        [DllImport("kernel32.dll")]
        public static extern uint SetThreadExecutionState(uint flags);
        public static ulong GetUptimeTicks() { return GetTickCount64() * 10000; }
        [DllImport("powrprof.dll")]
        public static extern uint CallNtPowerInformation(int level, IntPtr input,
            uint inputLength, out ulong output, uint outputLength);
        [DllImport("powrprof.dll")]
        [return: MarshalAs(UnmanagedType.U1)]
        public static extern bool IsPwrHibernateAllowed();
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter,
            int x, int y, int cx, int cy, uint flags);
    }
}
'@
}

function Write-Activity([string]$Message) {
    Add-Content -LiteralPath $script:LogPath -Encoding UTF8 -Value (
        '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Mode, $Message
    )
}

function Get-PowerClock {
    [UInt64]$interrupt = [EveningHibernate.Native]::GetUptimeTicks()
    [UInt64]$wake = 0
    $utc = [DateTime]::UtcNow
    $status = [EveningHibernate.Native]::CallNtPowerInformation(
        14, [IntPtr]::Zero, 0, [ref]$wake, 8
    )
    if ($status -ne 0 -or $wake -gt $interrupt) {
        throw "Cannot verify last boot/wake time (status $status)."
    }
    [pscustomobject]@{
        Utc = $utc
        InterruptTicks = [long]$interrupt
        LastAwakeUtc = $utc.AddTicks(-[long]($interrupt - $wake))
    }
}

function Test-StartWindow([DateTime]$Now, [DateTime]$LastAwake) {
    if ($Now.DayOfWeek -in @('Saturday', 'Sunday')) { return $false }
    $start = $Now.Date.AddHours(18).AddMinutes(20)
    # Allow ordinary scheduler latency; a boot/resume AFTER 18:20 still fails.
    return ($Now -ge $start -and $Now -lt $start.AddMinutes(1) -and
        $LastAwake -le $start)
}

function Test-HibernateWindow(
    [DateTime]$Now, [DateTime]$LastAwake, $State, $Clock
) {
    if ($null -eq $State) { return $false }
    if ($Now.DayOfWeek -in @('Saturday', 'Sunday')) { return $false }
    try {
        $deadline = $Now.Date.AddHours(18).AddMinutes(30)
        $armedUtc = [DateTime]::Parse(
            [string]$State.ArmedUtc, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        $uptimeElapsed = [long]$Clock.InterruptTicks - [long]$State.InterruptTicks
        $wallElapsed = ($Clock.Utc - $armedUtc).Ticks
        $armedLocal = $armedUtc.ToLocalTime()
        return (
            $State.Version -eq 1 -and $State.Status -eq 'armed' -and
            $State.OwnerSid -eq $script:OwnerSid -and
            $State.Date -eq $Now.ToString('yyyy-MM-dd') -and
            $armedLocal -ge $deadline.AddMinutes(-10) -and
            $armedLocal -lt $deadline.AddMinutes(-9) -and
            $Now -ge $deadline -and $Now -lt $deadline.AddMinutes(1) -and
            $LastAwake -le $deadline -and $uptimeElapsed -ge 0 -and
            [Math]::Abs($uptimeElapsed - $wallElapsed) -lt
                [TimeSpan]::FromSeconds(5).Ticks
        )
    } catch {
        return $false
    }
}

function Save-State($State) {
    # Write a complete file before replacing the previous day's state.
    $tempPath = "$script:StatePath.tmp"
    $State | ConvertTo-Json | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $script:StatePath -Force
}

function Invoke-HibernateRequest {
    if (-not [EveningHibernate.Native]::IsPwrHibernateAllowed()) {
        throw 'Windows hibernation is unavailable. Check powercfg /a.'
    }
    & "$env:SystemRoot\System32\shutdown.exe" /h
    if ($LASTEXITCODE -ne 0) { throw "shutdown.exe failed with exit code $LASTEXITCODE." }
}

function Remove-PostponedTasks {
    $taskNames = @(
        'Junmo-EveningHibernate-PostponedCountdown',
        'Junmo-EveningHibernate-PostponedHibernate'
    )
    foreach ($name in $taskNames) {
        $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($null -ne $t) {
            Stop-ScheduledTask -InputObject $t -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -InputObject $t -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

function Register-PostponedTasks([DateTime]$ReminderTime, [DateTime]$HibernateTime) {
    Remove-PostponedTasks
    $scriptFile = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $PSScriptRoot 'EveningHibernate.ps1' }
    $powershellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $principal = New-ScheduledTaskPrincipal -UserId $script:OwnerSid -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    # 1. Postponed countdown
    $actualRemindTime = if ($ReminderTime -le (Get-Date)) { (Get-Date).AddSeconds(10) } else { $ReminderTime }
    $remindArgs = '-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode PostponedCountdown -TargetDeadline "{1}"' -f $scriptFile, $HibernateTime.ToString('o')
    $remindAction = New-ScheduledTaskAction -Execute $powershellPath -Argument $remindArgs -WorkingDirectory $PSScriptRoot
    $remindTrigger = New-ScheduledTaskTrigger -Once -At $actualRemindTime
    Register-ScheduledTask -TaskName 'Junmo-EveningHibernate-PostponedCountdown' -Action $remindAction -Trigger $remindTrigger -Principal $principal -Settings $settings -Force | Out-Null

    # 2. Postponed hibernate
    $hibArgs = '-NoLogo -NoProfile -STA -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode PostponedHibernate -TargetDeadline "{1}"' -f $scriptFile, $HibernateTime.ToString('o')
    $hibAction = New-ScheduledTaskAction -Execute $powershellPath -Argument $hibArgs -WorkingDirectory $PSScriptRoot
    $hibTrigger = New-ScheduledTaskTrigger -Once -At $HibernateTime
    Register-ScheduledTask -TaskName 'Junmo-EveningHibernate-PostponedHibernate' -Action $hibAction -Trigger $hibTrigger -Principal $principal -Settings $settings -Force | Out-Null
}

function Show-CancelPromptDialog([System.Windows.Forms.Form]$ParentForm) {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '取消或推迟休眠'
    $dialog.ClientSize = New-Object System.Drawing.Size(430, 215)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.TopMost = $true
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(28, 36, 54)
    $dialog.ForeColor = [System.Drawing.Color]::White

    $msgLabel = New-Object System.Windows.Forms.Label
    $msgLabel.SetBounds(20, 22, 390, 52)
    $msgLabel.TextAlign = 'MiddleCenter'
    $msgLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $msgLabel.Text = "是否取消自动休眠？`r`n请选择取消今天，或推迟到 3 小时后："
    $dialog.Controls.Add($msgLabel)

    $btnCancelToday = New-Object System.Windows.Forms.Button
    $btnCancelToday.SetBounds(35, 92, 165, 46)
    $btnCancelToday.Text = '取消今天'
    $btnCancelToday.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $btnCancelToday.BackColor = [System.Drawing.Color]::FromArgb(190, 65, 65)
    $btnCancelToday.ForeColor = [System.Drawing.Color]::White
    $btnCancelToday.FlatStyle = 'Flat'
    $btnCancelToday.FlatAppearance.BorderSize = 0
    $btnCancelToday.Cursor = [System.Windows.Forms.Cursors]::Hand
    $dialog.Controls.Add($btnCancelToday)

    $btnPostpone = New-Object System.Windows.Forms.Button
    $btnPostpone.SetBounds(230, 92, 165, 46)
    $btnPostpone.Text = '推迟到3小时后'
    $btnPostpone.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $btnPostpone.BackColor = [System.Drawing.Color]::FromArgb(40, 120, 190)
    $btnPostpone.ForeColor = [System.Drawing.Color]::White
    $btnPostpone.FlatStyle = 'Flat'
    $btnPostpone.FlatAppearance.BorderSize = 0
    $btnPostpone.Cursor = [System.Windows.Forms.Cursors]::Hand
    $dialog.Controls.Add($btnPostpone)

    $btnBack = New-Object System.Windows.Forms.Button
    $btnBack.SetBounds(150, 158, 130, 34)
    $btnBack.Text = '返回倒计时'
    $btnBack.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $btnBack.BackColor = [System.Drawing.Color]::FromArgb(50, 60, 80)
    $btnBack.ForeColor = [System.Drawing.Color]::LightGray
    $btnBack.FlatStyle = 'Flat'
    $btnBack.FlatAppearance.BorderSize = 0
    $btnBack.Cursor = [System.Windows.Forms.Cursors]::Hand
    $dialog.Controls.Add($btnBack)

    $selection = @{ Value = 'Back' }
    $btnCancelToday.Add_Click({
        $selection.Value = 'CancelToday'
        $dialog.Close()
    })
    $btnPostpone.Add_Click({
        $selection.Value = 'Postpone3h'
        $dialog.Close()
    })
    $btnBack.Add_Click({
        $selection.Value = 'Back'
        $dialog.Close()
    })

    [void]$dialog.ShowDialog($ParentForm)
    $dialog.Dispose()
    return $selection.Value
}

function Show-Countdown([DateTime]$Deadline, [bool]$Preview) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object System.Windows.Forms.Form
    $deadlineText = $Deadline.ToString('HH:mm')
    $form.Text = if ($Preview) { '休眠提醒 · 预览（不会休眠）' } else { "$deadlineText 自动休眠提醒" }
    $form.ClientSize = New-Object System.Drawing.Size(510, 275)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $Preview
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(24, 32, 48)
    $form.ForeColor = [System.Drawing.Color]::White

    $heading = New-Object System.Windows.Forms.Label
    $heading.SetBounds(20, 18, 470, 36)
    $heading.TextAlign = 'MiddleCenter'
    $heading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15)
    $heading.Text = if ($Preview) { '这是安全预览，不会执行休眠' } else { "电脑将在今天 $deadlineText 自动休眠" }
    $form.Controls.Add($heading)

    $counter = New-Object System.Windows.Forms.Label
    $counter.SetBounds(20, 56, 470, 88)
    $counter.TextAlign = 'MiddleCenter'
    $counter.Font = New-Object System.Drawing.Font('Consolas', 50, [System.Drawing.FontStyle]::Bold)
    $counter.ForeColor = [System.Drawing.Color]::FromArgb(255, 199, 90)
    $form.Controls.Add($counter)

    $hint = New-Object System.Windows.Forms.Label
    $hint.SetBounds(25, 150, 460, 40)
    $hint.TextAlign = 'MiddleCenter'
    $hint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $hint.Text = "请保存工作。休眠后会保留当前桌面。`r`n如需继续使用，可点击下方取消或推迟。"
    $form.Controls.Add($hint)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.SetBounds(165, 204, 180, 42)
    $cancelButton.Text = '取消 / 推迟休眠'
    $cancelButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $cancelButton.BackColor = [System.Drawing.Color]::FromArgb(48, 62, 88)
    $cancelButton.ForeColor = [System.Drawing.Color]::FromArgb(235, 240, 250)
    $cancelButton.FlatStyle = 'Flat'
    $cancelButton.FlatAppearance.BorderSize = 1
    $cancelButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(75, 95, 130)
    $cancelButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($cancelButton)

    $uiState = @{
        AllowClose = $Preview
        End = $Deadline
        LastCheck = [DateTime]::MinValue
        InDialog = $false
    }

    $cancelButton.Add_Click({
        $uiState.InDialog = $true
        try {
            $choice = Show-CancelPromptDialog -ParentForm $form
            if ($choice -eq 'CancelToday') {
                $uiState.AllowClose = $true
                $timer.Stop()
                if (-not $Preview) {
                    Save-State ([pscustomobject]@{
                        Version = 1
                        Date = (Get-Date -Format 'yyyy-MM-dd')
                        OwnerSid = $script:OwnerSid
                        Status = 'cancelled'
                    })
                    Remove-PostponedTasks
                    Write-Activity 'Auto-hibernation cancelled today by user.'
                } else {
                    Write-Activity 'Preview: user selected CancelToday.'
                }
                $form.Close()
            } elseif ($choice -eq 'Postpone3h') {
                $uiState.AllowClose = $true
                $timer.Stop()
                if (-not $Preview) {
                    $newDeadline = $Deadline.AddHours(3)
                    $newReminder = $newDeadline.AddMinutes(-10)
                    Save-State ([pscustomobject]@{
                        Version = 1
                        Date = (Get-Date -Format 'yyyy-MM-dd')
                        OwnerSid = $script:OwnerSid
                        Status = 'postponed'
                        PostponedDeadline = $newDeadline.ToString('o')
                    })
                    Register-PostponedTasks -ReminderTime $newReminder -HibernateTime $newDeadline
                    Write-Activity ("Auto-hibernation postponed by 3 hours. New reminder: {0:yyyy-MM-dd HH:mm:ss}, new hibernate: {1:yyyy-MM-dd HH:mm:ss}." -f $newReminder, $newDeadline)
                } else {
                    Write-Activity ("Preview: user selected Postpone3h (to {0:HH:mm})." -f $Deadline.AddHours(3))
                }
                $form.Close()
            }
        } finally {
            $uiState.InDialog = $false
        }
    })

    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if (-not $uiState.AllowClose -and $eventArgs.CloseReason -eq 'UserClosing') {
            $eventArgs.Cancel = $true
        }
    })
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $refresh = {
        # Fixed clock deadline, not a count of timer callbacks.
        $currentTime = [DateTime]::Now
        if (-not $Preview -and ($currentTime - $uiState.LastCheck).TotalSeconds -ge 1) {
            $uiState.LastCheck = $currentTime
            try {
                $pending = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($pending.Status -in @('manual', 'cancelled', 'postponed')) {
                    $uiState.AllowClose = $true
                    $timer.Stop()
                    $form.Close()
                    return
                }
            } catch { # The independent hibernate task validates the state itself.
            }
        }
        $seconds = [Math]::Max(0, [Math]::Ceiling(($uiState.End - $currentTime).TotalSeconds))
        $counter.Text = '{0:00}:{1:00}' -f [int][Math]::Floor($seconds / 60), [int]($seconds % 60)
        if ($seconds -le 60) { $counter.ForeColor = [System.Drawing.Color]::Salmon }
        if ($seconds -le 0) {
            if ($Preview -or $currentTime -ge $uiState.End.AddMinutes(1)) {
                $uiState.AllowClose = $true
                $timer.Stop()
                $form.Close()
                return
            }
            $hint.Text = ("已到 {0}，正在等待系统进入休眠。" -f $uiState.End.ToString('HH:mm'))
        }
        if (-not $uiState.InDialog) {
            if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
            if (-not $form.Visible) { $form.Show() }
            # HWND_TOPMOST + SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE.
            # Reassert visibility without repeatedly taking keyboard focus.
            [void][EveningHibernate.Native]::SetWindowPos(
                $form.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0013
            )
        }
    }
    $form.Add_Shown($refresh)
    $timer.Add_Tick($refresh)
    try {
        if (-not $Preview) {
            # Keep this ten-minute reminder from turning into ordinary idle sleep.
            $powerRequest = [EveningHibernate.Native]::SetThreadExecutionState([UInt32]2147483651)
            if ($powerRequest -eq 0) { throw 'Unable to keep the countdown awake.' }
        }
        $timer.Start()
        [void]$form.ShowDialog()
    } finally {
        $timer.Stop()
        $timer.Dispose()
        $form.Dispose()
        if (-not $Preview) {
            [void][EveningHibernate.Native]::SetThreadExecutionState([UInt32]2147483648)
        }
    }
}

if ($Mode -eq 'Library') { return }
if ($Mode -eq 'Preview') {
    Show-Countdown -Deadline ([DateTime]::Now.AddSeconds($PreviewSeconds)) -Preview $true
    return
}
if ($Mode -eq 'Check') {
    $clock = Get-PowerClock
    [pscustomobject]@{
        HibernateAvailable = [EveningHibernate.Native]::IsPwrHibernateAllowed()
        LocalTime = $clock.Utc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        LastBootOrWake = $clock.LastAwakeUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        UserSid = $script:OwnerSid
        ScheduleRegistered = 'Not changed by this command'
    }
    return
}

if ($Mode -eq 'Manual') {
    # This is an explicit click, so no weekday/time/18:20 eligibility restriction.
    $previousState = $null
    try {
        if (Test-Path -LiteralPath $script:StatePath) {
            $previousState = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8
        }
        Save-State ([pscustomobject]@{
            Version = 1
            Date = (Get-Date -Format 'yyyy-MM-dd')
            OwnerSid = $script:OwnerSid
            Status = 'manual'
        })
        Write-Activity 'Manual hibernation requested; automatic reminder disabled for today.'
        Invoke-HibernateRequest
    } catch {
        # A rejected manual request must not disable tonight's protection.
        if ($null -ne $previousState) {
            Set-Content -LiteralPath $script:StatePath -Value $previousState -Encoding UTF8
        } else {
            Save-State ([pscustomobject]@{ Status = 'failed' })
        }
        Write-Activity "ERROR: $($_.Exception.Message)"
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            "休眠失败：$($_.Exception.Message)", '立即休眠', 'OK', 'Error'
        )
        throw
    }
    return
}

if ($Mode -eq 'PostponedCountdown') {
    $mutex = New-Object System.Threading.Mutex($false, "Local\EveningHibernate-PostponedCountdown-$script:OwnerSid")
    $ownsMutex = $false
    try {
        $ownsMutex = $mutex.WaitOne(0)
        if (-not $ownsMutex) { return }
        if (Test-Path -LiteralPath $script:StatePath) {
            try {
                $existingState = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($existingState.Date -eq (Get-Date -Format 'yyyy-MM-dd') -and
                    $existingState.OwnerSid -eq $script:OwnerSid -and
                    $existingState.Status -eq 'postponed') {
                    $deadline = if ($TargetDeadline) { [DateTime]::Parse($TargetDeadline) } else { (Get-Date).AddMinutes(10) }
                    $existingState.Status = 'armed-postponed'
                    $existingState.ArmedUtc = [DateTime]::UtcNow.ToString('o')
                    Save-State $existingState
                    Write-Activity ("Postponed countdown armed. Due at {0:yyyy-MM-dd HH:mm:ss}." -f $deadline)
                    Show-Countdown -Deadline $deadline -Preview $false
                    return
                }
            } catch {
            }
        }
        Write-Activity 'Postponed countdown skipped: invalid state or cancelled.'
        Remove-PostponedTasks
    } catch {
        Write-Activity "ERROR: $($_.Exception.Message)"
        throw
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    return
}

if ($Mode -eq 'PostponedHibernate') {
    $mutex = New-Object System.Threading.Mutex($false, "Local\EveningHibernate-PostponedHibernate-$script:OwnerSid")
    $ownsMutex = $false
    try {
        $ownsMutex = $mutex.WaitOne(0)
        if (-not $ownsMutex) { return }
        if (Test-Path -LiteralPath $script:StatePath) {
            try {
                $existingState = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($existingState.Date -eq (Get-Date -Format 'yyyy-MM-dd') -and
                    $existingState.OwnerSid -eq $script:OwnerSid -and
                    $existingState.Status -in @('postponed', 'armed-postponed')) {
                    $existingState.Status = 'consumed'
                    Save-State $existingState
                    Remove-PostponedTasks
                    Write-Activity 'Postponed hibernate deadline reached. Requesting shutdown.exe /h.'
                    Invoke-HibernateRequest
                    return
                }
            } catch {
            }
        }
        Write-Activity 'Postponed hibernate skipped: invalid state, cancelled, or already consumed.'
        Remove-PostponedTasks
    } catch {
        Write-Activity "ERROR: $($_.Exception.Message)"
        throw
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    return
}

$mutex = New-Object System.Threading.Mutex($false, "Local\EveningHibernate-$Mode-$script:OwnerSid")
$ownsMutex = $false
try {
    $ownsMutex = $mutex.WaitOne(0)
    if (-not $ownsMutex) { return }

    $cfgPath = Join-Path $PSScriptRoot 'config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.PermanentDisabled -eq $true) {
                Write-Activity 'Skipped: automatic hibernation is permanently disabled in config.'
                return
            }
            if ($cfg.PauseUntil) {
                $pauseEnd = [DateTime]::Parse($cfg.PauseUntil)
                if ((Get-Date) -le $pauseEnd) {
                    Write-Activity ("Skipped: automatic hibernation paused until {0:yyyy-MM-dd HH:mm:ss}." -f $pauseEnd)
                    return
                }
            }
        } catch {}
    }

    $clock = Get-PowerClock
    $now = $clock.Utc.ToLocalTime()
    $lastAwake = $clock.LastAwakeUtc.ToLocalTime()
    if ($Mode -eq 'Countdown') {
        if (-not (Test-StartWindow $now $lastAwake)) {
            Write-Activity 'Skipped: missed 18:20 or computer booted/resumed after 18:20.'
            return
        }
        if (-not [EveningHibernate.Native]::IsPwrHibernateAllowed()) {
            throw 'Windows hibernation is unavailable. Check powercfg /a.'
        }
        if (Test-Path -LiteralPath $script:StatePath) {
            try {
                $existingState = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($existingState.Date -eq $now.ToString('yyyy-MM-dd') -and
                    $existingState.OwnerSid -eq $script:OwnerSid -and
                    $existingState.Status -in @('manual', 'cancelled', 'postponed', 'consumed')) {
                    Write-Activity ("Skipped: user already set status to '{0}' today." -f $existingState.Status)
                    return
                }
            } catch { # Invalid or old state does not prevent a fresh 18:20 arming.
            }
        }
        $state = [pscustomobject]@{
            Version = 1
            Date = $now.ToString('yyyy-MM-dd')
            OwnerSid = $script:OwnerSid
            ArmedUtc = $clock.Utc.ToString('o')
            InterruptTicks = $clock.InterruptTicks
            Status = 'armed'
        }
        Save-State $state
        Write-Activity 'Armed today. Independent hibernation task is due at 18:30.'
        Show-Countdown -Deadline ($now.Date.AddHours(18).AddMinutes(30)) -Preview $false
    } else {
        $state = $null
        if (Test-Path -LiteralPath $script:StatePath) {
            try { $state = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { Write-Activity 'Skipped: unreadable state file.'; return }
        }
        if (-not (Test-HibernateWindow $now $lastAwake $state $clock)) {
            Write-Activity 'Skipped: no valid arming record, missed 18:30, reboot, or clock change.'
            return
        }
        # Consume first, so waking after a successful hibernation cannot repeat it.
        $state.Status = 'consumed'
        Save-State $state
        Write-Activity 'Requesting hibernation with shutdown.exe /h.'
        Invoke-HibernateRequest
    }
} catch {
    Write-Activity "ERROR: $($_.Exception.Message)"
    throw
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
