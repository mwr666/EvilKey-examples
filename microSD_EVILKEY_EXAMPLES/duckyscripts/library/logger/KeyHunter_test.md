# KeyHunter end-to-end test

Use one complete authorized test: install, record synthetic input in several applications and keyboard layouts, reboot, collect the data, remove the agent, and eject the card.

## 1. Preflight

On the demonstration computer, run:

```powershell
Test-Path "$env:LOCALAPPDATA\KeyHunter"
Test-Path "$([Environment]::GetFolderPath('Startup'))\KeyHunter.cmd"
Test-Path "D:\duckyscripts\helpers\SafeEject.ps1"
```

Expected: `False`, `False`, `True`. If either of the first two paths exists, run the `Collect-And-Remove` payload before testing again. Do not remove the files manually.

## 2. Install

On EvilKey, select `library/logger/KeyHunter/Install` and press `RUN`. Expect no continuous Caps Lock switching, no Notepad window with `KeyHunter-Install-Error.txt`, a green success indicator, and payload completion. After about 10 seconds without writes, the mass-storage interface should detach automatically.

Confirm that the agent started:

```powershell
$ready = Get-Content "$env:LOCALAPPDATA\KeyHunter\agent.ready" -Raw |
    ConvertFrom-Json
$ready
Get-Process -Id $ready.pid
Test-Path "$([Environment]::GetFolderPath('Startup'))\KeyHunter.cmd"
```

The process must exist and the final command must return `True`.

## 3. Generate synthetic data

Use only synthetic input. Type with a physical keyboard:

```text
KH-PL-01: Polish layout check: ąćęłńóśźż 1234567890
KH-EN-02: The quick brown fox jumps over the lazy dog
KH-BROWSER-03: Background capture test
KH-PASTE-04: synthetic clipboard content
KH-IDLE-05
```

Type the first line in Notepad with the Polish keyboard layout. Switch to English for the second line. Type the third in a browser text field. Paste the fourth with `Ctrl+V`. Switch applications with `Alt+Tab`, change between PL and EN layouts, and use Shift, Ctrl, AltGr, Backspace, and Enter. Wait about 30 seconds before typing `KH-IDLE-05`. Do not type real passwords: the agent records input across the current session.

## 4. Verify restart

Restart the computer and sign in without reinstalling. Confirm that the agent is running:

```powershell
$ready = Get-Content "$env:LOCALAPPDATA\KeyHunter\agent.ready" -Raw |
    ConvertFrom-Json
Get-Process -Id $ready.pid
```

Then type `KH-REBOOT-06: Agent restarted from Startup` in Notepad.

## 5. Collect and remove

On EvilKey, select `library/logger/KeyHunter/Collect-And-Remove` and press `RUN`. Expect the agent to stop, a result folder and `COLLECT_COMPLETE.flag` on the card, removal of the Startup launcher and `%LOCALAPPDATA%\KeyHunter`, safe eject, and a green device indicator. After eject, expose the card again through USB Tool.

## 6. Evaluate the result

Run:

```powershell
$root = "D:\duckyscripts\library\logger\KeyHunter\Collect-And-Remove"
$run = Get-ChildItem $root -Directory -Filter "KeyHunter-DUCKY-*" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
$log = Join-Path $run.FullName "demo-events.jsonl"
$marker = Join-Path $run.FullName "COLLECT_COMPLETE.flag"
$events = foreach ($line in Get-Content $log) {
    if ($line.Trim()) { $line | ConvertFrom-Json }
}
$characters = ($events |
    Where-Object event -eq "character" |
    ForEach-Object { $_.value.text }) -join ""
$requiredMarkers = @("KH-PL-01", "KH-EN-02", "KH-BROWSER-03", "KH-IDLE-05", "KH-REBOOT-06")
[pscustomobject]@{
    ResultFolder       = $run.FullName
    CompletionMarker   = Test-Path $marker
    EventCount         = $events.Count
    SessionStart       = @($events | Where-Object event -eq "session_start").Count
    SessionEnd         = @($events | Where-Object event -eq "session_end").Count
    HookInstalled      = @($events | Where-Object event -eq "hook_installed").Count
    ForegroundChanges  = @($events | Where-Object event -eq "foreground_changed").Count
    LayoutChanges      = @($events | Where-Object event -eq "keyboard_layout_changed").Count
    ClipboardEvents    = @($events | Where-Object event -eq "clipboard_paste").Count
    AgentErrors        = @($events | Where-Object event -eq "agent_error").Count
}
$requiredMarkers | ForEach-Object {
    [pscustomobject]@{ Marker = $_; Found = $characters.Contains($_) }
}
Get-Content $marker -Raw
```

Pass criteria: `CompletionMarker = True`; at least two `hook_installed` events after reboot; all required markers found; at least one clipboard event; zero agent errors; and `"stopMode": "graceful"` in `COLLECT_COMPLETE.flag`.

Finally, confirm removal:

```powershell
Test-Path "$env:LOCALAPPDATA\KeyHunter"
Test-Path "$([Environment]::GetFolderPath('Startup'))\KeyHunter.cmd"
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object CommandLine -Match "KeyHunter-Agent\.ps1"
```

Expect `False`, `False`, and no matching process.
