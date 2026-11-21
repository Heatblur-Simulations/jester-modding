# Jester A/G+

Version 1.0.0 (see `CHANGELOG.md`).
User guide: `Jester-AGplus-User-Guide.pdf`.

An additive Jester AI mod for the DCS F-4E (Heatblur). It never replaces a stock Jester file; delete `mods\init\agplus` to switch it off.

## Install
Close DCS first. `Saved Games` is the folder that holds `DCS` (or `DCS.openbeta`) and `DCS_F4E`.

1. Open `Saved Games\DCS_F4E\jester\mods` (create the `mods` folder if it is missing). Drag the folders `agplus` and `init` from this download into it. Choose Copy and Replace when Windows asks; the folders merge and nothing of yours is deleted.
2. Open the folder `_EXTRA (DCS Scripts)` and drag the folder `Scripts` into `Saved Games\DCS` (`Saved Games\DCS.openbeta` for open beta). Choose Copy and Replace; your own scripts stay.
3. Export.lua. Open the folder `Export.lua` inside `_EXTRA (DCS Scripts)`. If you have no `Saved Games\DCS\Scripts\Export.lua`, drag and drop the `Export.lua` from there into `Saved Games\DCS\Scripts`. If you already have one, do not replace it (Tacview, SRS and DCS-BIOS use it too): open yours in Notepad and paste this line at the very end on a new line, then save:
   ```
   pcall(function() local l=require("lfs"); dofile(l.writedir()..[[Scripts\AGPlus\AGPlusLoad.lua]]) end)
   ```
4. Open `Saved Games\DCS_F4E\jester\mods\agplus\Config.lua` in Notepad and set `SAVED_GAMES` (your Saved Games folder), `DCS_SAVED_FOLDER` (`'DCS'` or `'DCS.openbeta'`) and `DCS_INSTALL` (your DCS World folder). Save.
5. Start DCS. A mission restart is not enough.

Check: start an F-4E mission, wait ten seconds and open the Jester wheel: Air To Ground > A/G Plus. `INSTALL.md` has the full check, updating, removing and troubleshooting.

## Features
- **A/G Plus wheel:** Strike List, Maverick, Pave Spike, WRCS Integration, Weapon. INS Update is under Navigation.
- **Root wheel quick menu:** one extra item on the first page of the Jester wheel. Its name and contents follow the cockpit: **Maverick** (TV weapon mode), **Bombs** (Delivery Mode other than OFF) or **A/A Plus** (Delivery Mode OFF, or the weapon selector in position B; only with the A/A+ mod installed, otherwise the item is removed). The most used actions are one press from the root, and the last entry of the Maverick and Bombs menus opens the full A/G Plus menu. Clicks stay in the quick menu. `Config.ROOT_MENU = false` removes it; `Config.ROOT_MENU_NAMES = false` gives it the fixed name Combat.
- **Laser code entry:** Bombs > Pave Spike > Laser Code. Pick the hundreds, tens and ones digits on the wheel (the thousands digit is fixed at 1); the center text shows the new code and the last code sent. Enter Laser Code sends it to the pod. Jester accepts codes 1111 to 1788 where the digits are valid (second digit 1 to 7, third and fourth 1 to 8), so the wheel offers only those (`Config.LASER_ANY_DIGITS = true` offers 0 to 9).
- **Center text:** Weapon (the armed bombs and Mavericks), Mode (the Delivery Mode knob: Direct, TGT Find or Offset, or J-Mav while Jester Maverick is working) and Target.
- **Context List (short press of the context button):** with the pod caged, holding or waiting to reacquire, it lists the filled Strike List slots, Search Area and, for a lost target, Reacquire. In TV mode the Maverick's list works the same way. Strike List > Manage > Context List switches the pod's list to the full target list.
- **One-shot context press (long press):**
  - TGT FIND with a target held: sets the drag coefficient for the armed bomb.
  - OFFSET: sets the release range dial for the armed bomb from airspeed and height above the target.
  - DIRECT + TV with Jester Maverick on: search where you look.
- **Jester Maverick:** slews the A, B, D and G seekers to Strike List targets, searches, tracks per-missile cap and FOV, advances to the next target after a launch.
- **Pave Spike:** look-there, area search, hold, target list. Destroyed targets drop out of the lists by themselves.
- **INS update from TACAN (Navigation > INS Update):** Overfly TACAN uses a station up to 120 NM away. Fix By Bearing uses a station up to 150 NM away. A TACAN bearing is good to about 1 degree, which is about 0.5 NM at 30 NM. Beyond 30 NM, Fix By Bearing shows the expected error and needs a second press within 15 seconds to confirm.

Thank you to Heatblur for making outstanding DCS modules, and for making the F-4 Jester API available to the community.
