<p align="center">
  <img src="docs/github/hero-lvgl.png" alt="EvilKey microSD examples" width="100%">
</p>

<p align="center">
  <a href="https://github.com/mwr666/EvilKey-firmware">Firmware and device GUI</a> ·
  <a href="https://github.com/mwr666/EvilKey-Manager">Windows Manager</a> ·
  <strong>microSD examples</strong> ·
  <a href="https://hackaday.io/project/206807-evilkey-i-needed-a-fido2-key-then-the-maker-brain-took-over">Hackaday project</a> ·
  <a href="https://www.printables.com/model/1855790-evilkey-v1-enclosure-waveshare-esp32-s3-touch-amol">Printable V1 enclosure</a>
</p>

<p align="center">
  <img src="docs/github/evilkey-lvgl-logo-motion.webp" alt="Animated EvilKey logo with the device screensaver glitch" width="128">
</p>

# EvilKey microSD examples

Original sample scripts for the EvilKey USB Tool. Copy the `microSD_EVILKEY_EXAMPLES/duckyscripts/` tree to the root of a microSD card and read each example's instructions before use. Some examples handle credentials or input events; run them only on systems you own or are explicitly authorized to test, and use synthetic data when learning or demonstrating them.

**Start here:** [hello_world.duck](microSD_EVILKEY_EXAMPLES/duckyscripts/test/hello_world.duck) is a physically tested Windows demo. Select it in USB Tool and press **RUN** to open Notepad and type a harmless three-line joke. [Copy and test instructions](microSD_EVILKEY_EXAMPLES/README.md#tested-windows-demo).

<p align="center"><a href="https://cdn.hackaday.io/files/2068078848030688/evilkey-usb-tool-hello-world-real-silent.mp4"><img src="https://raw.githubusercontent.com/mwr666/EvilKey-firmware/main/docs/github/evilkey-usb-tool-demo-poster.jpg" alt="Play hello_world.duck on a real EvilKey and Windows PC" width="420"></a></p>

[▶ Watch the silent 37-second physical demo](https://cdn.hackaday.io/files/2068078848030688/evilkey-usb-tool-hello-world-real-silent.mp4). The edit joins two real camera takes; captions and the logo outro are editorial. The payload starts only when selected on the key and **RUN** is pressed.

## Hardware for the PCB V1 USB Tool demo

| Quantity | Component |
| --- | --- |
| 1 | Waveshare ESP32-S3 Touch AMOLED 1.64, **PCB V1** |
| 1 | Short data-capable USB-C cable/loop (Unitek C14179ABK-style in the prototype) |
| 1 | Printed V1 enclosure (the current prototype is home printed) |
| 4 | M2 × 5 mm screws for the module |
| 1 | M5 × 10 mm flat-point grub screw for the cable loop |
| 1 | **FAT32-formatted microSD card** for USB Tool scripts |

The microSD card is needed to reproduce `hello_world.duck`; FIDO2 and Air Mouse work without it. Copy this repository's `microSD_EVILKEY_EXAMPLES/duckyscripts/` tree to the card root; the tested script is `/duckyscripts/test/hello_world.duck`. Card capacity is not specified. See the [Hackaday component list](https://hackaday.io/project/206807/components) and [build instructions](https://hackaday.io/project/206807/instructions).

The separate Hak5 payload collection is not included. Four locally retained examples with third-party authorship or derivation notices are also excluded pending a separate rights review. See [package details](microSD_EVILKEY_EXAMPLES/README.md) and the [license](LICENSE.md).

[▶ Watch the real EvilKey device GUI](https://cdn.hackaday.io/files/2068078848030688/evilkey-gui-real-silent.mp4) — silent camera footage of the touchscreen in use on the prototype.

## Related projects

- [EvilKey firmware](https://github.com/mwr666/EvilKey-firmware) — open AGPLv3 firmware and USB Tool implementation.
- [EvilKey Manager](https://github.com/mwr666/EvilKey-Manager) — Windows device controls and offline USB Tool data decoding under separate noncommercial terms.
- [Printable V1 enclosure](https://www.printables.com/model/1855790-evilkey-v1-enclosure-waveshare-esp32-s3-touch-amol) — digital STL and 3MF case files for the Waveshare PCB V1, sold separately on Printables.

I welcome ideas for clear, testable examples that demonstrate useful EvilKey behavior without relying on third-party payload collections.

Voluntary support is available through [GitHub Sponsors](https://github.com/sponsors/mwr666). Sponsorship is not a software purchase or a kit preorder.

## License

Original EvilKey examples are source available for private noncommercial use under [EvilKey microSD Examples License](LICENSE.md). Commercial use requires separate written permission from Michał Wojciechowski. Independently licensed material retains its own terms; the license does not cover outside script libraries.
