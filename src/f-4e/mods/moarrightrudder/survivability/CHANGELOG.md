# Changelog - Jester Survivability

Versions follow major.minor. The guide and the README carry the version.

## 1.0 - first public release

**Missile detection and calls**
- Jester sees every incoming missile whose plume is in view (inside 40 NM for fighter missiles, 25 NM for SAMs), without stock's random roll.
- Early call "Missile, clock" on a long shot, then "Missile missile missile, clock" at 14 s to impact (18 s for a SAM). One call per direction.
- A long shot in the rear sector gets no warning and no program while it stays there.

**Countermeasures**
- A chaff, flare or combined program timed to the time to impact (10 s for fighter missiles, 14 s for SAMs).
- Close shots with a quiet RWR get flares. SAMs get chaff, and both when first seen close.
- The mod sets the chaff and flare mode knobs to SGL while the program runs and restores them afterwards.
- Setup ALE-40 item on the wheel under Systems programs the dispenser. The Jester CMS menu selects who dispenses.

**Singer calls**
- "Singer, clock, type" for ground-launched radar missiles that the ALR-46 does not report (SA-5, SA-6, SA-8, SA-10, SA-11, SA-19, Hawk, Patriot, Rapier and active-radar air missiles).

**Optional object feed**
- `_EXTRA (DCS Scripts)` and the steps in `INSTALL.md` let Jester see semi-active radar missiles (AIM-7, R-27R/ER) and call singers at launch.

**Related**
- Fixes for stock RWR call-out bugs are separate mods in the `fixes` folder of the repository.
