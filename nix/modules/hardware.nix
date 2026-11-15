# Hardware wiring for the Banana Pi BPI-F3 (SpacemiT K1).
{ lib, ... }:
{
  hardware = {
    enableRedistributableFirmware = true;

    # Mainline device tree; it has the SD slot, eMMC, Ethernet, USB and PCIe.
    deviceTree.name = "spacemit/k1-bananapi-f3.dtb";
  };

  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";
}
