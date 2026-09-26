param([switch]$ChildProcess)

$ErrorActionPreference = 'Stop'

# The diagnostic needs an STA thread for its dedicated WinForms target. Relaunch
# only the test itself; production scripts are not affected.
if (-not $ChildProcess -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $process = Start-Process -FilePath $windowsPowerShell -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $PSCommandPath), '-ChildProcess'
    ) -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) { throw "KeyHunter diagnostic failed with exit code $($process.ExitCode)." }
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$keyHunterRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$tempBase = Join-Path ([IO.Path]::GetTempPath()) ('KeyHunter-Diagnostic-' + [guid]::NewGuid().ToString('N'))
$tempRoot = Join-Path $tempBase 'KeyHunter'
$traySource = Join-Path $keyHunterRoot 'assets\KeyHunter-Tray.exe'
$collectorLauncherSource = Join-Path $keyHunterRoot 'assets\KeyHunter-Collect.exe'
$cleanupSource = Join-Path $keyHunterRoot 'assets\KeyHunter-Cleanup.ps1'
$agentSource = Join-Path $keyHunterRoot 'assets\KeyHunter-Agent.ps1'
$trayPath = Join-Path $tempRoot 'KeyHunter-Tray.exe'
$collectorLauncherPath = Join-Path $tempRoot 'KeyHunter-Collect.exe'
$readyPath = Join-Path $tempRoot 'agent.ready'
$logPath = Join-Path $tempRoot 'demo-events.jsonl'
$stopPath = Join-Path $tempRoot 'stop.flag'
$form = $null
$trayProcess = $null

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Copy-Item -LiteralPath $traySource -Destination $trayPath
    Copy-Item -LiteralPath $collectorLauncherSource -Destination $collectorLauncherPath
    Copy-Item -LiteralPath $agentSource -Destination (Join-Path $tempRoot 'KeyHunter-Agent.ps1')
    Set-Content -LiteralPath (Join-Path $tempRoot 'installed-at.txt') -Value (Get-Date).ToString('o') -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $tempRoot 'skip-injected.txt') -Value 'false' -Encoding Ascii

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $trayPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['LOCALAPPDATA'] = $tempBase
    $startInfo.EnvironmentVariables['KEYHUNTER_TRAY_MUTEX'] = 'Local\KeyHunterTrainingTray-Diagnostic-' + [guid]::NewGuid().ToString('N')
    $startInfo.EnvironmentVariables['KEYHUNTER_AGENT_MUTEX'] = 'Local\KeyHunter-Diagnostic-' + [guid]::NewGuid().ToString('N')
    $trayProcess = [Diagnostics.Process]::Start($startInfo)

    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $readyPath)) {
        if ($trayProcess.HasExited) { throw 'Tray application exited before agent.ready.' }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $readyPath)) { throw 'Agent did not become ready within 20 seconds.' }

    # Send ordinary text only into this dedicated diagnostic window. This tests
    # the complete hook -> C# ToUnicodeEx buffer -> JSONL path without typing in
    # any user application.
    $form = New-Object Windows.Forms.Form
    $form.Text = 'KeyHunter diagnostic target'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object Drawing.Size(440, 140)
    $form.TopMost = $true
    $box = New-Object Windows.Forms.TextBox
    $box.Location = New-Object Drawing.Point(20, 25)
    $box.Size = New-Object Drawing.Size(380, 28)
    $box.Font = New-Object Drawing.Font('Segoe UI', 12)
    $form.Controls.Add($box)
    $form.Show()
    $form.Activate()
    [void]$box.Focus()
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 350
    [Windows.Forms.SendKeys]::SendWait('na1')
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 1200

    New-Item -ItemType File -Path $stopPath -Force | Out-Null
    if (-not $trayProcess.WaitForExit(12000)) { throw 'Tray application did not exit after stop.flag.' }
    Start-Sleep -Milliseconds 400

    $events = @()
    foreach ($line in (Get-Content -LiteralPath $logPath | Where-Object { $_.Trim() })) {
        $events += ($line | ConvertFrom-Json)
    }
    $errors = @($events | Where-Object event -eq 'agent_error')
    $characters = @($events | Where-Object event -eq 'character')
    $keyDown = @($events | Where-Object event -eq 'key_down')
    $keyUp = @($events | Where-Object event -eq 'key_up')
    $joinedText = (($characters | ForEach-Object { [string]$_.value.text }) -join '')

    if ($errors.Count -ne 0) { throw "Agent logged $($errors.Count) internal error(s)." }
    if (-not ($events | Where-Object event -eq 'session_start')) { throw 'session_start missing.' }
    if (-not ($events | Where-Object event -eq 'hook_installed')) { throw 'hook_installed missing.' }
    if (-not ($events | Where-Object event -eq 'session_end')) { throw 'session_end missing.' }
    if ($keyDown.Count -lt 3 -or $keyUp.Count -lt 3) { throw "Expected at least 3 key_down/key_up events; got $($keyDown.Count)/$($keyUp.Count)." }
    if ($characters.Count -lt 3) { throw "Expected at least 3 character events; got $($characters.Count)." }
    if ($joinedText -notmatch '(?i)n' -or $joinedText -notmatch '1') { throw "Translated text is incomplete: '$joinedText'." }

    # Verify the console-free collector launcher separately with a harmless
    # local script. The production Collector is never executed by this test.
    $collectorMarker = Join-Path $tempRoot 'collector-launch.ok'
    Set-Content -LiteralPath (Join-Path $tempRoot 'Collect-KeyHunter.ps1') -Encoding Ascii -Value @'
