param(
    [string]$DriveLabel = 'DUCKY',
    [switch]$DryRun,
    [switch]$SignalScrollLock
)

$ErrorActionPreference = 'Stop'

$disk = Get-CimInstance -ClassName Win32_LogicalDisk |
    Where-Object { $_.VolumeName -eq $DriveLabel } |
    Select-Object -First 1

if (-not $disk) {
    throw "Could not find a mounted volume labelled '$DriveLabel'."
}

$driveLetter = [char]$disk.DeviceID[0]

# Leave the removable volume before locking it. Write-VolumeCache is the
# documented Windows filesystem-cache barrier, but Windows does not guarantee
# that it becomes an observable SCSI SYNCHRONIZE CACHE command for this MSC
# profile. The subsequent safe-eject IOCTL is therefore the authoritative host
# completion signal consumed by PicoFIDO.
Set-Location -LiteralPath $env:SystemRoot
Write-VolumeCache -DriveLetter $driveLetter -ErrorAction Stop | Out-Null

if ($DryRun) {
    Write-Output "Flushed $driveLetter`: ($DriveLabel); eject skipped."
    exit 0
}

if (-not ('PicoFidoSafeRemovalR36' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class PicoFidoSafeRemovalR36 {
    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;
    private const uint FSCTL_LOCK_VOLUME = 0x00090018;
    private const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;
    private const uint IOCTL_STORAGE_EJECT_MEDIA = 0x002D4808;
    private const byte VK_SCROLL = 0x91;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string path, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        SafeFileHandle device, uint controlCode,
        IntPtr input, uint inputSize, IntPtr output, uint outputSize,
        out uint bytesReturned, IntPtr overlapped);

    [DllImport("user32.dll")]
    private static extern void keybd_event(
        byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    public static int Eject(char driveLetter) {
        using (SafeFileHandle volume = CreateFileW(
            @"\\.\" + driveLetter + ":",
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero)) {
            if (volume.IsInvalid) return Marshal.GetLastWin32Error();

            uint bytes;
            if (!DeviceIoControl(volume, FSCTL_LOCK_VOLUME,
                    IntPtr.Zero, 0, IntPtr.Zero, 0, out bytes, IntPtr.Zero))
                return Marshal.GetLastWin32Error();
            if (!DeviceIoControl(volume, FSCTL_DISMOUNT_VOLUME,
                    IntPtr.Zero, 0, IntPtr.Zero, 0, out bytes, IntPtr.Zero))
                return Marshal.GetLastWin32Error();
            if (!DeviceIoControl(volume, IOCTL_STORAGE_EJECT_MEDIA,
                    IntPtr.Zero, 0, IntPtr.Zero, 0, out bytes, IntPtr.Zero))
                return Marshal.GetLastWin32Error();
            return 0;
        }
    }

    public static void SignalScrollLock() {
        keybd_event(VK_SCROLL, 0, 0, UIntPtr.Zero);
        keybd_event(VK_SCROLL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
}
'@
}

$result = [PicoFidoSafeRemovalR36]::Eject($driveLetter)
if ($result -ne 0) {
    throw "Safe eject of $driveLetter`: failed with Win32 error $result."
}

if ($SignalScrollLock) {
    # Let USB/HID settle after the host eject request. The lock-state signal is
    # a completion handshake for a DuckyScript WAIT_FOR_SCROLL_CHANGE and is
    # never emitted when flush or eject fails.
    Start-Sleep -Milliseconds 750
    [PicoFidoSafeRemovalR36]::SignalScrollLock()
}

$suffix = if ($SignalScrollLock) { ' and signalled Scroll Lock' } else { '' }
Write-Output "Flushed and safely ejected $driveLetter`: ($DriveLabel)$suffix."
