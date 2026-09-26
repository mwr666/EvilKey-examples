param(
    [string]$OutputRoot = '',
    [int]$StopTimeoutSeconds = 8,
    [string]$DriveLabel = 'DUCKY',      # passed by the payload; used in folder name / summary / marker
    [string]$SafeEjectPath = '',        # empty = auto-discover SafeEject.ps1 locally or on the DUCKY volume
    [int]$DriveWaitSeconds = 90
)

$ErrorActionPreference = 'Stop'
$demoRoot     = Join-Path $env:LOCALAPPDATA 'KeyHunter'
$logPath      = Join-Path $demoRoot 'demo-events.jsonl'
$pidPath      = Join-Path $demoRoot 'agent.pid'
$trayPidPath  = Join-Path $demoRoot 'tray.pid'
$stopFlagPath = Join-Path $demoRoot 'stop.flag'
$installPath  = Join-Path $demoRoot 'install.json'
$readyPath    = Join-Path $demoRoot 'agent.ready'
$agentPath    = Join-Path $demoRoot 'KeyHunter-Agent.ps1'
$trayPath     = Join-Path $demoRoot 'KeyHunter-Tray.exe'
$startupDirectory = [Environment]::GetFolderPath('Startup')
$startupPath  = Join-Path $startupDirectory 'KeyHunter.vbs'
$legacyStartupPath = Join-Path $startupDirectory 'KeyHunter.cmd'
$runKey       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'KeyHunterTraining'

function Find-SafeEjectScript {
    if ($SafeEjectPath) {
        if (Test-Path -LiteralPath $SafeEjectPath) { return (Resolve-Path -LiteralPath $SafeEjectPath).Path }
        Write-Warning "Specified SafeEject path not found: $SafeEjectPath"
        return $null
    }
    # Walk up from this script's folder. At each level check both a direct
    # helper and the canonical PicoFIDO duckyscripts\helpers location.
    $dir = $PSScriptRoot
    for ($i = 0; $i -lt 8 -and $dir; $i++) {
        foreach ($relative in @('SafeEject.ps1', 'helpers\SafeEject.ps1')) {
            $candidate = Join-Path $dir $relative
            if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }

    # A locally installed collector is outside the card tree. Resolve the
    # helper through the volume label in that case.
    $volume = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.VolumeName -eq $DriveLabel } | Select-Object -First 1
    if ($volume) {
        $candidate = Join-Path $volume.DeviceID 'duckyscripts\helpers\SafeEject.ps1'
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    return $null
}

function Wait-KeyHunterVolume {
    $deadline = (Get-Date).AddSeconds($DriveWaitSeconds)
    do {
        $volume = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.VolumeName -eq $DriveLabel } | Select-Object -First 1
        if ($volume) { return $volume }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "Volume '$DriveLabel' was not available within ${DriveWaitSeconds}s."
}

function Start-DeferredCleanup {
    $cleanupSource = Join-Path $demoRoot 'KeyHunter-Cleanup.ps1'
    if (-not (Test-Path -LiteralPath $cleanupSource)) {
        $volume = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.VolumeName -eq $DriveLabel } | Select-Object -First 1
        if ($volume) {
            $cleanupSource = Join-Path $volume.DeviceID 'duckyscripts\library\logger\KeyHunter\assets\KeyHunter-Cleanup.ps1'
        }
    }
    if (-not (Test-Path -LiteralPath $cleanupSource)) {
        throw 'Deferred cleanup helper was not found locally or on the DUCKY volume.'
    }

    $tempCleanup = Join-Path ([IO.Path]::GetTempPath()) ("KeyHunter-Cleanup-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $cleanupSource -Destination $tempCleanup -Force

    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShell
    $startInfo.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -File "{0}"' -f $tempCleanup.Replace('"', '""')
    $startInfo.WorkingDirectory = [IO.Path]::GetTempPath()
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.EnvironmentVariables['KEYHUNTER_CLEANUP_TARGET'] = $demoRoot
    $startInfo.EnvironmentVariables['KEYHUNTER_CLEANUP_WAIT_PID'] = [string]$PID

    $cleanupProcess = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $cleanupProcess) {
        Remove-Item -LiteralPath $tempCleanup -Force -ErrorAction SilentlyContinue
        throw 'Deferred cleanup process was not created.'
    }
    Start-Sleep -Milliseconds 250
    if ($cleanupProcess.HasExited) {
        $exitCode = $cleanupProcess.ExitCode
        Remove-Item -LiteralPath $tempCleanup -Force -ErrorAction SilentlyContinue
        throw "Deferred cleanup process exited prematurely with code $exitCode."
    }
}