Set-Content -LiteralPath $env:KEYHUNTER_COLLECT_TEST -Value 'PASS' -Encoding Ascii
'@
    $collectorInfo = New-Object Diagnostics.ProcessStartInfo
    $collectorInfo.FileName = $collectorLauncherPath
    $collectorInfo.UseShellExecute = $false
    $collectorInfo.CreateNoWindow = $true
    $collectorInfo.EnvironmentVariables['KEYHUNTER_COLLECT_TEST'] = $collectorMarker
    $collectorLauncher = [Diagnostics.Process]::Start($collectorInfo)
    [void]$collectorLauncher.WaitForExit(5000)
    $collectorDeadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $collectorDeadline -and -not (Test-Path -LiteralPath $collectorMarker)) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $collectorMarker)) { throw 'Collector launcher did not execute its local script.' }
    if ((Get-Content -LiteralPath $collectorMarker -Raw).Trim() -ne 'PASS') { throw 'Collector launcher marker is invalid.' }

    # Verify that deferred cleanup waits for its owning process, removes only
    # the exact LocalAppData\KeyHunter target and reports a verified result.
    $cleanupLocalAppData = Join-Path $tempBase 'CleanupLocalAppData'
    $cleanupTarget = Join-Path $cleanupLocalAppData 'KeyHunter'
    $cleanupScript = Join-Path $tempBase 'KeyHunter-Cleanup-Test.ps1'
    $cleanupStatus = Join-Path $tempBase 'cleanup.status'
    $holderScript = Join-Path $tempBase 'cleanup-holder.ps1'
    New-Item -ItemType Directory -Path $cleanupTarget -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cleanupTarget 'sentinel.txt') -Value 'delete me' -Encoding Ascii
    Copy-Item -LiteralPath $cleanupSource -Destination $cleanupScript -Force
    Set-Content -LiteralPath $holderScript -Value 'Start-Sleep -Milliseconds 800' -Encoding Ascii

    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $holderInfo = New-Object Diagnostics.ProcessStartInfo
    $holderInfo.FileName = $powerShell
    $holderInfo.Arguments = '-NoProfile -NonInteractive -File "{0}"' -f $holderScript.Replace('"', '""')
    $holderInfo.UseShellExecute = $false
    $holderInfo.CreateNoWindow = $true
    $holder = [Diagnostics.Process]::Start($holderInfo)

    $cleanupInfo = New-Object Diagnostics.ProcessStartInfo
    $cleanupInfo.FileName = $powerShell
    $cleanupInfo.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -File "{0}"' -f $cleanupScript.Replace('"', '""')
    $cleanupInfo.WorkingDirectory = $tempBase
    $cleanupInfo.UseShellExecute = $false
    $cleanupInfo.CreateNoWindow = $true
    $cleanupInfo.EnvironmentVariables['LOCALAPPDATA'] = $cleanupLocalAppData
    $cleanupInfo.EnvironmentVariables['KEYHUNTER_CLEANUP_TARGET'] = $cleanupTarget
    $cleanupInfo.EnvironmentVariables['KEYHUNTER_CLEANUP_WAIT_PID'] = [string]$holder.Id
    $cleanupInfo.EnvironmentVariables['KEYHUNTER_CLEANUP_STATUS'] = $cleanupStatus
    $cleanupProcess = [Diagnostics.Process]::Start($cleanupInfo)
    if (-not $cleanupProcess.WaitForExit(15000)) { throw 'Deferred cleanup test timed out.' }
    if ($cleanupProcess.ExitCode -ne 0) { throw "Deferred cleanup exited with code $($cleanupProcess.ExitCode)." }
    if (Test-Path -LiteralPath $cleanupTarget) { throw 'Deferred cleanup left its target directory behind.' }
    if (-not (Test-Path -LiteralPath $cleanupStatus) -or (Get-Content -LiteralPath $cleanupStatus -Raw).Trim() -ne 'removed') {
        throw 'Deferred cleanup did not publish a verified success result.'
    }

    Write-Host 'PASS: tray + agent + ordinary text translation + graceful stop + local collector launcher + deferred cleanup' -ForegroundColor Green
    Write-Host ("Events: key_down={0}, key_up={1}, character={2}, text='{3}'" -f $keyDown.Count, $keyUp.Count, $characters.Count, $joinedText)
}
finally {
    if ($form) { $form.Close(); $form.Dispose() }
    if ($trayProcess -and -not $trayProcess.HasExited) { Stop-Process -Id $trayProcess.Id -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath (Join-Path $tempRoot 'agent.pid')) {
        try {
            $agentPid = [int](Get-Content -LiteralPath (Join-Path $tempRoot 'agent.pid') -Raw).Trim()
            Stop-Process -Id $agentPid -Force -ErrorAction SilentlyContinue
        } catch {}
    }
    Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
}
