# Changelog - Jester A/A+

Versions follow major.minor. The guide and the README carry the version.

## 1.0 - first public release

**Searching**
- Directed search from a cue: an RWR emitter, an AWACS BRAA reply, an EWRS group, or where you park the cursor. Jester steps the antenna through elevation bars with a different gain for look-up and look-down, then focuses what he finds and holds the beam on it.
- Cursor search: bump the cursor up or down before you let go and Jester scans level plus that side only, two laps.
- When a report gives the contact's altitude, the search works a tight pattern around that elevation.
- Cues are ranked by threat; a new cue interrupts a running search only if it clearly outscores it.
- Periodic IFF challenge every 15 s while the radar is the picture on the scope, and at once on a new contact or a lock (`IFF_PERIODIC`).

**Modes**
- Radar > A/A Plus: Unified (default), Pilot and Off. Status line in the middle of the wheel.
- In Unified, slewing the cursor gives you control and a double press hands it back; control also returns after 90 s idle.

**Context button**
- A short press steps through contacts left to right across the scope and turns around at each end, never repeating the end contact.
- A long press locks the focused contact, faster than stock.
- A lock you make by hand with the antenna hand controller is kept.
- Lock start is silent. A lost or abandoned lock is forgotten for 20 s.
- Look-down locks: a short preparation follows the contact until the paint is steady, then fires the lock.

**Close in**
- The background scan freezes inside 5 NM.
- BFM mode: chatter muted, speed calls on, IFF challenge on lock.

**Optional AWACS, BRAA and EWRS cues**
- Needs the hook in `_EXTRA (DCS Scripts)` and the `io` change described in `INSTALL.md`.
- Bearings are corrected for each map's magnetic variation. Only AWACS replies addressed to your flight callsign are used.

**Related**
- Separate fix mods for stock Jester bugs (single bandit lock, close bandit awareness) are in the `fixes` folder of the repository.
