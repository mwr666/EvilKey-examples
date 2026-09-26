# EvilKey microSD examples

This repository contains original EvilKey scripts in this directory. Copy its
`duckyscripts/` tree to the root of a microSD card, then
edit each example's configuration and follow its own README before use. Run
security-testing examples only on systems you are authorized to test.

The private working project retains four folders with third-party author or
derivation notices. They are excluded from this public repository and are not
covered by [EvilKey microSD Examples License 1.0](LICENSE.md). Obtain separate
permission or use another lawful distribution basis before publishing those
adapted payloads.

The separately analyzed Hak5 compatibility repository is not included.

## Tested Windows demo

[`duckyscripts/test/hello_world.duck`](duckyscripts/test/hello_world.duck) is a
Windows-only USB Tool demonstration, physically tested by the project owner.
After you select it and press **RUN** on EvilKey, it minimizes open windows,
opens Notepad, creates a new document and types:

```text
YOU HAVE BEEN HACKED
Relax. This key only opened Notepad.
The only data stolen was your attention.
```

Save your work before running it on your own unlocked computer. The script does
not run when the device is connected or the card is mounted. Copy the
`duckyscripts/` tree to the card, safely eject it, enter USB Tool, select the
script, then press **RUN**. This demo reads no host files and sends no data over
the network.