function Get-ValidatedAgentProcess {
    param([Parameter(Mandatory = $true)][int]$AgentPid)

    $process = Get-Process -Id $AgentPid -ErrorAction SilentlyContinue
    if (-not $process) { return $null }

    if ($process.ProcessName -notin @('powershell', 'pwsh')) {
        throw "PID $AgentPid belongs to '$($process.ProcessName)', not the KeyHunter PowerShell agent. Refusing to stop it."
    }

    $ready = $null
    try { $ready = Get-Content -LiteralPath $readyPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
    if (-not $ready -or [int]$ready.pid -ne $AgentPid) {
        throw "PID $AgentPid has no matching agent.ready identity. Refusing to stop it."
    }

    $cim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $AgentPid" -ErrorAction Stop
    $commandLine = [string]$cim.CommandLine
    if ([string]::IsNullOrWhiteSpace($commandLine) -or
        $commandLine.IndexOf($agentPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "PID $AgentPid command line does not contain the expected agent path. Refusing to stop it."
    }

    if ($ready.processStartUtc) {
        $expectedStart = [DateTime]::Parse([string]$ready.processStartUtc).ToUniversalTime()
        $actualStart = $process.StartTime.ToUniversalTime()
        if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 2) {
            throw "PID $AgentPid start time does not match agent.ready. Refusing to stop it."
        }
    }

    return $process
}

function Get-ValidatedTrayProcess {
    param([Parameter(Mandatory = $true)][int]$TrayPid)

    $process = Get-Process -Id $TrayPid -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    $actualPath = $null
    try { $actualPath = $process.MainModule.FileName } catch {}
    if (-not $actualPath -or -not [string]::Equals($actualPath, $trayPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "PID $TrayPid is not the expected KeyHunter tray application. Refusing to stop it."
    }
    return $process
}

if (-not (Test-Path -LiteralPath $installPath)) {
    throw "No installation found at '$installPath'. Nothing to collect."
}
$install = Get-Content -LiteralPath $installPath -Raw | ConvertFrom-Json

# The installed copy starts before PicoFIDO exposes STORAGE. Wait for the
# labelled card here, then choose the canonical result directory on that card.
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $duckyVolume = Wait-KeyHunterVolume
    $OutputRoot = Join-Path $duckyVolume.DeviceID 'duckyscripts\library\logger\KeyHunter\Collect-And-Remove'
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

# --- 1) graceful stop: use the agent's own stop path so it logs session_end ----
$agentPid = $null
if (Test-Path -LiteralPath $pidPath) {
    try { $agentPid = [int](Get-Content -LiteralPath $pidPath -Raw).Trim() } catch {}
}

$stopMode = 'not_running'
$agentProcess = if ($agentPid) { Get-ValidatedAgentProcess -AgentPid $agentPid } else { $null }
# A single stop flag terminates both the agent and its tray companion.
New-Item -ItemType File -Path $stopFlagPath -Force | Out-Null
if ($agentProcess) {
    if (-not $agentProcess.WaitForExit($StopTimeoutSeconds * 1000)) {
        Write-Warning "Agent did not stop within ${StopTimeoutSeconds}s; forcing termination."
        Stop-Process -InputObject $agentProcess -Force -ErrorAction Stop
        [void]$agentProcess.WaitForExit(2000)
        $stopMode = 'forced'
    } else {
        $stopMode = 'graceful'
    }
}

$trayPid = $null
if (Test-Path -LiteralPath $trayPidPath) {
    try { $trayPid = [int](Get-Content -LiteralPath $trayPidPath -Raw).Trim() } catch {}
}
$trayProcess = if ($trayPid) { Get-ValidatedTrayProcess -TrayPid $trayPid } else { $null }
if ($trayProcess -and -not $trayProcess.WaitForExit(5000)) {
    Write-Warning 'Tray application did not stop after the stop flag; forcing its verified process to exit.'
    Stop-Process -InputObject $trayProcess -Force -ErrorAction Stop
    [void]$trayProcess.WaitForExit(2000)
}

# --- 2) collect artifacts -------------------------------------------------------
$stamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
$safeLabel = ($DriveLabel -replace '[\\/:*?"<>|]', '_')
if (-not $safeLabel) { $safeLabel = 'NOLABEL' }
$outDir    = Join-Path $OutputRoot ("KeyHunter-{0}-{1}" -f $safeLabel, $stamp)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

if (Test-Path -LiteralPath $logPath) { Copy-Item -LiteralPath $logPath -Destination (Join-Path $outDir 'demo-events.jsonl') }
Copy-Item -LiteralPath $installPath -Destination (Join-Path $outDir 'install.json') -ErrorAction SilentlyContinue
foreach ($marker in @('agent.ready', 'agent.error')) {
    $src = Join-Path $demoRoot $marker
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $outDir $marker) }
}

