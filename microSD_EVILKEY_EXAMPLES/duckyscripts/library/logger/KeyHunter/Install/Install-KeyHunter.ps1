param(
    [string]$DriveLabel = 'DUCKY',
    [string]$SkipInjected = 'true',
    [int]$ReadyTimeoutSeconds = 20,
    [string]$StartupDirectory = '',
    [string]$SignalSuccess = 'true',
    [string]$RegisterStartup = 'true'
)

$ErrorActionPreference = 'Stop'
$startupDirectoryResolved = if ($StartupDirectory) { $StartupDirectory } else { [Environment]::GetFolderPath('Startup') }
$demoRoot     = Join-Path $env:LOCALAPPDATA 'KeyHunter'
$agentPath    = Join-Path $demoRoot 'KeyHunter-Agent.ps1'
$trayPath     = Join-Path $demoRoot 'KeyHunter-Tray.exe'
$collectorPath = Join-Path $demoRoot 'Collect-KeyHunter.ps1'
$collectorLauncherPath = Join-Path $demoRoot 'KeyHunter-Collect.exe'
$readyPath    = Join-Path $demoRoot 'agent.ready'
$errorPath    = Join-Path $demoRoot 'agent.error'
$stopFlagPath = Join-Path $demoRoot 'stop.flag'
$pidPath      = Join-Path $demoRoot 'agent.pid'
$trayPidPath  = Join-Path $demoRoot 'tray.pid'
$legacyVbs    = Join-Path $startupDirectoryResolved 'KeyHunter.vbs'
$legacyCmd    = Join-Path $startupDirectoryResolved 'KeyHunter.cmd'
$runKey       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'KeyHunterTraining'
$script:trayProcess = $null

$script:skipInjectedEnabled = [bool]($SkipInjected -match '^(?i)(1|true|\$true)$')
$script:signalSuccessEnabled = [bool]($SignalSuccess -match '^(?i)(1|true|\$true)$')
$script:registerStartupEnabled = [bool]($RegisterStartup -match '^(?i)(1|true|\$true)$')

function Stop-InstalledProcess {
    param(
        [Parameter(Mandatory = $true)][string]$PidFile,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [int]$WaitMilliseconds = 3000
    )
    $targetPid = $null
    try { $targetPid = [int](Get-Content -LiteralPath $PidFile -Raw -ErrorAction Stop).Trim() } catch {}
    if (-not $targetPid) { return }
    $process = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if (-not $process) { return }
    $actualPath = $null
    try { $actualPath = $process.MainModule.FileName } catch {}
    if (-not $actualPath -or -not [string]::Equals($actualPath, $ExpectedPath, [StringComparison]::OrdinalIgnoreCase)) { return }
    if (-not $process.WaitForExit($WaitMilliseconds)) {
        Stop-Process -InputObject $process -Force -ErrorAction SilentlyContinue
        [void]$process.WaitForExit(1000)
    }
}

