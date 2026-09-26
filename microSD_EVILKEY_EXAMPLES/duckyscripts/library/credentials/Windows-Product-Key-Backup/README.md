# Windows Product Key Backup — EvilKey

This local inventory payload records the full Windows OEM key through Keystroke Reflection in `loot.bin` and `loot.idx`. It does not use Discord, a network connection, or STORAGE, and it does not change Microsoft Defender settings or PowerShell history.

## Output

A key that was found uses a compact ASCII record:

```text
WPK1|COMPUTER-NAME|OEM-LICENSE-DESCRIPTION|XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
```

Other statuses:

```text
N|COMPUTER-NAME|DIGITAL_LICENSE_NO_EXPORTABLE_KEY
E|COMPUTER-NAME|0x........
```

`N` means `SoftwareLicensingService` did not expose an OA3 key stored in firmware. This is normal for some digital and retail licenses. The payload does not try to recover a generic installation key from the registry.

## Use

1. Run the payload on a computer whose license you are authorized to inventory.
2. Confirm Keystroke Reflection on the EvilKey screen.
3. After completion, expose the card and open the matching `loot.bin` and `loot.idx` files in EvilKey Manager.
4. Move the full key to an encrypted recovery archive, then delete the two loot files from the card.

The payload does not require UAC. The full key in `loot.bin` is a license secret and should be protected like other recovery data.
