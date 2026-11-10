#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Remove', 'Status', 'Export')]
    [string]$Action = 'Status'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskPrefix = 'Junmo-EveningHibernate-'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$userSid = $identity.User.Value
$scriptPath = Join-Path $PSScriptRoot 'EveningHibernate.ps1'
$powershellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$definitions = @(
    @{ Name = 'Countdown'; Time = '18:20:00'; Limit = 'PT12M' },
    @{ Name = 'Hibernate'; Time = '18:30:00'; Limit = 'PT1M' }
)

function New-TaskXml($Definition) {
    $arguments = '-NoLogo -NoProfile -STA -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode {1}' -f $scriptPath, $Definition.Name
    $escapedArgs = [Security.SecurityElement]::Escape($arguments)
    $escapedExe = [Security.SecurityElement]::Escape($powershellPath)
    $escapedWorkDir = [Security.SecurityElement]::Escape($PSScriptRoot)
    # Tomorrow if today's trigger already passed: installation never runs a task.
    $boundary = [DateTime]::Today.Add([TimeSpan]::Parse($Definition.Time))
    if ($boundary -le [DateTime]::Now) { $boundary = $boundary.AddDays(1) }
    $start = $boundary.ToString("yyyy-MM-dd'T'HH:mm:ss")
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Weekday battery protection: 18:20 reminder, 18:30 hibernation only if armed today.</Description></RegistrationInfo>
  <Triggers><CalendarTrigger><StartBoundary>$start</StartBoundary><Enabled>true</Enabled><ScheduleByWeek><WeeksInterval>1</WeeksInterval><DaysOfWeek><Monday/><Tuesday/><Wednesday/><Thursday/><Friday/></DaysOfWeek></ScheduleByWeek></CalendarTrigger></Triggers>
  <Principals><Principal id="Owner"><UserId>$userSid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>false</AllowStartOnDemand>
    <Enabled>true</Enabled><Hidden>false</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>$($Definition.Limit)</ExecutionTimeLimit>
    <Priority>5</Priority>
  </Settings>
  <Actions Context="Owner"><Exec><Command>$escapedExe</Command><Arguments>$escapedArgs</Arguments><WorkingDirectory>$escapedWorkDir</WorkingDirectory></Exec></Actions>
</Task>
"@
}

if ($Action -eq 'Export') {
    foreach ($definition in $definitions) {
        $xmlPath = Join-Path $PSScriptRoot ($definition.Name + '.xml')
        New-TaskXml $definition | Set-Content -LiteralPath $xmlPath -Encoding Unicode
        Write-Output $xmlPath
    }
    return
}

if ($Action -eq 'Install') {
    # Preflight before making any scheduler changes.
    $check = & $scriptPath -Mode Check
    if (-not $check.HibernateAvailable) { throw 'Hibernation is unavailable. Run powercfg /a first.' }
    foreach ($definition in $definitions) {
        Register-ScheduledTask -TaskName ($taskPrefix + $definition.Name) -Xml (New-TaskXml $definition) -Force | Out-Null
    }
    Write-Output 'Installed two weekday tasks. No task has been run now.'
} elseif ($Action -eq 'Remove') {
    foreach ($definition in $definitions) {
        $task = Get-ScheduledTask -TaskName ($taskPrefix + $definition.Name) -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            Stop-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -InputObject $task -Confirm:$false
        }
    }
    # Invalidate a pending day and clear temporary postponed tasks
    $postponedTasks = @('Junmo-EveningHibernate-PostponedCountdown', 'Junmo-EveningHibernate-PostponedHibernate')
    foreach ($pt in $postponedTasks) {
        $task = Get-ScheduledTask -TaskName $pt -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            Stop-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -InputObject $task -Confirm:$false
        }
    }
    $statePath = Join-Path $PSScriptRoot 'today.json'
    if (Test-Path -LiteralPath $statePath) {
        Set-Content -LiteralPath $statePath -Value '{"Status":"disabled"}' -Encoding UTF8
    }
    Write-Output 'Removed tasks and invalidated any pending hibernation.'
} else {
    foreach ($definition in $definitions) {
        $task = Get-ScheduledTask -TaskName ($taskPrefix + $definition.Name) -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            Write-Output ($taskPrefix + $definition.Name + ': not installed')
        } else {
            $task | Select-Object TaskName, State
            $task | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult, NextRunTime
        }
    }
    foreach ($pt in @('Junmo-EveningHibernate-PostponedCountdown', 'Junmo-EveningHibernate-PostponedHibernate')) {
        $task = Get-ScheduledTask -TaskName $pt -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            $task | Select-Object TaskName, State
            $task | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult, NextRunTime
        }
    }
}
