# Hardware wiring for the Banana Pi BPI-F3 (SpacemiT K1).
{ lib, ... }:
{
  # No firmware blobs (linux-firmware etc.): nothing the board supports loads
  # any (Ethernet PHY, USB, PCIe/NVMe, SD; the on-board Wi-Fi has no driver).
  # Re-enable hardware.enableRedistributableFirmware for USB devices that do.
  hardware.deviceTree.name = "spacemit/k1-bananapi-f3.dtb";

  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";
}
