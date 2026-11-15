# UEFI USB-drive image for the Banana Pi BPI-F3 (SpacemiT K1).
#
# A plain UEFI disk with no board firmware on it: the board boots from the
# firmware-only SD card (`.#sdImageUefi`), whose U-Boot finds the drive's
# EFI/BOOT/BOOTRISCV64.EFI (u-boot patch 011) and starts systemd-boot from it.
#
# Layout (GPT; only the firmware card needs MBR, because of its raw boot blobs):
#   1  ESP   FAT32  systemd-boot, loader entries, kernel, initrd, DTB
#   2  ext4  NIXOS_USB  root filesystem (expands to fill the drive on first boot)
#
# The image is assembled without a VM (cross-compiled), so the ESP is
# populated by hand here the way NixOS's systemd-boot builder lays it out;
# the first on-device `nixos-rebuild` takes it over from there.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  efiArch = pkgs.stdenv.hostPlatform.efiArch;
  sdBoot = "${config.systemd.package}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
  sdbCfg = config.boot.loader.systemd-boot;

  espLabel = "ESP";
  rootLabel = "NIXOS_USB";
  espSizeMiB = 1024;

  kernel = "${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile}";
  initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
  dtb = "${config.hardware.deviceTree.package}/${config.hardware.deviceTree.name}";

  rootfsImage = pkgs.callPackage "${modulesPath}/../lib/make-ext4-fs.nix" {
    storePaths = [ config.system.build.toplevel ];
    compressImage = false;
    populateImageCommands = ''
      mkdir -p ./files/boot
    '';
    volumeLabel = rootLabel;
  };
