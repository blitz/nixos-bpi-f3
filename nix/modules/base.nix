# Base headless system config for the Banana Pi BPI-F3.
{
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  # Keep the closure small: no documentation (NixOS manual, man/info pages),
  # no default packages (perl, rsync, strace), no XDG/desktop data.
  imports = [ "${modulesPath}/profiles/minimal.nix" ];

  # No installer tooling; this system is flashed as an image, not installed.
  # nixos-rebuild stays for on-device rebuilds.
  system.tools = {
    nixos-build-vms.enable = false;
    nixos-enter.enable = false;
    nixos-generate-config.enable = false;
    nixos-install.enable = false;
    nixos-option.enable = false;
  };

  # Plain GPT + ext4/vfat: no bcache (LVM is off below).
  boot.bcache.enable = false;

  # Headless: serial is the primary console; disable the hvc0 getty that some
  # RISC-V profiles enable.
  systemd.services."serial-getty@hvc0".enable = false;

  services = {
    lvm.enable = false;

    openssh = {
      enable = lib.mkDefault true;
      settings.PasswordAuthentication = lib.mkDefault true;
      openFirewall = lib.mkDefault true;
    };

    # Headless box with no persisted RTC and a hostname that's easy to lose on a
    # busy LAN: advertise via LLDP so it shows up in switch/`lldpcli` neighbour
    # tables (find it without console access). Lightweight; no open ports.
    lldpd.enable = true;
  };

  environment.systemPackages = with pkgs; [
    htop
    lm_sensors
    i2c-tools
    dnsutils
    ethtool
    kmod
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  system.stateVersion = "25.11";
}
