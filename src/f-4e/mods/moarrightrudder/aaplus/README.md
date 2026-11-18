# Jester A/A+

Version 1.0 (see `CHANGELOG.md`).
User guide: `Jester-AAplus-User-Guide.pdf`.

An additive Jester AI mod for the DCS F-4E (Heatblur). It never replaces a stock Jester file; delete `mods\init\aaplus` to switch it off.

## Install
Close DCS first. `Saved Games` is the folder that holds `DCS` (or `DCS.openbeta`) and `DCS_F4E`.

1. Open `Saved Games\DCS_F4E\jester\mods` (create the folders if they do not exist) and drag the folders `aaplus` and `init` from this download into it. Choose Copy and Replace when Windows asks; the folders merge and only A/A+ files are added.
2. Open `Saved Games\DCS_F4E\jester\mods\aaplus\Config.lua` and set `Config.SAVED_GAMES` (the line marked "PATH TO EDIT") to your Saved Games folder, for example `C:\Users\Pat\Saved Games` or `A:\Saved Games`. It is the only path to edit.
3. Start DCS. (LShift+R restarts the mission and reloads Jester's Lua.)

Check: start an F-4E mission and open the Jester wheel: Radar > A/A Plus. `INSTALL.md` has the full check, the optional AWACS hook, updating, removing and troubleshooting.

## Features
Jester runs the radar the way a WSO would for air-to-air, instead of waiting to be told.
- **Directed search:** for a contact he has been cued to (RWR emitter, a BRAA/AWACS call, an EWRS group, or where you leave the cursor), he steps the antenna through elevation bands with the right gain for look-up and look-down, then focuses the contact and hands over to stock's call-outs and lock.
- **Cursor search:** bump the cursor up or down and leave it, and he scans level plus that side only (two laps).
- **Hold and lock preparation:** holds the gain and the beam on a contact he is working, keeps the cursor on it, and prepares the lock.
- **Periodic IFF:** he presses the IFF challenge every 15 s while the radar is the picture on the scope (with or without contacts), and at once on a new contact and on a lock. Not in BFM (it has its own IFF on lock), not with the radar off or in standby, and not while the scope shows the Pave Spike, a Maverick or other video. `Config.IFF_PERIODIC = false` turns it off.
- **Heads out:** stock's background scan stands still inside 5 NM (TRANSITION / BFM).
- **Three modes** (Radar menu on the Jester wheel > A/A Plus):
  - UNIFIED (default): Jester searches on his own, slewing the cursor gives you control, a context double-press hands it back.
  - PILOT: you drive the cursor and scan.
  - OFF: stock behavior.

## Optional: AWACS / BRAA / EWRS cues
Without this, A/A+ still works from the RWR and the cursor; the AWACS feature stays off (one log line says so). It needs two things:
1. **The hook.** Drag the folder `Scripts` from `_EXTRA (DCS Scripts)` into your DCS folder inside Saved Games (`Saved Games\DCS`, or `Saved Games\DCS.openbeta` for open beta) and choose Copy and Replace. It adds `Scripts\Hooks\AAPlusMessages.lua` and writes `Logs\aaplus_messages.txt`. DCS must be fully restarted once. `Config.AWACS_FILE` already points at it, built from `Config.SAVED_GAMES` (folder `DCS`).
   - The hook also tells A/A+ which map is loaded. AWACS and EWRS bearings are magnetic, so A/A+ compensates for each map's magnetic variation (the per-map values MOOSE uses; `Config.MAGVAR` overrides them). A map with no entry, such as a new release, counts as 0 degrees. An old hook that does not report the map keeps the Caucasus figures.
   - The hook also reports your flight callsign (read from the mission data; it follows a respawn or slot change). A/A+ uses only AWACS replies addressed to that callsign, so on a server another player's bogey dope is ignored. The wheel shows it as `ID: <callsign>`. With no callsign (an old hook, or none in the mission data) stock AWACS replies are ignored.
2. **Input/output access.** Jester's Lua must be allowed to read that file (the `io` library). DCS removes `io` from mission scripts in `<DCS install>\Scripts\MissionScripting.lua` (the `sanitizeModule('io')` line). Commenting that line out gives `io` to every mission script, which is a security risk if you load missions you do not trust, and a DCS update puts the line back. Your call.

## Settings
All in `mods\aaplus\Config.lua`; most settings are commented. The ones people change: `DEFAULT_MODE`, the `SEARCH_*` band sizes and dwell times, `SEARCH_UP_GAIN` / `SEARCH_DOWN_GAIN` / `SEARCH_UNKNOWN_GAIN`, `SEARCH_BUMP_LAPS`. `LOG_TO_FILE` (off) writes `aaplus.log` for bug reports.

## Uninstall
Delete `mods\init\aaplus` (stops it loading). Delete `mods\aaplus` to remove it completely. Delete the hook file to stop the AWACS log.

## Notes
- `Jester-AAplus-User-Guide.pdf` is the user guide: how the mod works, what to expect in the sim, and its limits.
- Needs Jester's Lua to be able to load the mod folder (any Jester version with the `mods\init` mechanism).
- `mods\aaplus\DESIGN.md` is the developer document: invariants, the test sequence, the change history.
- It does not touch Jester Survivability and needs nothing from it.

Thank you to Heatblur for making outstanding DCS modules, and for making the F-4 Jester API available to the community.
