# nixos-bpi-f3

NixOS for the [Banana Pi BPI-F3](https://docs.banana-pi.org/en/BPI-F3/BananaPi_BPI-F3) — an octa-core [SpacemiT K1](https://www.spacemit.com/en/key1/) RISC-V SBC (RVA22 + RVV 1.0).

This flake **cross-compiles** from an `x86_64` host to `riscv64` and produces two images:

- **`sdImageUefi`** — a firmware-only SD card: the SpacemiT boot chain (U-Boot 2022.10 + OpenSBI, built from source) with UEFI enabled, and no OS. The board's BootROM can only load firmware from SD/eMMC, so this card stays in the slot.
- **`usbImage`** — headless NixOS on a USB drive, as a plain UEFI disk (GPT, ESP with systemd-boot, ext4 root) with no board firmware on it.

The bootloader is Armbian's U-Boot fork (`pyavitz/spacemit-u-boot`) plus its patch set and two of ours; OpenSBI is the SpacemiT gitee tree. There is no turnkey NixOS image for this board upstream — this is a "roll your own" build, adapted from [nixos-licheepi4a](https://github.com/randomizedcoder/nixos-licheepi4a).

**Status:** the firmware card + USB drive booted to the login prompt on real hardware with Linux 7.0.12, and the root filesystem grew to fill the drive. The flake now tracks `linuxPackages_latest` (7.3.4), which has not been booted on the board yet. Earlier versions of this repo also had an SD-root NixOS image with root-on-NVMe migration; see the git history and [`PROGRESS.md`](./PROGRESS.md).

## Quick start

You build on an **`x86_64-linux`** machine; the flake cross-compiles to `riscv64` automatically (it sets `nixpkgs.crossSystem`), so there is nothing special to configure — just `nix build`.

**Prerequisites**

- Nix with flakes enabled. Either use `--extra-experimental-features 'nix-command flakes'` on each command, or add to `~/.config/nix/nix.conf` (or `/etc/nix/nix.conf`):
  ```
  experimental-features = nix-command flakes
  ```
- A fast x86_64 builder with plenty of disk/RAM. Because we target `rv64gcv` (see Scope), the build gets **no** binary-cache hits and compiles the cross toolchain + the whole closure from source — budget a long first build (hours, not minutes) and tens of GB of store.

**Clone, build, flash**

```sh
# 1. Clone
git clone https://github.com/randomizedcoder/nixos-bpi-f3.git
cd nixos-bpi-f3

# 2. Cross-compile both images (runs on x86_64, produces riscv64 images).
#    Tip: add `--log-format internal-json -v |& nom` (nix-output-monitor) to watch progress.
nix build .#sdImageUefi -o result-uefi
nix build .#usbImage

# 3. Flash the firmware to an SD card and NixOS to a USB drive.
lsblk                                   # find the devices (NOT partitions)
sudo dd if=result-uefi/sd-image/nixos-bpi-f3-sd-image-uefi.img \
        of=/dev/sdX bs=4M conv=fsync status=progress
sudo dd if=result/usb-image/nixos-bpi-f3-usb-image-*.img \
        of=/dev/sdY bs=4M conv=fsync status=progress

# 4. Insert both, connect a USB-UART (115200 8N1), power on, and log in as bpi / bpi-f3.
```

> First time on RISC-V Nix? You don't need a riscv64 machine or QEMU — cross-compilation does it all on x86_64. If a build step is too slow locally, point Nix at a beefier [remote builder](https://nix.dev/manual/nix/stable/advanced-topics/distributed-builds).

## Scope

- **Headless, mainline kernel.** Uses nixpkgs' `linuxPackages_latest` with the in-tree `k1-bananapi-f3` device tree (which has the SD slot, eMMC, Ethernet, USB and PCIe) and the K1 drivers forced on.
- **No GPU / NPU.** The IMG BXE GPU and the AI accelerator only work on the vendor (Bianbu) kernel. If you need them, you'll have to package that kernel — out of scope here.
- **ISA baseline `rv64gcv` (RVV 1.0 enabled).** The K1's X60 cores implement RVV 1.0. Note this diverges from the riscv64 community binary caches (which target `rv64gc`), so **the whole closure is built locally** — the first build is long and gets no cache hits. Build it on a fast machine.

## Repository layout

`flake.nix` (flake-parts) is intentionally thin; everything substantive is a module/derivation under `nix/`:

```
flake.nix                              # flake-parts: inputs + perSystem (packages/formatter/checks/devShell)
nix/
  cross.nix                            # cross target: riscv64, rv64gcv / lp64d
  overlay.nix                          # exposes the bootloader packages + the firmware image
  modules/                             # nixosConfigurations.bpi-f3-usb
    default.nix                        # aggregator
    kernel.nix                         # kernel package + forced K1 Kconfig + initrd
    hardware.nix                       # device tree + firmware
    base.nix                           # console/getty, ssh, packages, nix settings, stateVersion
    user-group.nix                     # default user / hostname
    usb-image.nix                      # systemd-boot, filesystems, first boot, image build
  pkgs/
    u-boot/default.nix                 # Armbian U-Boot fork + UEFI -> FSBL.bin, bootinfo_emmc.bin, u-boot.itb
    u-boot/patches/                    # Armbian's patch set (vendored, 001-009) + ours (010, 011)
    opensbi/default.nix                # vendor OpenSBI -> fw_dynamic.itb
    sd-image-uefi/default.nix          # firmware-only SD image
```

## Development

```sh
nix fmt           # format (treefmt: nixfmt + deadnix; prettier for *.md)
nix flake check   # eval + formatting + statix lint gate
nix develop       # shell with nixfmt, deadnix, statix, dtc, nix-output-monitor
```

## Build outputs

```sh
nix build .#usbImage     # default; NixOS USB drive -> result/usb-image/*.img (uncompressed)
nix build .#sdImageUefi  # firmware-only SD card -> result/sd-image/*.img (16 MiB)
nix build .#uboot        # bootloader only: FSBL.bin, bootinfo_emmc.bin, u-boot.itb
nix build .#opensbi      # OpenSBI only: fw_dynamic.itb
```

Building `.#uboot` / `.#opensbi` on their own is handy when iterating on the vendor bootloader build without rebuilding the kernel and rootfs.

## Boot flow

BootROM → FSBL (SPL) → OpenSBI → U-Boot (all from the SD card) → systemd-boot (USB drive) → Linux.

### Firmware SD card (`sdImageUefi`)

The SpacemiT BootROM reads a small boot-info header at sector 0, then chains through the FSBL (SPL), OpenSBI and U-Boot. They live at fixed raw sector offsets (matching Armbian's `write_uboot_platform`); the card has no partition table:

| Artifact                     | Sector | Byte offset | Source      |
| ---------------------------- | ------ | ----------- | ----------- |
| `bootinfo_emmc.bin`          | 0      | `0x0`       | `.#uboot`   |
| `FSBL.bin` (SPL)             | 1      | `0x200`     | `.#uboot`   |
| `fw_dynamic.itb` (OpenSBI)   | 1280   | `0x140000`  | `.#opensbi` |
| `u-boot.itb` (U-Boot proper) | 2048   | `0x200000`  | `.#uboot`   |

With no partitions on the card, the SPL falls back to these raw offsets (patch `001`). U-Boot has UEFI explicitly enabled (`bootefi`, the EFI boot manager, `efidebug`). Its boot script tries the SD card, then the first USB drive (patch `011`), then the NVMe — partition 1 each — and runs `EFI/BOOT/BOOTRISCV64.EFI` if there is no `extlinux.conf`/`boot.scr`. If the ESP has `spacemit/k1-bananapi-f3.dtb` under `/`, `/dtb/` or `/dtb/current/`, `bootefi` passes that device tree (patch `010`); otherwise it falls back to U-Boot's own vendor device tree, which mainline kernels don't expect.

If you add partitions to the card yourself, use an MBR table starting at ≥16 MiB: a GPT's primary header lives at sector 1, exactly where `FSBL.bin` is, while MBR keeps everything in sector 0 (the ~80-byte `bootinfo_emmc.bin` fits before the table at byte 446). Armbian uses MBR for this board for the same reason.

### NixOS USB drive (`usbImage`)

| Part | Filesystem | Label | Contents |
| --- | --- | --- | --- |
| 1 | FAT32 | `ESP` | systemd-boot, loader entries, kernel, initrd, DTB |
| 2 | ext4 | `NIXOS_USB` | root filesystem (registers the store + grows on first boot) |

systemd-boot passes the generation's device tree to the kernel through its `devicetree` entry. On-device `nixos-rebuild switch` updates the ESP as on any UEFI NixOS (`nixosConfigurations.bpi-f3-usb`). UEFI variables aren't persistent under U-Boot, so the system never writes them.

## Serial console

Connect a 3.3 V USB-UART to the F3's debug UART header and open it at **115200 8N1**:

```sh
picocom -b 115200 /dev/ttyUSB0         # recommended
```

Kernel console is `ttyS0,115200`, with `earlycon=uart8250,mmio32,0xd4017000` for output from the very first boot stage (`earlycon=sbi` produced nothing on this board).

> Gotcha: **minicom** may silently _not_ apply the baud rate, showing a screen of garbage that looks like a hardware fault. Prefer `picocom`, or capture raw with `stty -F /dev/ttyUSB0 115200 raw -echo; cat /dev/ttyUSB0`.

## Default login

- user: **`bpi`**
- password: **`bpi-f3`**

Change these in `nix/modules/user-group.nix` (regenerate the hash with `mkpasswd -m yescrypt`) before putting the board on an untrusted network.

## First boot

The board's RTC isn't persisted, so the clock starts behind (around the image build date). Until `systemd-timesyncd` syncs over the network, TLS fails — `nix-shell`, channel fetches, etc. error with _"certificate is not yet valid or the system clock is incorrect"_. Wait a few seconds after the NIC comes up, or nudge it:

```sh
timedatectl                              # want 'System clock synchronized: yes'
sudo systemctl restart systemd-timesyncd
```

## Challenges worked around

Recorded here (and in [`PROGRESS.md`](./PROGRESS.md)) so the config's quirks make sense to whoever reads it next:

- **OpenSBI vs GCC 15 / C23** — the vendor tree has `typedef int bool;`, which GCC 15 (defaulting to `-std=c23`, where `bool` is a keyword) rejects under `-Werror`. Built with `platform-cflags-y=-std=gnu17`.
- **U-Boot fork + patch set** — stock vendor U-Boot's SPL loads OpenSBI/U-Boot only from GPT partitions _named_ `opensbi`/`uboot`, and boots via bespoke env scripts. We build **Armbian's fork** (`pyavitz/spacemit-u-boot`) + its patches: `001` adds the raw-offset SPL fallback (`0x500`/`0x800` = sectors 1280/2048), `002`/`004` add the MMC boot target + the extlinux/boot.scr/EFI boot script.
- **`bootefi` and the device tree** — without an FDT argument, `bootefi` hands the OS U-Boot's own vendor device tree. Patch `010` loads the mainline one from the ESP when present; systemd-boot's `devicetree` entry replaces it in any case.
- **No USB in the boot order** — the vendor boot script only tried the SD card and the NVMe. Patch `011` adds the first USB drive between them.
- **Cross-built UEFI disk** — the image is assembled without a VM, so the ESP is populated the way NixOS's systemd-boot builder would, and the first-boot script registers the store _before_ the best-effort resize (a failed resize must never leave the store unregistered).
- **"Garbled serial"** — minicom silently didn't apply 115200, and `earlycon=sbi` produced nothing; using `picocom` + `earlycon=uart8250,mmio32,0xd4017000` gave clean early output.

## Limitations

This is a **mainline, headless** build — we did **not** do the vendor "custom work" (the closed-driver integration that the Bianbu vendor kernel ships):

- **No display / GPU** (IMG BXE) and **no NPU / AI accelerator.** These only work on the vendor (Bianbu) kernel with proprietary drivers; not attempted here. This board is headless/server/dev-box only.
- **The SD card must stay inserted** — it carries the firmware; the BootROM can't load it from USB or NVMe.
- **Only the first USB storage device** (partition 1) is tried by U-Boot.
- **Wi-Fi** — the on-board chip (e.g. `8852bs`) needs an out-of-tree driver; not included.
- **RTC** is not persisted across power cycles — the clock relies on NTP (see [First boot](#first-boot)).
- **Binary caches** — targeting `rv64gcv` diverges from the riscv64 community caches, so there are no cache hits; the first build compiles the whole closure locally.

## References

- BPI-F3 docs: <https://docs.banana-pi.org/en/BPI-F3/BananaPi_BPI-F3>
- U-Boot fork we build (Armbian's): <https://github.com/pyavitz/spacemit-u-boot> (tag `k1-bl-v2.2.9-release`)
- SpacemiT OpenSBI: <https://gitee.com/spacemit-buildroot/opensbi>
- Armbian (BPI-F3 board + spacemit family configs + U-Boot patches): <https://github.com/BPI-SINOVOIP/armbian-build>
- Base flake (Lichee Pi 4A): <https://github.com/randomizedcoder/nixos-licheepi4a>

See [`IMPLEMENTATION.md`](./IMPLEMENTATION.md) for the original design and [`PROGRESS.md`](./PROGRESS.md) for the history.
