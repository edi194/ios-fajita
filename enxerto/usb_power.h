#pragma once
/*
 * Bring the SDM845 USB30_PRIM controller + QUSB2 PHY out of the cold-boot state
 * (ABL only powers them when it enters fastboot). No-op when GDSC and clocks are
 * already on. Returns 0 = was alive (nothing touched), 1 = powered up here,
 * <0 = could not (-1 GDSC, -2 clocks, -3 DWC3 unreadable). Logs through con_*.
 * Leaves the PHY as ABL's fastboot does: PWR_CTRL1 0x22 (powered, clamp off).
 * Best effort and UNTESTED on hardware: PMIC rails for the PHY are not touched.
 */
int usb_power_up(void);
