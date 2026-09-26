$ErrorActionPreference = 'Stop'

$targetDirectory = [Environment]::GetEnvironmentVariable('KEYHUNTER_CLEANUP_TARGET')
$waitPidRaw      = [Environment]::GetEnvironmentVariable('KEYHUNTER_CLEANUP_WAIT_PID')
$statusPath      = [Environment]::GetEnvironmentVariable('KEYHUNTER_CLEANUP_STATUS')
$errorPath       = Join-Path ([IO.Path]::GetTempPath()) 'KeyHunter-Cleanup-LastError.log'

try {
    if ([string]::IsNullOrWhiteSpace($targetDirectory)) {
        throw 'KEYHUNTER_CLEANUP_TARGET is missing.'
    }

    $expectedTarget = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KeyHunter')).TrimEnd('\')
    $actualTarget   = [IO.Path]::GetFullPath($targetDirectory).TrimEnd('\')
    if (-not [string]::Equals($actualTarget, $expectedTarget, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected directory: $actualTarget"
    }

    $waitPid = 0
    if (-not [int]::TryParse($waitPidRaw, [ref]$waitPid) -or $waitPid -le 0) {
        throw 'KEYHUNTER_CLEANUP_WAIT_PID is invalid.'
    }

    # The Collector is executing from the directory being removed. Wait until
    # it has completed SafeEject and exited before starting any delete attempt.
    $parentDeadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $parentDeadline -and (Get-Process -Id $waitPid -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 200
    }
    if (Get-Process -Id $waitPid -ErrorAction SilentlyContinue) {
        throw "Collector process $waitPid did not exit within 180 seconds."
    }

    $deleteDeadline = (Get-Date).AddSeconds(20)
    do {
        if (-not (Test-Path -LiteralPath $actualTarget)) { break }
        Remove-Item -LiteralPath $actualTarget -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $actualTarget) { Start-Sleep -Milliseconds 250 }
    } while ((Get-Date) -lt $deleteDeadline)

    if (Test-Path -LiteralPath $actualTarget) {
        throw "KeyHunter directory still exists after deferred cleanup: $actualTarget"
    }

    Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($statusPath)) {
        [IO.File]::WriteAllText($statusPath, 'removed')
    }
}
catch {
    $detail = "{0}`r`n{1}" -f (Get-Date).ToString('o'), $_.Exception.ToString()
    try { [IO.File]::WriteAllText($errorPath, $detail) } catch {}
    if (-not [string]::IsNullOrWhiteSpace($statusPath)) {
        try { [IO.File]::WriteAllText($statusPath, 'failed') } catch {}
    }
    exit 1
}
finally {
    # This copy lives in %TEMP%, outside the directory being removed.
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}