in
{
  boot = {
    loader = {
      grub.enable = false;
      systemd-boot = {
        enable = true;
        # Keeps the ESP from filling up with old kernels.
        configurationLimit = 20;
      };
      # U-Boot's UEFI variables are not persistent; never try to write them.
      efi.canTouchEfiVariables = false;
    };

    kernelParams = [
      # Direct UART0 earlycon (0xd4017000, reg-shift=2/io-width=4 -> mmio32).
      # Prints from the very start; earlycon=sbi produced nothing on this board.
      "earlycon=uart8250,mmio32,0xd4017000"
      "console=ttyS0,115200"
      "rootwait"
      "rw"
    ];
  };

  fileSystems = {
    "/boot" = {
      device = "/dev/disk/by-label/${espLabel}";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };
    "/" = {
      device = "/dev/disk/by-label/${rootLabel}";
      fsType = "ext4";
    };
  };

  # First boot: register the shipped Nix store, then grow the root partition
  # to fill the drive. Registration comes first and the resize is best-effort,
  # so a failed resize can never leave the store unregistered (which breaks
  # nixos-rebuild much later with a baffling "no substituter" error). The
  # backup GPT header is moved to the end of the (larger) drive before
  # partition 2 is grown.
  boot.postBootCommands = ''
    if [ -f /nix-path-registration ]; then
      set -euo pipefail
      set -x

      ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration
      touch /etc/NIXOS
      ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system

      rootPart=$(${pkgs.util-linux}/bin/findmnt -n -o SOURCE /)
      bootDevice=$(${pkgs.util-linux}/bin/lsblk -npo PKNAME "$rootPart")
      partNum=$(cat "/sys/class/block/$(basename "$rootPart")/partition")
      if ${pkgs.util-linux}/bin/sfdisk --relocate gpt-bak-std "$bootDevice" \
        && echo ",+," | ${pkgs.util-linux}/bin/sfdisk -N"$partNum" --no-reread "$bootDevice" \
        && ${pkgs.parted}/bin/partprobe \
        && ${pkgs.e2fsprogs}/bin/resize2fs "$rootPart"; then
        echo "root filesystem resized to fill the drive."
      else
        echo "warning: root partition resize failed; continuing (store is registered)."
      fi

      rm -f /nix-path-registration
    fi
  '';

  system.build.usbImage = pkgs.callPackage (
    {
      stdenv,
      dosfstools,
      e2fsprogs,
      mtools,
      libfaketime,
      util-linux,
    }:
    stdenv.mkDerivation {
      name = "nixos-bpi-f3-usb-image-${config.system.nixos.label}";

      nativeBuildInputs = [
        dosfstools
        e2fsprogs
        libfaketime
        mtools
        util-linux
      ];

      buildCommand = ''
        mkdir -p $out/nix-support $out/usb-image
        img=$out/usb-image/nixos-bpi-f3-usb-image-${config.system.nixos.label}.img
        echo "file usb-image $img" >> $out/nix-support/hydra-build-products

        # --- ESP contents, laid out like systemd-boot-builder.py does ---
        # Boot files are named <store dir>-<file>.efi under EFI/nixos, so the
        # builder recognises (and later garbage-collects) them.
        bootName() {
          local p sub
          p=$(readlink -f "$1")
          sub=''${p#${builtins.storeDir}/}
          sub=''${sub%%/*}
          echo "EFI/nixos/$sub-$(basename "$p").efi"
        }
        kernel=$(bootName ${kernel})
        initrd=$(bootName ${initrd})
        dtb=$(bootName ${dtb})

        mkdir -p esp/EFI/BOOT esp/EFI/systemd esp/EFI/nixos esp/loader/entries
        # Removable-media path (what U-Boot runs) + bootctl's own install path.
        cp ${sdBoot} esp/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI
        cp ${sdBoot} esp/EFI/systemd/systemd-boot${efiArch}.efi
        cp ${kernel} esp/$kernel
        cp ${initrd} esp/$initrd
        cp ${dtb} esp/$dtb

        cat > esp/loader/loader.conf <<EOF
        timeout ${toString config.boot.loader.timeout}
        default nixos-*
        ${lib.optionalString (!sdbCfg.editor) "editor 0"}
        console-mode ${sdbCfg.consoleMode}
        EOF

        cat > esp/loader/entries/nixos-generation-1.conf <<EOF
        title NixOS
        version Generation 1 ${config.system.nixos.label}
        linux /$kernel
        initrd /$initrd
        options init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams}
        devicetree /$dtb
        sort-key ${sdbCfg.sortKey}
        EOF

        # --- Disk image: 1 MiB GPT gap, ESP, root (+ slack for alignment and
        # the backup GPT) ---
        rootBytes=$(stat -c %s ${rootfsImage})
        espBytes=$((${toString espSizeMiB} * 1024 * 1024))
        truncate -s $((1024 * 1024 + espBytes + rootBytes + 4 * 1024 * 1024)) $img

        sfdisk $img <<EOF
        label: gpt
        unit: sectors

        start=2048, size=$((espBytes / 512)), type=U, name=ESP
        type=L, name=nixos
        EOF

        # Root filesystem into partition 2.
        eval $(partx $img -o START,SECTORS --nr 2 --pairs)
        if [ $((SECTORS * 512)) -lt "$rootBytes" ]; then
          echo "ERROR: root partition ($SECTORS sectors) smaller than rootfs ($rootBytes bytes)" >&2
          exit 1
        fi
        fsck.ext4 -vn ${rootfsImage}
        dd conv=notrunc if=${rootfsImage} of=$img bs=512 seek=$START

        # FAT32 ESP into partition 1.
        eval $(partx $img -o START,SECTORS --nr 1 --pairs)
        truncate -s $((SECTORS * 512)) esp.img
        mkfs.vfat -F 32 -n ${espLabel} esp.img
        find esp -exec touch --date=2000-01-01 {} +
        cd esp
        for d in $(find . -type d -mindepth 1 | sort); do
          faketime "2000-01-01 00:00:00" mmd -i ../esp.img "::/$d"
        done
        for f in $(find . -type f | sort); do
          mcopy -pvm -i ../esp.img "$f" "::/$f"
        done
        cd ..
        fsck.vfat -vn esp.img
        dd conv=notrunc if=esp.img of=$img bs=512 seek=$START
      '';
    }
  ) { };
}
