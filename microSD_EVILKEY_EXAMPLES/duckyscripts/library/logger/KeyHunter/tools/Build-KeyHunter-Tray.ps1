param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\assets\KeyHunter-Tray.exe'),
    [string]$CollectOutputPath = (Join-Path $PSScriptRoot '..\assets\KeyHunter-Collect.exe')
)

$ErrorActionPreference = 'Stop'

# PowerShell 7's Add-Type intentionally rejects executable output types. The
# Windows PowerShell 5.1 compiler still supports a genuine WindowsApplication,
# which is required here so no console window is ever allocated.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $process = Start-Process -FilePath $windowsPowerShell -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
        '-OutputPath', ('"{0}"' -f ([IO.Path]::GetFullPath($OutputPath))),
        '-CollectOutputPath', ('"{0}"' -f ([IO.Path]::GetFullPath($CollectOutputPath)))
    ) -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) { throw "Windows PowerShell compiler failed with exit code $($process.ExitCode)." }
    return
}

$source = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\assets\KeyHunter-Tray.cs')).Path
$output = [IO.Path]::GetFullPath($OutputPath)
$collectSource = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\assets\KeyHunter-Collect.cs')).Path
$collectOutput = [IO.Path]::GetFullPath($CollectOutputPath)
$outputDirectory = Split-Path -Parent $output
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $collectOutput -Force -ErrorAction SilentlyContinue

Add-Type -Path $source `
    -ReferencedAssemblies @('System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll') `
    -OutputAssembly $output `
    -OutputType WindowsApplication

Add-Type -Path $collectSource `
    -ReferencedAssemblies @('System.dll', 'System.Windows.Forms.dll') `
    -OutputAssembly $collectOutput `
    -OutputType WindowsApplication

if (-not (Test-Path -LiteralPath $output)) {
    throw "Tray application was not created: $output"
}
if (-not (Test-Path -LiteralPath $collectOutput)) {
    throw "Collector launcher was not created: $collectOutput"
}

$stream = [IO.File]::OpenRead($output)
try {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '') }
    finally { $sha256.Dispose() }
}
finally { $stream.Dispose() }
Write-Host "Built:  $output"
Write-Host "SHA256: $hash"

$stream = [IO.File]::OpenRead($collectOutput)
try {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $collectHash = ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '') }
    finally { $sha256.Dispose() }
}
finally { $stream.Dispose() }
Write-Host "Built:  $collectOutput"
Write-Host "SHA256: $collectHash"
