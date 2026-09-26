# KeyHunter (global training agent + tray timer)

A controlled laboratory keyboard-capture demonstrator for Windows. A headless PowerShell agent installs a
`WH_KEYBOARD_LL` low-level keyboard hook and records every keystroke made in the current
user session — across all applications — to a JSONL file. A small Windows tray companion
starts the agent without allocating a console window and restarts it at logon through the
standard per-user `HKCU\...\Run` entry. The tray icon is deliberately low-contrast, but it is
not blank: its tooltip identifies `KeyHunter training`, and opening it displays the elapsed
time since installation. This keeps the exercise discoverable without putting a window on
the taskbar during normal operation.

## Files
- `assets/KeyHunter-Agent.ps1` — background KeyHunter agent (installed to `%LOCALAPPDATA%\KeyHunter\`)
- `assets/KeyHunter-Tray.exe` — console-free Windows tray companion with the elapsed-time window; it owns the subtle visible training icon and starts the agent as a hidden child process.
- `assets/KeyHunter-Tray.cs` — inspectable source for the tray application.
- `assets/KeyHunter-Collect.exe` / `.cs` — minimal console-free launcher for the locally installed Collector. It starts the script with the normal machine execution policy and does not use `-ExecutionPolicy Bypass` or an inline PowerShell command.
- `assets/KeyHunter-Cleanup.ps1` — narrowly scoped deferred remover. A temporary copy waits for the Collector to finish, accepts only `%LOCALAPPDATA%\KeyHunter` as its deletion target, retries removal, verifies that the directory disappeared, and records a diagnostic error in `%TEMP%` on failure.
- `tools/Build-KeyHunter-Tray.ps1` — reproducibly compiles the tray EXE with Windows PowerShell's built-in C# compiler.
- `Install/Install-KeyHunter.ps1` — copies the agent, tray app and a local Collector into `%LOCALAPPDATA%\KeyHunter`, writes `install.json`, creates the standard `KeyHunterTraining` HKCU Run value, starts the tray app, and waits for explicit ready/error markers before signalling success (Scroll Lock) to EvilKey. On failure it stops only validated KeyHunter processes and removes all current and legacy artifacts. The deferred cleanup helper remains on the card and is resolved by the Collector, so installation does not depend on copying it locally.
- `Collect-And-Remove/Collect-KeyHunter.ps1` — the installed copy waits for the `DUCKY` volume, validates both process identities, gracefully stops the agent and tray app via their shared stop flag, collects log + metadata into a timestamped folder on the card with a `COLLECT_COMPLETE.flag` marker, removes the Run value, schedules verified cleanup from `%TEMP%`, then resolves and invokes `duckyscripts/helpers/SafeEject.ps1` from the card. Local demo files are removed only after the Collector exits.
- `tests/Test-KeyHunter.ps1` — isolated end-to-end diagnostic. It starts a temporary copy, types `na1` into its own dedicated window, verifies ordinary key and character events, confirms a graceful stop, and deletes all temporary data. It does not install autostart.

Both payloads use a bounded result handshake: Scroll Lock means success, Caps Lock
means failure, and a 150-second timeout is also treated as failure. The original
host lock-key state is restored in every branch; failures stop the payload instead
of being displayed as successful completion.

The HID launcher is intentionally short and resilient. Installation uses one
chunked hidden command to reach the card. The bootstrap polls ready
filesystem drives through `System.IO.DriveInfo` every 100 ms instead of invoking
the blocking WMI `Win32_LogicalDisk` provider every 250 ms. This is important
when STORAGE is attached only after the hidden bootstrap has started: Windows
can announce the USB disk and FAT volume several seconds before a WMI query
returns its label. The typed command remains below the Windows Run dialog limit.
Collection types only the local
`KeyHunter-Collect.exe` path (about 60 characters); that launcher starts the local
Collector without an inline PowerShell command, `-Command`, or execution-policy
bypass. The Collector waits up to 90 seconds for the `DUCKY` volume itself.
The installer launcher uses 40 ms recovery gaps and up to 4 ms per-character
jitter after conservative Run-dialog focus delays. Neither payload types a long
second-stage command into an interactive console, so a late Explorer window
cannot steal that input.

## Log format
One JSON object per line in `%LOCALAPPDATA%\KeyHunter\demo-events.jsonl`.
Common fields: `timestamp`, `event`, `value`, `processId` (agent PID), `scope`,
`foregroundProcess`, `keyboardLayout`, `keyboardCulture`, `keyboardHandle`.

| event | meaning |
|---|---|
| `session_start` / `session_end` | agent lifecycle |
| `hook_installed` | WH_KEYBOARD_LL confirmed installed |
| `hook_rearmed` | periodic defensive re-registration of the hook (default every 300 seconds) |
| `key_down` / `key_up` | keyCode name, vkCode, scanCode, flags, injected flag, sysKey, modifiers (shift/control/alt) |
| `character` | text translated for the focused window's keyboard layout (`ToUnicodeEx`), incl. control tokens like `<ENTER>` |
| `dead_key` | a dead key was pressed; logged with vkCode + scanCode. The combining mark is layout-defined and intentionally not resolved to a code point, so no incorrect accents are written |
| `clipboard_paste` | clipboard text snapshot when Ctrl+V / Shift+Insert is pressed (capped at 4096 chars) |
| `keyboard_layout_changed` | focused window's layout changed |
| `foreground_changed` | focus moved to another process/window (also polled every ~500 ms while idle) |
| `agent_error` | internal error detail |

## How it stays reliable in the background
- The hook callback only snapshots and enqueues; all file I/O, registry lookups and JSON conversion happen in the message-pump drain loop, keeping the callback far below `LowLevelHooksTimeout` so Windows does not silently remove the hook.
- `ToUnicodeEx` and its mutable character buffer stay entirely in the C# interop layer. PowerShell receives only an immutable result object (`result`, `text`), avoiding the native-buffer lifetime boundary that previously could corrupt the PowerShell process heap.
- Each physical modifier key is tracked independently (per VK), seeded once at startup: releasing one of two held Shifts leaves `shift=true`, auto-repeat downs are idempotent, and AltGr — right Alt, which may arrive as RAlt, Ctrl+RShift or Ctrl+RAlt depending on layout/settings — is attributed correctly. Caps Lock is tracked from physical hook transitions rather than the agent thread's message-queue state, so translated characters remain consistent while another application has focus.
- Cross-process parameters (`-SkipInjected`) are declared as strings and parsed defensively in both installer and agent, so launching the agent can never fail on type binding.
- `PeekMessage` uses the full five-parameter signature with `PM_REMOVE`.
- The agent writes `agent.ready` only after the hook is confirmed installed (or `agent.error` on failure); the ready marker includes PID, process start time and script path. The installer waits for that marker instead of guessing, verifies the PID before sending the success signal, and cleans up all artifacts on failure.
- Windows may silently remove a timed-out low-level hook and exposes no status query for it. The agent therefore re-arms the hook periodically on its existing message-pump thread without injecting a probe key into the foreground application.

## Stop / remove
- Graceful: create `%LOCALAPPDATA%\KeyHunter\stop.flag` (the agent logs `session_end`; the tray app also exits), or run the collector script.
- The collector is preferred because it validates process identities before stopping them, removes the `KeyHunterTraining` Run value, and gathers the exercise artifacts before cleanup.

## Known limitations (by design)
- Captures physical key events only. IME composition results are not captured (IME input appears as its underlying key events). Pasted text is captured via the clipboard snapshot on Ctrl+V/Shift+Insert, not by reading target apps' buffers.
- Dead-key presses are logged as `dead_key` events without resolving the specific combining mark; composed text still renders normally in the target application.
- `-SkipInjected` (default on) filters software-injected keys (`LLKHF_INJECTED`, e.g. `SendInput`). True HID devices — including EvilKey itself — are not flagged injected, so their keystrokes are still logged; to keep a collector's own commands out of the log, stop the agent before doing further work (the collector does this).
- Per user session only; capturing keys in elevated windows requires running the agent elevated.
- The tray application is intentionally discoverable. It does not use a transparent icon, spoof another application, disable Defender, or add exclusions. Endpoint protection may still classify global keyboard-hook behavior as suspicious; use only on the designated training computer.
