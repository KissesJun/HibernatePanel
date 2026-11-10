#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$folder = $PSScriptRoot
foreach ($name in @('EveningHibernate.ps1', 'Manage-Tasks.ps1', 'Create-Shortcut.ps1')) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $folder $name), [ref]$tokens, [ref]$errors
    )
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }
}
. (Join-Path $folder 'EveningHibernate.ps1') -Mode Library
$script:Passed = 0
function Assert-Case([string]$Name, [bool]$Actual, [bool]$Expected) {
    if ($Actual -ne $Expected) { throw "FAIL: $Name (actual: $Actual)" }
    $script:Passed++
    Write-Output "PASS: $Name"
}
function New-Arm([DateTime]$Local) {
    [pscustomobject]@{
        Version = 1
        Date = $Local.ToString('yyyy-MM-dd')
        OwnerSid = $script:OwnerSid
        ArmedUtc = $Local.ToUniversalTime().ToString('o')
        InterruptTicks = [long][TimeSpan]::FromHours(8).Ticks
        Status = 'armed'
    }
}
function New-Clock([DateTime]$Local, [int]$ElapsedSeconds = 600) {
    [pscustomobject]@{
        Utc = $Local.ToUniversalTime()
        InterruptTicks = [long][TimeSpan]::FromHours(8).Ticks +
            [TimeSpan]::FromSeconds($ElapsedSeconds).Ticks
    }
}
$day = [DateTime]::SpecifyKind([DateTime]'2026-10-28', [DateTimeKind]::Local)
$start = $day.AddHours(18).AddMinutes(20)
$awake = $day.AddHours(9)
$end = $start.AddMinutes(10)
$arm = New-Arm $start
$clock = New-Clock $end

Assert-Case 'normal weekday start' (Test-StartWindow $start $awake) $true
Assert-Case 'scheduler delay, fixed 18:30 deadline' (Test-StartWindow $start.AddSeconds(40) $awake) $true
Assert-Case 'boot at 18:20:10 is skipped' (Test-StartWindow $start.AddSeconds(20) $start.AddSeconds(10)) $false
Assert-Case 'resume after 18:20 is skipped' (Test-StartWindow $start.AddSeconds(30) $start.AddSeconds(25)) $false
Assert-Case 'early manual task invocation' (Test-StartWindow $start.AddSeconds(-1) $awake) $false
Assert-Case 'late launch is skipped' (Test-StartWindow $start.AddMinutes(1) $awake) $false
Assert-Case 'Saturday is skipped' (Test-StartWindow $start.AddDays(3) $awake) $false
Assert-Case 'Sunday is skipped' (Test-StartWindow $start.AddDays(4) $awake) $false
Assert-Case 'Monday runs' (Test-StartWindow $start.AddDays(5) $awake) $true

Assert-Case 'armed at 18:20, hibernate at 18:30' (Test-HibernateWindow $end $awake $arm $clock) $true
Assert-Case 'never hibernate without arming' (Test-HibernateWindow $end $awake $null $clock) $false
Assert-Case 'do not hibernate early' (Test-HibernateWindow $end.AddSeconds(-1) $awake $arm $clock) $false
$late = $end.AddMinutes(1)
Assert-Case 'do not catch up after 18:31' (Test-HibernateWindow $late $awake $arm (New-Clock $late 660)) $false
Assert-Case 'no surprise hibernation after late resume' (Test-HibernateWindow $end.AddSeconds(20) $end.AddSeconds(10) $arm (New-Clock $end.AddSeconds(20) 620)) $false
Assert-Case 'sleep/resume before deadline still allows protection' (Test-HibernateWindow $end $end.AddMinutes(-1) $arm $clock) $true
$rebootClock = New-Clock $end 0
Assert-Case 'reboot invalidates arming' (Test-HibernateWindow $end $awake $arm $rebootClock) $false
$arm.Date = '2026-10-27'
Assert-Case 'yesterday marker is skipped' (Test-HibernateWindow $end $awake $arm $clock) $false
$arm = New-Arm $start
$arm.Status = 'manual'
Assert-Case 'manual hibernation cancels automatic' (Test-HibernateWindow $end $awake $arm $clock) $false
$arm.Status = 'cancelled'
Assert-Case 'cancelled marker cancels automatic hibernate' (Test-HibernateWindow $end $awake $arm $clock) $false
$arm.Status = 'postponed'
Assert-Case 'postponed marker prevents regular 18:30 hibernate' (Test-HibernateWindow $end $awake $arm $clock) $false
$arm.Status = 'consumed'
Assert-Case 'consumed marker cannot hibernate again' (Test-HibernateWindow $end $awake $arm $clock) $false
$arm = New-Arm $start
$arm.OwnerSid = 'S-1-0-0'
Assert-Case 'another user marker is rejected' (Test-HibernateWindow $end $awake $arm $clock) $false
Assert-Case 'malformed marker fails safely' (Test-HibernateWindow $end $awake ([pscustomobject]@{Status='bad'}) $clock) $false

# Export only: no tasks are registered and no shutdown command is invoked.
& (Join-Path $folder 'Manage-Tasks.ps1') -Action Export | Out-Null
foreach ($name in @('Countdown', 'Hibernate')) {
    [xml]$xml = Get-Content -LiteralPath (Join-Path $folder "$name.xml") -Raw -Encoding Unicode
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    foreach ($setting in @('StartWhenAvailable', 'WakeToRun', 'DisallowStartIfOnBatteries', 'StopIfGoingOnBatteries')) {
        Assert-Case "$name/$setting is false" ($xml.SelectSingleNode("//t:$setting", $ns).InnerText -eq 'false') $true
    }
    Assert-Case "$name uses exactly 5 weekdays" ($xml.SelectNodes('//t:DaysOfWeek/*', $ns).Count -eq 5) $true
    Assert-Case "$name uses interactive user session" ($xml.SelectSingleNode('//t:LogonType', $ns).InnerText -eq 'InteractiveToken') $true
}
$nativeCheck = & (Join-Path $folder 'EveningHibernate.ps1') -Mode Check
Assert-Case 'native power clock is readable' (-not [string]::IsNullOrEmpty($nativeCheck.LastBootOrWake)) $true
Write-Output ("All {0} checks passed. No hibernation or task registration was performed." -f $script:Passed)
