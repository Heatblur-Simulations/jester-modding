# Jester Survivability: working notes

Status: 13 Oct 2026. These notes are the seed for a quick-read user guide and, later, a technical manual. They cover what the
suite does, what each feature depends on, and its status. Settings are in `Config.lua`; the code comments
in `Countermeasures.lua` carry the detail.

## Overview

An additive Jester mod (`mods\survivability`, launched from `mods\init\survivability`). It changes no stock files except by
wrapping or replacing a few stock methods at run time. Delete `mods\init\survivability` to remove it.

| File | Job |
|------|-----|
| `Suite.lua` | Entry point: starts the other parts. |
| `Config.lua` | Every tunable value (and the two feature switches `COUNTERMEASURES`, `ALE40_SETUP`). |
| `Countermeasures.lua` | Missile detection, warning calls, chaff and flare programs, RWR launch watch, ground-launch "singer" call. |
| `ALE40.lua` | "Setup ALE-40" item on the Jester wheel (Systems): programs the dispenser and hands chaff to Jester. |
| `Log.lua` | Logging to `survivability.log` and the Jester console. |

## Features, and what each one needs

| Feature | Description | Needs the object feed? | Needs the RWR? |
|---------|--------------|------------------------|----------------|
| Missile vision | Jester always sees a missile inside `AIR.visible_nm` (40) / `SAM.visible_nm` (25), instead of stock's random roll. | No | No |
| Shooter matching | A hostile aircraft behind the missile on its track is the shooter (fighter launch). No shooter = ground (SAM) launch. | No | No |
| Radar-missile detection | Semi-active radar missiles (AIM-7, R-27R/ER and similar) are never handed to Jester by the sim. The feed is the only way to see them. | **Yes** | No |
| Warning calls | Long shot: "missile, clock" early, then "missile missile missile, clock" at `warn_tti_s`. Close shot: the three-times call at once. SAM: three-times call at `SAM.warn_tti_s`. | Radar missiles: yes. IR missiles and visible SAMs: no | No |
| Countermeasure programs | Flares only for a close shot with a quiet RWR, otherwise chaff and flares; SAMs get chaff (both when first seen close). Timed by time to impact. | Same as above | Used to choose the program |
| RWR SAM launch watch | When the RWR shows a launch and no SAM missile is tracked, chaff after `RWR.first_s`. | No | **Yes** (only SA-2, SA-3, SA-15 and a few others, see below) |
| Ground-launch "singer" call | "Singer, clock, type" the first time a ground-launched radar missile is seen, for SAM sites the RWR does not report (SA-6 and others). | **Yes, for an early call.** Without the feed it waits for Jester's eyes (inside 25 NM, typically some seconds after the launch) and a missile never seen gets no call. | Type comes from the RWR emitter near that clock, else a lookup by missile name |
| One call per direction | A "missile missile missile" (or plain "missile") for the same clock, plus or minus one hour, within `CALLS.gap_s` (8 s) of the last one is not repeated. A salvo of two missiles, or the same missile reported by the feed and then by the eyes, gives one call. A different direction is always called. Speech only: countermeasures are not affected. | No | No |
| Call priorities | Missile calls priority 3, launch and singer calls 2 (stock: 0), so they do not wait behind routine chatter. | No | No |

## Limits that come from the sim

- **The ALR-46 reports a launch only for a few systems** (Heatblur F-4E manual, radar warning receiver page): SA-2, SA-3, SA-15,
  NASAMS (while tracking an AIM-120), and some air-to-air missiles (R-77, SD-10, AIM-54, AIM-120). It gives **no** launch
  indication for SA-5, SA-6, SA-8, SA-10, SA-11, SA-19, Hawk, Patriot or Rapier. Stock's "singer" call and the RWR launch watch
  therefore never fire for those; the ground-launch call above exists to cover them.
- **Radar-guided missiles are invisible to Jester** in the sim's own contact list, at any range. Only the object feed sees them.
- **The object feed needs the server to allow object export** and `SurvFeed.lua` in the Export environment. A status line in the
  log shows whether it is live (`feed status: ... object export looks ON`). Without it the suite falls back to what Jester's
  eyes see.