function Remove-InstallArtifacts {
    New-Item -ItemType File -Path $stopFlagPath -Force -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Milliseconds 750
    Stop-InstalledProcess -PidFile $pidPath -ExpectedPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    Stop-InstalledProcess -PidFile $trayPidPath -ExpectedPath $trayPath
    Remove-ItemProperty -LiteralPath $runKey -Name $runValueName -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $legacyVbs -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $legacyCmd -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $demoRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Send-KeyHunterLockSignal {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ScrollLock', 'CapsLock')]
        [string]$Key
    )

    if (-not ('KeyHunterLockSignal' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class KeyHunterLockSignal
{
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const byte VK_CAPITAL = 0x14;
    private const byte VK_SCROLL = 0x91;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern void keybd_event(
        byte virtualKey,
        byte scanCode,
        uint flags,
        UIntPtr extraInfo);

    private static void Tap(byte virtualKey)
    {
        keybd_event(virtualKey, 0, 0, UIntPtr.Zero);
        keybd_event(virtualKey, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    public static void ScrollLock() { Tap(VK_SCROLL); }
    public static void CapsLock() { Tap(VK_CAPITAL); }
}
'@
    }

    if ($Key -eq 'ScrollLock') {
        [KeyHunterLockSignal]::ScrollLock()
    }
    else {
        [KeyHunterLockSignal]::CapsLock()
    }
}

try {
    $sourceAgent = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\assets\KeyHunter-Agent.ps1')).Path
    $sourceTray  = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\assets\KeyHunter-Tray.exe')).Path
    $sourceCollector = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\Collect-And-Remove\Collect-KeyHunter.ps1')).Path
    $sourceCollectorLauncher = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\assets\KeyHunter-Collect.exe')).Path
    $sourceSafeEject = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..\..\helpers\SafeEject.ps1')).Path

    New-Item -ItemType Directory -Path $demoRoot -Force | Out-Null
    Copy-Item -LiteralPath $sourceAgent -Destination $agentPath -Force
    Copy-Item -LiteralPath $sourceTray -Destination $trayPath -Force
    Copy-Item -LiteralPath $sourceCollector -Destination $collectorPath -Force
    Copy-Item -LiteralPath $sourceCollectorLauncher -Destination $collectorLauncherPath -Force

    Remove-Item -LiteralPath $stopFlagPath, $readyPath, $errorPath -Force -ErrorAction SilentlyContinue

    $installedAt = (Get-Date).ToString('o')

    Set-Content `
        -LiteralPath (Join-Path $demoRoot 'installed-at.txt') `
        -Value $installedAt `
        -Encoding Ascii

    Set-Content `
        -LiteralPath (Join-Path $demoRoot 'skip-injected.txt') `
        -Value $script:skipInjectedEnabled.ToString().ToLowerInvariant() `
        -Encoding Ascii

    $metadata = [ordered]@{
        installedAt            = $installedAt
        computer               = $env:COMPUTERNAME
        user                   = $env:USERNAME
        driveLabel             = $DriveLabel
        scope                  = 'Global training agent; WH_KEYBOARD_LL hook across current user session'
        skipInjected           = [bool]$script:skipInjectedEnabled
        agentPath              = $agentPath
        trayPath               = $trayPath
        collectorPath          = $collectorPath
        collectorLauncherPath  = $collectorLauncherPath
        safeEjectPath           = $sourceSafeEject
        startupPath            = if ($script:registerStartupEnabled) {
            "$runKey\$runValueName"
        }
        else {
            $null
        }
        launcherType           = 'Windows tray application; agent child process is created without a console window'
        readyPath              = $readyPath
        errorPath              = $errorPath
    }

    $metadata |
        ConvertTo-Json -Depth 4 |
        Set-Content `
            -LiteralPath (Join-Path $demoRoot 'install.json') `
            -Encoding UTF8

    # Remove launchers left by earlier versions.
    Remove-Item -LiteralPath $legacyVbs -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $legacyCmd -Force -ErrorAction SilentlyContinue

    if ($script:registerStartupEnabled) {
        New-Item -Path $runKey -Force | Out-Null
        Set-ItemProperty -LiteralPath $runKey -Name $runValueName -Value ('"{0}"' -f $trayPath)
    }

    # Do not open another external try block here.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $trayPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $script:trayProcess = [System.Diagnostics.Process]::Start($startInfo)

    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    $state = 'timeout'

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $readyPath) {
            $state = 'ready'
            break
        }

        if (Test-Path -LiteralPath $errorPath) {
            $state = 'error'
            break
        }

        if ($script:trayProcess.HasExited) {
            $state = 'tray-exited'
            break
        }

        Start-Sleep -Milliseconds 200
    }

    switch ($state) {
        'ready' {
            $agentPid = $null
            try {
                $agentPid = [int]((Get-Content -LiteralPath $readyPath -Raw |
                    ConvertFrom-Json).pid)
            }
            catch {}

            if (-not $agentPid -or
                -not (Get-Process -Id $agentPid -ErrorAction SilentlyContinue)) {
                throw 'Agent reported ready but its process is not running.'
            }

            if (-not (Test-Path -LiteralPath $trayPidPath)) {
                throw 'Tray application did not publish tray.pid.'
            }

            if ($script:signalSuccessEnabled) {
                # The collector's proven completion path first flushes and
                # ejects DUCKY. After HID settles, emit a long result pulse and
                # restore Scroll Lock on the host side. The payload therefore
                # never calls RESTORE_HOST_KEYBOARD_LOCK_STATE after eject.
                & $sourceSafeEject -DriveLabel $DriveLabel | Out-Null
                Start-Sleep -Milliseconds 1000
                Send-KeyHunterLockSignal -Key ScrollLock
                Start-Sleep -Milliseconds 1500
                Send-KeyHunterLockSignal -Key ScrollLock
                Write-Host "KeyHunter ready (agent PID $agentPid); DUCKY ejected and success pulse sent." -ForegroundColor Green
            }
        }

        'error' {
            $detail = ''
            try {
                $detail = (Get-Content -LiteralPath $errorPath -Raw).Trim()
            }
            catch {}

            throw "Agent failed to start: $detail"
        }

        'tray-exited' {
            throw 'Tray application exited before the agent became ready.'
        }

        default {
            throw "Agent did not report ready within ${ReadyTimeoutSeconds}s."
        }
    }
}
catch {
    $message = $_.Exception.Message
    $failureSignalSent = $false
    $cleanupCompleted = $false

    try {
        Send-KeyHunterLockSignal -Key CapsLock
        Start-Sleep -Milliseconds 1500
        Send-KeyHunterLockSignal -Key CapsLock
        $failureSignalSent = $true
    }
    catch {}

    try {
        Remove-InstallArtifacts
        $cleanupCompleted = $true
    }
    catch {
        $message += " Cleanup failed: $($_.Exception.Message)"
    }

    $signalText = if ($failureSignalSent) {
        'Failure signal was sent.'
    }
    else {
        'Failure signal could not be sent.'
    }

    $cleanupText = if ($cleanupCompleted) {
        'Install artifacts were removed.'
    }
    else {
        'Install artifacts could not be completely removed.'
    }

    throw "$message $signalText $cleanupText"
}
