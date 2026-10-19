# Firmware-only SD image for the Banana Pi BPI-F3 (SpacemiT K1): just the
# boot chain (BootROM -> FSBL -> OpenSBI -> U-Boot with UEFI), no OS.
#
# The blobs sit at the same raw sector offsets as in the NixOS SD image (see
# ../../modules/sd-image/sd-image-bpi-f3.nix); there is no partition table. The
# SPL's raw-offset fallback (u-boot patch 001) loads OpenSBI/U-Boot when no
# partitions are found, so it needs none. U-Boot then boots an OS from another
# device, including UEFI OS loaders (EFI/BOOT/BOOTRISCV64.EFI) via bootefi.
{
  lib,
  runCommand,
  bpi-f3-uboot-uefi,
  k1-opensbi,
}:

let
  # 16 MiB: the same gap the NixOS image leaves ahead of its first partition.
  imageSectors = 16 * 2048;

  # 512-byte sectors, matching Armbian's write_uboot_platform().
  blobs = [
    {
      file = "${bpi-f3-uboot-uefi}/bootinfo_emmc.bin";
      sector = 0;
    }
    {
      file = "${bpi-f3-uboot-uefi}/FSBL.bin";
      sector = 1;
    }
    {
      file = "${k1-opensbi}/fw_dynamic.itb";
      sector = 1280;
    }
    {
      file = "${bpi-f3-uboot-uefi}/u-boot.itb";
      sector = 2048;
    }
  ];
in
runCommand "nixos-bpi-f3-sd-image-uefi"
  {
    meta = {
      description = "Firmware-only SD image for the Banana Pi BPI-F3: OpenSBI + U-Boot with UEFI";
      platforms = [ "riscv64-linux" ];
    };
  }
  ''
    img=$out/sd-image/nixos-bpi-f3-sd-image-uefi.img
    mkdir -p $out/sd-image $out/nix-support

    # Each blob must end before the next one starts (the last one before the
    # end of the image).
    check_fits() {
      local size end
      size=$(stat -c %s "$1")
      end=$(( $2 * 512 + size ))
      if [ "$end" -gt $(( $3 * 512 )) ]; then
        echo "ERROR: $1 ($size bytes at sector $2) overruns sector $3" >&2
        exit 1
      fi
    }
    ${lib.concatStrings (
      lib.zipListsWith (a: b: ''
        check_fits ${a.file} ${toString a.sector} ${toString b.sector}
      '') blobs (lib.tail blobs ++ [ { sector = imageSectors; } ])
    )}

    truncate -s ${toString (imageSectors * 512)} $img
    ${lib.concatMapStrings (b: ''
      dd if=${b.file} of=$img bs=512 seek=${toString b.sector} conv=notrunc
    '') blobs}

    echo "file sd-image $img" >> $out/nix-support/hydra-build-products
  ''