- **Jester's voice is built from fixed clips.** The singer clip carries its clock position ("singer twelve o'clock"), so the type
  comes after it. The follow-up form uses `phrases/andasinger`; stock's `phrases/andsinger` has no voice file.

## Singer call for ground launches: rules

- Fires on the first sighting of a ground-launched missile that is not an IR type (so not MANPADS).
- Not made while the RWR itself shows a launch (stock's singer covers it); a singer from the RWR that follows a call made for the
  same site is dropped, so a launch is never announced twice.
- No second call for the same site (same clock, plus or minus one) within `SINGER.same_site_s` (30 s). A call within
  `SINGER.and_s` (5 s) of another is spoken "and a singer".
- Type: the voice phrase of the RWR surface emitter at that clock (or one hour either side). If none, `SINGER.types` maps a
  lower-case missile name to a phrase (`sa3m9m` is SA-6). The log line shows which source was used.

## Log lines worth knowing

| Line | Meaning |
|------|---------|
| `feed status: ... object export looks ON` | The feed is live. |
| `feed missile: ...` / `missile seen: ...` | A missile was first tracked (feed or eyes), with its program. |
| `ground launch call (feed\|eyes): singer N o'clock, type ... (RWR emitter\|missile name\|unknown), missile ...` | The singer call was made. `unknown` = no type: send this line to add a mapping. |
| `RWR launch: ...` | The RWR showed a launch (only the systems listed above). |

## Status (13 Oct 2026)

- Shipping cleanup done 13 Oct: the temporary `RWR contact:` diagnostic is removed and `Config.LOG_TO_FILE` is false (set it true to
  write `survivability.log` for a test run or a bug report). The Jester console log stays on.
- Flown 13 Oct (SA-6 launches, feed live): the singer call fired at the first feed sighting with the type
  taken from the RWR emitter (`SAM/sasix`); repeats for the same site were skipped. The same flight showed up to four "missile missile
  missile" calls within six seconds for one salvo, which led to the one-call-per-direction rule above.
- Changes in this version: the `last_singer_time_stamp` change in the Suite's `SaySinger` (it lets the "and a singer" form fire for two RWR
  launches in a row, SA-2 / SA-3), and the one-call-per-direction rule.
- Not built: ordering of a nails call and its "and nails" follow-up (they are separate tasks of equal priority; the order can in
  principle swap, no case has been heard).

## Planned documents

1. A quick-read user guide (a pamphlet): what Jester now does for you, in the order you meet it in flight, for both the Jester A/A+
   and this Suite.
2. A technical manual: the invariants, the dependencies in the table above, the sim limits, the test sequences.
   `aaplus\DESIGN.md` already holds the Jester A/A+'s invariants and regression sequence.

## Missile visibility and reaction (tests 14 Oct 2026; technical notes, not for the user guide's numbers)

Guide rule (user decision): the guide says only that Jester takes longer to see a missile plume at long range, and that in BFM he
watches for a missile to come off the rail at once. No ranges or delay figures go in the guide; they stay here.

