# Jester Survivability

Version 1.0 (see `CHANGELOG.md`).
User guide: `Jester-Survivability-User-Guide.pdf`.

An additive Jester AI mod for the DCS F-4E (Heatblur). It never replaces a stock Jester file; delete `mods\init\survivability` to switch it off.

## Install
Close DCS first. `Saved Games` is the folder that holds `DCS` (or `DCS.openbeta`) and `DCS_F4E`.

1. Open `Saved Games\DCS_F4E\jester\mods` (create the folders if they do not exist) and drag the folders `survivability` and `init` from this download into it. Choose Copy and Replace when Windows asks; the folders merge and only Survivability files are added.
2. Open `Saved Games\DCS_F4E\jester\mods\survivability\Config.lua` and set `Config.SAVED_GAMES` (the line marked "PATH TO EDIT") to your Saved Games folder, for example `C:\Users\Pat\Saved Games` or `A:\Saved Games`. It is the only path to edit.
3. Start DCS.

This is enough for missiles Jester's own eyes can see (IR missiles, visible SAMs).

Check: start an F-4E mission and open the Jester wheel: Systems. The Setup ALE-40 item should be there. `INSTALL.md` has the full check, the optional object feed, updating, removing and troubleshooting.

## Features
Gives Jester missile defense. For the stock RWR call-out fixes, install the optional mods in the `fixes` folder.
- **Missile detection:** he always sees an incoming missile inside 40 NM (fighter missiles) / 25 NM (SAMs), not on a random roll.
- **Calls:** "Missile, <clock>" early on a long shot, then "Missile missile missile, <clock>" at the time to impact; one call per direction (a salvo or a repeat sighting is not called twice).
- **Countermeasures:** dispenses a chaff/flare program timed to the time to impact. IR-type or close shots with a quiet RWR get flares.
- **Singer calls:** for SAM launches the ALR-46 does not report (SA-6 and others), a "Singer, <clock>, <system>" call when the missile is first seen.
- **Setup ALE-40:** an item on the wheel (Systems) that programs the dispenser and hands chaff to Jester.

## Optional but recommended: the object feed
Semi-active radar missiles (AIM-7, R-27R/ER and similar) are never handed to Jester by the sim; the only way to see them is DCS's object export. Without the feed those get no call and no countermeasures, and the ground-launch singer call comes late (after Jester sees the missile) or not at all. To enable it:
1. Drag the folder `Scripts` from `_EXTRA (DCS Scripts)` into your DCS folder inside Saved Games (`Saved Games\DCS`, or `Saved Games\DCS.openbeta` for open beta) and choose Copy and Replace. It adds `Scripts\SurvFeed.lua`.
2. Add this line at the END of `Saved Games\DCS\Scripts\Export.lua` (create the file if there is none):
   ```lua
   pcall(function() local l=require("lfs"); dofile(l.writedir()..[[Scripts\SurvFeed.lua]]) end)
   ```
3. Jester's Lua needs the `io` library to read the feed file. In `<DCS install>\Scripts\MissionScripting.lua`, comment out the `sanitizeModule('io')` line. This gives every mission script file access (a security risk with untrusted missions), and a DCS update puts the line back.
4. On a multiplayer server the server must allow object export; on a server that does not, the feed is simply empty.
5. `Config.FEED.path` already points at that file, built from `Config.SAVED_GAMES`. Restart DCS.

The log line `feed status: ... object export looks ON` (needs `LOG_TO_FILE`) shows whether the feed is live.

## Settings
All in `mods\survivability\Config.lua`, every number commented: visible ranges, warning and dispense times, the chaff/flare programs, the call gap (`CALLS.gap_s`), singer rules (`SINGER`), voice priorities. `COUNTERMEASURES` and `ALE40_SETUP` switch the two parts on or off. `LOG_TO_FILE` (off) writes `survivability.log` for bug reports.

## Known limits
- The ALR-46 reports a launch only for SA-2, SA-3, SA-15 and a few others; for the rest the singer call comes from the object feed or Jester's eyes (see `NOTES.md`).
- Radar-missile calls need the object feed (above).
- Chaff request to Jester is off on purpose (the suite times its own dump).

## Uninstall
Delete `mods\init\survivability` (stops it loading), then `mods\survivability` for a full removal. Remove the SurvFeed line from `Export.lua` and delete `SurvFeed.lua` to stop the feed.

## Notes
- `Jester-Survivability-User-Guide.pdf` is the user guide: how the mod works, what to expect in the sim, and its limits.
- `mods\survivability\NOTES.md` has the feature/dependency table, sim limits, log-line guide and status.
- It does not touch Jester A/A+ and needs nothing from it.

Thank you to Heatblur for making outstanding DCS modules, and for making the F-4 Jester API available to the community.
