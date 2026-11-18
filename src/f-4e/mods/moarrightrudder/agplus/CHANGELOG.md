# Changelog - Jester A/G+

Versions follow major.minor.patch. The version is in `agplus\Config.lua` (`Config.VERSION`).

## Unreleased (Oct 27 2026)

- Ships: the unit feed now includes Export class 3 (navy), and the search lists them under a new **Ships** category. Before this, ships never reached the search in single player or multiplayer.
- Multiplayer menu stalls: the A/G Plus menu rebuild is limited to one per 1.5 s (`MENU_REBUILD_GAP_S`); the many rebuilds a search used to ask for, one per spotted unit, fold into one. A rebuild that takes 15 ms or more is logged to `agplus.log` with the target count (`MENU_REBUILD_LOG_MS`).
- Statics in multiplayer: a client cannot reach the server scripting, so statics cannot be listed there. The hook stops asking after three failed tries and says so in `dcs.log`.
- The unit feed logs an object census (count per Export class) and a few names of unknown classes to `dcs.log` once per session, to show what a server exports.

## 1.0.0 - first public release

**Pave Spike**
- A short press opens the context list whenever the pod is caged, holding or waiting to reacquire, even with an empty Strike List. Search Area is always in the list, so a search starts without the wheel; a lost target gets a Reacquire entry when it is in no slot.

**Maverick (AGM-65 A, B, D, G)**
- Jester slews the seeker to the current Strike List target, then hands over to the pilot.
- A and B are modeled as separate seekers, each with its own slew rate, gimbal limit, picture size and trim.
- Per-missile cap and FOV tracking. A fresh seeker gets its cap taken off first (held 0.5 s on the A/B, a click on the D/G).
- After Launch: Next advances to the next Strike List target after a shot (pickle held 1.2 s and the missile count drops; works with single and triple rails).
- Pilot actions: ARR held with the hand control slews the seeker and Jester lets go; a short ARR tap marks the seeker caged (the lock-bug cure); pilot trigger cages or changes FOV.
- Long press with DIRECT + TV: search where you are looking, or from the boresight. D/G gives the FOV back before the cage when a search ends.
- Optional per-set trim (TV-A, TV-B, IR-Narrow, IR-Wide) with a trainer in the Maverick Dev menu.

**Strike List, center text and wheel**
- A/G Plus wheel order: Strike List, Maverick, Pave Spike, WRCS Integration, Weapon.
- Center text: Weapon, Mode and Target on separate lines. Mode follows the Delivery Mode knob (Direct, TGT Find, Offset), or shows J-Mav while Jester Maverick is working.
- Strike List: Auto Fill, Delete Unit, Purge Targets.

**One-shot context presses (long press)**
- TGT FIND: sets the drag coefficient for the armed bomb.
- OFFSET: sets the release range dial from airspeed and height above the target.

**Pave Spike and WRCS**
- Look-there, area search, hold on a target, target list; WRCS offset bombing with map marks.

**Navigation**
- INS update from TACAN (fix by bearing, overfly).

**Install**
- Feed scripts, the Pave Spike hook and the message hook are included under `feeds`. See `INSTALL.md`.
- `Config.DCS_SAVED_FOLDER` selects `DCS` or `DCS.openbeta`.

**Not supported**
- CBU-97 and the M117.

### Nov 10 2026
- Context List source: Strike List > Manage > Context List switches the pod's Context List between the Strike List slots (default) and the full target list. In full-list mode a short press steps through every listed unit (Search Area and Reacquire stay in the list) and the pod goes to the chosen unit even when it is in no slot. The center text of the Strike List shows the setting. `Config.CONTEXT_LIST_SOURCE = 'strike'` or `'full'` sets the start-up value. The Maverick's TV-mode list still uses the Strike List.
- Destroyed targets: a listed unit that drops out of the unit feed while it is well inside the feed's range (45 km) is removed from the target list and the Strike List after a few seconds, whoever destroyed it. While the pod is idle the unit feed is asked for 3.5 s every 8 s so kills are noticed then too. Only the current target (held or last held) gets the message "Target Destroyed - <name>"; any other unit leaves quietly. The wheel is sent back to the Strike List page so the lists redraw (`Config.PAVE_DEAD_REDRAW = false` skips that). Auto Fill then fills the freed slot with another unit. If the destroyed unit is the one the pod is holding, the hold ends (the laser goes off, the pod stays in track), no reacquire is attempted, and with Auto Advance on the pod goes on to the next filled Strike List slot once the laser is off; after the last slot it loops back to the first filled slot ("Strike List Complete" only when no other slot is left). The next slot is picked after every destroyed unit is out of the list, so a collateral kill in the next slot is skipped. Statics and units beyond the feed's reach are never removed. Off with `Config.PAVE_REMOVE_DEAD = false`.
- Auto Advance after a normal pass with a weapon release now loops too: after the last filled slot the pod goes back to the first filled slot ("Strike List Complete" only when no other slot is filled).
- Maverick D/G FOV: the first pilot trigger after an ARR tap is counted as a re-cage and no longer flips the mod's FOV (it desynced from the seeker). The ARR tap and the trigger now log the FOV the mod assumes.
- `MAG_DECLINATION_FALLBACK` (the magnetic variation used on a map the mod does not recognize) is now 0 instead of +7.
- Multiplayer statics: when the server scripting is not reachable (a client), the hook reads the static objects from the mission file the client loaded (starting positions only: statics spawned by mission scripts are missed, destroyed ones stay listed). Log line: "statics: red=N blue=N ... (from the mission file)".