Measured (pilot's cockpit view, plume first made out, matched to the `trace` lines in `survivability.log`):

| Missile | Shooter | Contrail | First seen | Note |
|---------|---------|----------|------------|------|
| R-33 | MiG-31, head-on | yes (missile hid in it) | about 26.8 NM | a lower bound |
| AIM-54C | F-14, head-on | no | about 31.4 NM, 9 s after launch from 34.3 NM | pilot's call: about 30 NM is the maximum for a smoke plume |
| SA-10 (5V55, log name `SA5B55`) | ground site, head-on | no | about 29.9 NM (5 s after launch) and 29.5 NM (6 s after launch), two runs, launch at 31.0 NM | pilot started looking at about 30 NM, so a floor; large missile, smaller SAMs may be shorter |
| SA-10 (run 3) | ground site, head-on | no | about 31.8 NM, 7.4 s after launch | third run |
| SA-15 (9M338K) | ground site, head-on | no | about 8.4 NM, 3.3 s after launch (launched at 9.4 NM) | Jester sighted it at 8.7 NM, 2.6 s after launch (taper delay about 2.5 s), 0.7 s before the pilot. The RWR launch tone fired chaff at 0.4 s after launch, before any sighting. |

Decision (14 Oct): SAM plumes use their own curve, `Config.REACT_SAM` = 5 s at 30 NM falling to 3 s at 5 NM and closer (measured 3.3-7.4 s after launch; the short end leaves a chance against MANPADS). Aircraft missiles keep the `REACT` curve (10 s at 30 NM down to 0.5 s at 3 NM).

Settings that follow (all in `Config.lua`):

- `AIR.visible_nm` and `FEED.max_nm` = 30 NM: a missile with its motor burning (or smoke still hanging) is seen out to this. `SAM.visible_nm`
  = 30 NM too (SA-10 test, two runs; other SAMs not measured). The feed's singer call (ground launch) now waits for the same range and reaction delay
  (before, it was spoken at the launch itself, e.g. at 31 NM).
- `REACT` = 10 s at 30 NM, straight line down to 0.5 s at 3 NM or closer. Counted from when the missile comes inside visibility range. Applies
  to feed missiles and to Jester's eyes (the `Eyes.IsContactVisible` wrapper). Dispensing (10-14 s to impact, 5-7 NM) is barely affected.
- Burnout (feed only): the feed's `spd` field (missile's own speed, from `SurvFeed.lua`) falling `coast_drop_mps` (40) below its peak.
  Smoke trail counts as visible for `smoke_s` (10) after burnout; after that an unsighted coasting missile is only seen inside
  `coast_nm` (1.5). Without `spd` (older SurvFeed.lua) the closing speed is used. A long Phoenix shot is therefore called late (about 3 s)
  unless the RWR cue below fires.
- Realism check: a 0.4 m missile at 8 NM subtends about 5 arc-seconds (eye resolves about 60), so only the plume and smoke trail can be seen.

Active-missile RWR cue (flown 14 Oct, AIM-54): the ALR-46 shows a missile symbol when an active-seeker missile goes active (manual: "AIM-54
tracking", F-14 row). In `rwr_contacts` it arrives as a contact with `symbol` = `uncorrelated_missile_launch` (category/type unknown, subcategory
`sam`), about 5.4 NM (10 s) from impact. The suite answers it at once: "missile missile missile" at that clock plus one chaff program, and
marks the nearest feed missile as already dispensed (without that it dispensed again at 3 s to impact). Detection is any `rwr_contacts` field
containing "missile", so the correlated variant should be covered but has not been seen. `/RWR AN_ALR_46_Audio` `Launch Audio Playing` reads
live (boolean) and is also watched, but did not fire in the test. Fired from TWS there is no aircraft emitter, so the symbol is the cue.

Duplicate tracking fix: a missile the feed tracked from launch was picked up later by Jester's eyes, found no shooter nearby, and became a
second, "SAM" track (false "singer" call, second heads-up, second dispense). The eyes path now defers to a feed track at the same range.

Log lines added: `trace feed#N` / `trace eyes#N` (range, closing speed, bearing, once a second), `feed: missile sighted at X NM (...)`,
`RWR activity: id=...`, `RWR missile symbol: ...`, `RWR active missile: heads-up for hour N`, `Jester dispensing allowed: ...`,
`eyes: missile at X NM is the feed missile already tracked`.

Still open: whether the stock CMS menu's handoff changes `GetJesterCountermeasuresDispensingAllowed` (it stayed `true` in the log so far);
a smaller IR missile (AIM-9, R-73) and a SAM plume to measure; the correlated-missile symbol wording.

## CMS menu handoff (test 14 Oct 2026)

The stock wheel item Countermeasures Dispensing (Jester / Manual) drives `jester.memory:GetJesterCountermeasuresDispensingAllowed()`: Manual reads false, Jester reads true; the default at mission start is true. It is the only countermeasure member on the memory object (plus the property `jester_countermeasures_dispensing_allowed`). The suite reads this flag in `pump()`, so Manual stops all suite dispensing and Jester lets it run. Setup ALE-40 sets the flag true.