# Completion marker on the card so firmware/manager can detect a finished run.
[ordered]@{
    completedAt = (Get-Date).ToString('o')
    driveLabel  = $DriveLabel
    stopMode    = $stopMode
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outDir 'COLLECT_COMPLETE.flag') -Encoding UTF8

# --- 3) summary ------------------------------------------------------------------
$counts     = @{}
$totalLines = 0
$collectedLog = Join-Path $outDir 'demo-events.jsonl'
if (Test-Path -LiteralPath $collectedLog) {
    foreach ($line in (Get-Content -LiteralPath $collectedLog | Where-Object { $_.Trim() })) {
        $totalLines++
        try {
            $e = $line | ConvertFrom-Json
            if (-not $counts.ContainsKey($e.event)) { $counts[$e.event] = 0 }
            $counts[$e.event]++
        } catch {}
    }
}

Write-Host ''
Write-Host 'KeyHunter collection complete' -ForegroundColor Cyan
Write-Host ("Drive label:   {0}" -f $DriveLabel)
Write-Host ("Stop mode:     {0}" -f $stopMode)
Write-Host ("Events logged: {0}" -f $totalLines)
foreach ($k in ($counts.Keys | Sort-Object)) { Write-Host ("  {0,-28} {1}" -f $k, $counts[$k]) }
if (-not $counts.ContainsKey('session_end')) {
    Write-Warning 'No session_end event found (agent may have been force-stopped).'
}
Write-Host ("Artifacts:     {0}" -f $outDir)

# --- 4) remove autostart now; remove local files after this Collector exits -------
Remove-ItemProperty -LiteralPath $runKey -Name $runValueName -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $startupPath) {
    Remove-Item -LiteralPath $startupPath -Force
}
if (Test-Path -LiteralPath $legacyStartupPath) {
    Remove-Item -LiteralPath $legacyStartupPath -Force
}
Start-DeferredCleanup

Write-Host 'Tray app and autostart removed; local demo files queued for verified deferred cleanup.' -ForegroundColor Green

# --- 5) safe eject: hand control back to the firmware ----------------------------
$safeEject = Find-SafeEjectScript
if (-not $safeEject) {
    throw 'SafeEject.ps1 not found (override with -SafeEjectPath). Artifacts were collected, but safe eject did not run.'
}
& $safeEject -DriveLabel $DriveLabel -SignalScrollLock
Write-Host "SafeEject invoked: $safeEject" -ForegroundColor Green
