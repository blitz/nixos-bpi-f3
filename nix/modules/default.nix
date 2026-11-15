# NixOS for the Banana Pi BPI-F3 (SpacemiT K1, RISC-V) on a UEFI USB drive.
#
# Headless mainline target: a recent nixpkgs kernel with the in-tree
# k1-bananapi-f3 device tree and the SpacemiT K1 drivers forced on. No GPU/NPU
# (vendor-kernel only). Boots via the firmware-only SD card (.#sdImageUefi).
{
  imports = [
    ./kernel.nix
    ./hardware.nix
    ./base.nix
    ./user-group.nix
    ./usb-image.nix
  ];
}
