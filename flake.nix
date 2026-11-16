#
# Banana Pi F3 flake.nix
#
# Build (cross-compiled x86_64 -> riscv64):
#   nix build .#usbImage    # NixOS on a UEFI USB drive (default target; ./result/usb-image/*.img)
#   nix build .#sdImageUefi # firmware-only SD card: boot blobs + U-Boot with UEFI, no OS
#   nix build .#uboot       # U-Boot blobs: FSBL.bin, bootinfo_emmc.bin, u-boot.itb
#   nix build .#opensbi     # OpenSBI fw_dynamic.itb
#   nix flake check         # eval the config + treefmt + statix
#   nix fmt                 # format the tree (nixfmt + deadnix; prettier for *.md)
#
# Flash (replace /dev/sdX / /dev/sdY with your SD card / USB drive!):
# sudo dd if=$(readlink -f result-uefi/sd-image/*.img) of=/dev/sdX bs=4M conv=fsync status=progress
# sudo dd if=$(readlink -f result/usb-image/*.img) of=/dev/sdY bs=4M conv=fsync status=progress
#
{
  description = "NixOS for the Banana Pi BPI-F3 (SpacemiT K1, RISC-V), cross-compiled from x86_64";

  inputs = {
    nixpkgs.url = "https://channels.cyberus-linux.com/channel/cyberus-linux-26.05.tar.xz";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Bootloader sources (non-flake), pinned via flake.lock.
    #
    # U-Boot is Armbian's fork + its patch set (see nix/pkgs/u-boot): the stock
    # vendor U-Boot can't extlinux-boot a generic distro, this can.
    uboot-spacemit = {
      url = "github:pyavitz/spacemit-u-boot/k1-bl-v2.2.9-release";
      flake = false;
    };
    # SpacemiT vendor OpenSBI (gitee), tag k1-bl-v2.2.10-release.
    opensbi-spacemit = {
      url = "git+https://gitee.com/spacemit-buildroot/opensbi.git?ref=k1-bl-v2.2.y&rev=34143f5f665be8b86ebb71b8085a1ade7f8b97ad";
      flake = false;
    };
  };

  outputs =
    inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      let
        overlay = import ./nix/overlay.nix inputs;

        # Cross pkgset: build host x86_64-linux -> target riscv64, with the
        # bootloader overlay. Built once and shared, so the overlay + crossSystem
        # are never applied twice.
        pkgsCross = import nixpkgs {
          localSystem = "x86_64-linux";
          crossSystem = import ./nix/cross.nix;
          overlays = [ overlay ];
        };

        usbImage = inputs.self.nixosConfigurations.bpi-f3-usb.config.system.build.usbImage;
      in
      {
        systems = [ "x86_64-linux" ];
        imports = [ inputs.treefmt-nix.flakeModule ];

        flake = {
          overlays.default = overlay;

          # USB-drive system: plain UEFI disk (ESP with systemd-boot + root),
          # booted by the firmware-only SD card (sdImageUefi). On-device
          # `nixos-rebuild`s target this configuration.
          nixosConfigurations.bpi-f3-usb = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              { nixpkgs.pkgs = pkgsCross; }
              ./nix/modules
            ];
          };
        };

        perSystem =
          { pkgs, ... }:
          {
            packages = {
              default = usbImage;
              inherit usbImage;
              sdImageUefi = pkgsCross.bpi-f3-sd-image-uefi;
              uboot = pkgsCross.bpi-f3-uboot;
              opensbi = pkgsCross.k1-opensbi;
            };

            # `nix fmt` + `nix flake check`'s formatting gate (nixfmt-rfc-style + deadnix).
            # prettier reflows Markdown prose (proseWrap=never -> let the renderer
            # soft-wrap; no hard line breaks). Scoped to *.md so it never touches
            # flake.lock or other files.
            treefmt = {
              projectRootFile = "flake.nix";
              programs = {
                nixfmt.enable = true;
                deadnix.enable = true;
                prettier = {
                  enable = true;
                  includes = [ "*.md" ];
                  settings.proseWrap = "never";
                };
              };
            };

            # `nix flake check` lint gate.
            checks.statix = pkgs.runCommandLocal "statix-check" { nativeBuildInputs = [ pkgs.statix ]; } ''
              statix check "${inputs.self}"
              touch "$out"
            '';

            devShells.default = pkgs.mkShellNoCC {
              packages = with pkgs; [
                nixfmt
                deadnix
                statix
                dtc
                nix-output-monitor
              ];
            };
          };
      }
    );
}
