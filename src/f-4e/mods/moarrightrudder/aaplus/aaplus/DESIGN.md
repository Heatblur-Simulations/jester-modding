# Jester A/A+: design notes and regression sequence

(Formerly the "A/A Director", folder `aadirector`; renamed 13 Oct 2026. Older changelog entries and log excerpts below may use the old names:
`aadirector` = `aaplus`, `[AAD]` log prefix = `[AA+]`, hook `AADMessageLog.lua` = `AAPlusMessages.lua`, file `aad_messages.txt` = `aaplus_messages.txt`,
wheel entry `A/A Director` = `A/A Plus`.)

Read this before changing Search.lua, Cues.lua, Director.lua or Awacs.lua. Every change is checked against the
invariants below and the regression sequence before it is deployed. Update this file in the same change.

## Hard facts about stock

- Stock's targets (`target_to_focus_on`, `target_to_highlight`, `target_currently_locked`, `target_to_lock`) are
  USERDATA, not tables. Never test `type(t) == 'table'`; read `t.id` inside pcall (`tid(t)` in Search.lua). That test
  silently disabled the follow-hold, the stale-focus check and the focus half of `held_by_stock`.

### APQ-120 beam geometry (source: Chuck's Guide, F-4E, part 10 radar & sensors, sections 2.2.3 and 2.3.3; the three pages are saved as images in `docs_radar\` next to this file)
- Beam width: 3.7 deg (half power) without feedhorn nutation, 6.7 deg (full power) with nutation. Nutation gives a "bigger" beam (more search coverage) at the cost of detection range and discrimination, and it is required for automatic tracking.
- Vertical coverage: 1 bar = 6.7 deg with nutation (3.7 without). 2 bars = the beam alternates between 1.875 deg above and below the radar plane, 10.45 deg total (3.75 deg bar spacing + the 6.7 deg beam). `Config.SEARCH_STEP_DEG` 3.5 comes from the beam size ("3.7 = minimum coverage without nutation").
- Nutation active (table): RDR / BST / AIR-GRD with the action switch released: yes. MAP released: no. RDR or MAP, B-scope display: 5, 10, 25, 50 NM: yes with half or full action; 100 NM and 200 NM: yes with half action, no with full action. MAP with the PPI display: never. BST / AIR-GRD follow the same ranges as the RDR B-scope.
- Azimuth: 120 deg total with the display on WIDE (+-60), 45 deg total on NAR (+-22.5). The antenna is stabilized in pitch and roll to the horizon in automatic search.
- Detection (Chuck): bombers about 40-50 NM, fighters about 25 NM, lock typically within 20 NM or less.
- Use: with the nutating beam (6.7 deg, half width 3.35 deg) the beam's lower edge is what meets the ground, so main-lobe clutter starts where a line 3.35 deg below the beam center reaches the terrain. An upward aim bias on a look-down contact moves that edge farther out and is limited by the half-width: stay well inside 3.35 deg (the sim's actual pattern is not verified). Not used yet (see the look-down gain notes).

## Pieces

- Cues.lua: the cue list (RWR emitters, stock-BRAA `awacs`, EWRS groups `ewrs:N`, IFF orphans, CURSOR). A cue is
  "satisfied" when a matching real track exists. Also: `Cues.Threat` (search order), the EWRS-to-RWR merge, the
  stepping order for the context button, the gimbal check in `Cues.Best`.
- Awacs.lua: contacts read from stock's BRA message and the EWRS picture (hook file). Per contact: position, altitude,
  type, the aspect word, and (from successive reports of the same group) velocity and closure. `Awacs.ThreatInfo`
  (range, aspect, closure, time to merge), `Awacs.TypeClass`, `Awacs.TakeCue` (stock reply), `Awacs.TakeEwrsGroups`
  (EWRS groups), `Awacs.Elevation(cue)` (elevation for the search; a cursor cue snaps only within about 10 deg of
  bearing, so a cursor search elsewhere has no elevation).
- Search.lua: the bar search (bands), gain handling, the gain hold `gh`, focus of the found contact, the context-button
  press (`ContextShort`).
- Director.lua: once a second: takes the stock reply and the EWRS picture, runs cues, starts the best search or
  preempts for a clearly more threatening cue, calls `Search.GainHoldUpdate`.

## Invariants (do not break)

Gain
- G1. One gain owner at a time: a search (`sw.gain_cfg`) or the hold (`gh`). Stock's `AdjustGain` is skipped for both.
- G2. A held gain survives every hand-off: found, called out, handover (focus), preempted by a new report, pilot slew,
  and the start of the next search. Nothing may put the knob back to stock in between. Only these release it:
  contact lost 15 s with no focus/lock/highlight, a search that wants no gain, or a reset. There is no time limit: the gain
  is held for as long as the contact is worked (focus, lock or highlight). (No
  ground-range release in the hold: it never fired and was not wanted.)
- G3. A new search takes over the held gain (`carried_cfg`) instead of releasing it. Its knob baseline stays
  `Search.orig_knob` (the stock value), never a value read while one of our gains is on the knob.
- G4. Which gain: contact elevation known and above the horizon: `SEARCH_UP_GAIN` for the whole pattern
  (`AWACS_ONE_GAIN`); below: `SEARCH_DOWN_GAIN`. No elevation known: `SEARCH_UNKNOWN_GAIN` on level/up bars,
  `SEARCH_DOWN_GAIN` below the horizon.
- G5. The knob is re-asserted every 1.5 s if it drifts (max 15 per search). Stock applies a gain late, so the knob is
  also set directly.
- G6. A hold at the unknown-elevation gain is upgraded to the look-up gain (same value, 0.73) as soon as the held
  contact is more than 0.5 deg above the horizon. The look-up window is narrow; see G7 (tuned value now 0.73).
- G7. Gain values (v40/v41, flown with the log checked for `gain -> X`): `SEARCH_UP_GAIN` and `SEARCH_UNKNOWN_GAIN`
  0.73, `SEARCH_DOWN_GAIN` 0.63 (final; was 0.55 before the look-down tests). The window is narrow: on the
  look-up geometry (player 3000 ft, B 12000 ft head-on, E emitter at 50 NM / 25000 ft) 0.70 was steady (found 32-38 NM,
  focus about 31 NM, two runs), 0.73 was best (found 40-41 NM, focus after 8-10 s, steady paint, two runs) and 0.75 was
  lost within a second or two of each find (hits 0-3, never listed by stock, no focus 40 -> 10 NM). Level flight (B at
  20000 ft, player 20000 ft) at 0.73: found 43 NM, focus after 3.7 s, 47 hits by 39 NM. Stock (about 0.68, nil gains)
  level: found 30 NM, focus 29 NM. NOTE: the earlier gain cards (gain_card_results.md) had 0.75 best (about 44 NM) and
  0.70 weaker (about 28 NM). Today's flights contradict that for 0.75 and 0.70 on the same geometry. The mod has changed
  since (hold aiming the beam at the contact's elevation, steering the cursor to the track bearing, extrapolation), so
  the cards are not a safe reference for exact values. Keep re-checking after tracking changes; 0.73 sits close to
  the edge (0.75 fails), so a weaker target or other elevation may need a lower value.

Focus
- F1. A contact found beyond `STOCK_FOCUS_NM` (30 NM) is not focused at once: see F4. Focus by Jester (`focus_found`)
  uses stock's next-bandit pick (`Api.GetNextBanditOrNil`) or `radar_targets`, and marks the focus
  `pilot_requested_target_to_highlight` so stock does not drop it. It fails when stock has no target object for the
  contact (the contact is not being painted); the log says so (`focus_found: not focusing ...`).
- F3. A contact found on a bar more than `SEARCH_RECENTER_DEG` (1.5 deg) from its real elevation (from its reported
  altitude) gets the beam pointed at its elevation first; the search waits (up to `SEARCH_RECENTER_HOLD_S`, 3.5 s) for
  a fresh paint. Reason (log 7a): found on the +0 bar with the contact at +4.2 deg, the track was never painted again.
- F4. A contact found beyond 30 NM (`sw.far`, latched at the find) is handled in the holding phase, in this order:
  (a) Painted steadily (on the scope now and at least `SEARCH_FOCUS_HITS`, 5, hits): Jester focuses it at once
  (`contact has N hits: focusing it ahead of the call-out`), so the cursor moves first and stock's report follows.
  (b) Otherwise the beam is held on the contact's elevation (reported altitude), range + 3 NM, refreshed when the
  elevation moves 0.7 deg or the range 3 NM, with the knob re-asserted, until (a) is met, stock calls it out (F6) or
  `SEARCH_HOLD_FAR_S` (60 s) passes, then Jester focuses it. No focus is forced on a contact with few hits: it left stock
  with a focus it never confirmed, the radar went back to its normal scan and the cursor (which follows fresh paints)
  stayed put. Evidence: stock calls a contact out at 33-40 NM once it has painted 10+ times (card runs, 7a at 12,000 ft);
  a forced focus with 2 hits never produced a call-out. Flown (7a, 12,000/3,000 ft): found at 36 NM, 9 hits and focused
  7.8 s after the start, the track then painted steadily (hits 12, 18, 21, ...) and the cursor followed.
- F5. A contact that has painted once near the cue (not yet two hits, so not a track) gets the beam aimed at its
  elevation (reported altitude) when that is more than 1.5 deg from the current bar, and the search stays on it for
  `SEARCH_CANDIDATE_HOLD_S` (12 s) more, following its elevation as it closes (`candidate_track` in Search.lua).
- F6. A contact stock called out beyond 30 NM with no focus yet is focused by Jester (stock focuses only inside 30 NM;
  stock's call-out phase `IDENTIFY_TARGETS` can take ~20 s, which is why F4 (a) acts first).
- F2. A focus on a contact that has been off the scope for more than `FOCUS_LOST_S` (8 s) must not block a new
  search; the new search clears that focus. A lock, or a focus on a contact still on the scope, blocks.

Cues
- C1. RWR and AWACS cues need stock to hold the track (`CUE_NEEDS_HELD`). "Called out" counts only while the track is
  on the scope (`tr.present`).
- C2. A search treats a track it painted as matched (`TracksNear(cue, true)`).
- C3. A new BRAA report while searching the previous report moves the search to the new position if the contact
  moved more than `AWACS_NEW_CUE_NM`. A search on another cue (RWR) is interrupted only by threat preemption (C6).
  A report already matched by a running search is adopted by it (no restart).
- C4. Seeded tracks (already on the list at the start) count as found only when freshly painted (present, age <= 4 s).
- C5. A cursor cue comes from the pilot's slew; stick input puts the cursor with the pilot, a double press gives it back.

- C6. Search order (UNIFIED): highest `Cues.Threat` score. A launch warning is not a factor (too late by then).
  Terms (`Config.CUE_THREAT`): kind (RWR 3.0, IFF 2.0, cursor 2.0, AWACS 0.0); aircraft class from the EWRS type
  (`AWACS_TYPE_CLASSES`: fighter +1.5, attack +0.8, other -0.5, helo -2.0; stock BRAA has no type: 0); time to merge
  (3.0 at 0 s, 0 at 180 s or opening); aspect (hot +1.0, flanking +0.3, beaming -0.5, cold -1.5); measured speed
  (+0.5 at 700 kt); closeness (1.0); elevation above us (+-1.0); near the nose (0.5). An RWR cue with an AWACS/EWRS
  contact in its sector adds that contact's terms, so an emitter with a known hot fighter scores about 7.5, an
  emitter alone 3.9, a bare stock BRAA bogey 1.5 on the first call and 5 once confirmed closing fast inside about 15 NM.
  A cue interrupts a running search only if it out-scores it by `CUE_SWITCH_MARGIN` (1.0). A search that is still sweeping with
  nothing found after `CUE_STALL_S` (20 s) gives way to any cue that scores higher (margin `CUE_STALL_MARGIN` 0.3, so a near-tie with a close cue does not switch; log `(that search found
  nothing in N s)`). Reason (7b rerun): a 68 s sweep for an emitter 44 NM away blocked a hot bogey 17 NM out that
  out-scored it by only 0.2. Also (7b, v21): a stalled search yields to any waiting cue that is CLOSER, even if it scores lower, so a far emitter that will not paint cannot hold the radar while a bandit closes; it never switches to a farther cue.
- F7. Two fixes from 7b: (1) the found contact itself counts as one matched emitter when deciding to resume (a one-hit find is not yet a 'known' track, so a single-emitter cue resumed at once and threw the find away at 14 NM); (2) the long hold (beam held, focus at `SEARCH_FOCUS_HITS` or on the call-out, up to `SEARCH_HOLD_FAR_S`) applies to any find with fewer than `SEARCH_FOCUS_HITS` hits as well as to those beyond `STOCK_FOCUS_NM` (a one-hit find at 25 NM was dropped after the 8 s hold).
- F8. While the beam is held on a found contact (long hold), a higher-scoring cue takes the radar only if it is CLOSER than that contact (`Director.CloserThanFound`); the stalled-search takeover stays. Reason (7b v31): an unpaintable emitter at 45 NM pre-empted B, found at 25 NM, 20 s into its hold.
- F9. While holding a found contact, the cursor (which the narrow scan follows) is placed on the contact's own last measured bearing and range (`Picture.tracks[found].az_deg`), not on the cue's bearing, which lags a closing contact (7b v32: B at -40, cursor at -30, B at the strip edge and not painting).
- F10. The long hold is chosen by how the contact paints NOW (`hits` and `present`, not the historical `max_hits`): a find that is not on the scope with at least `SEARCH_FOCUS_HITS` hits holds long (7b v32: B, found a second time, still carried max_hits 5 from the first find, so it got the 8 s hold, then `no stock target object`).
- F11. During the sweep the cursor's bearing is the measured bearing of a track near the cue that painted within `SEARCH_STALE_TRACK_S` (12 s), not the cue's: the stock BRAA bearing lags a closing contact by 7-10 deg and the narrow scan follows the cursor (7b v33: B at -43, cue -33, never found). `AWACS_NEAR_HOLD_S` raised to 45 s because stock's own BRAA reports for the nearer bandit can be 27 s apart (a far call at t=41 restarted the search).
- F12. The long hold is used for any find beyond `SEARCH_HOLD_LONG_NM` (20 NM), not only beyond `STOCK_FOCUS_NM` (30), and for any find not painting steadily now (F10). Reason (7b v34): B found at 26 NM with steady paints got the 8 s hold, stock had not called it out, `no stock target object`. `called_far` (stock does not focus a call-out beyond 30 NM) still uses `STOCK_FOCUS_NM`.
- 7b result (v35): E no longer hijacks the radar; B found at 25 NM, beam and cursor held on it, focused at 17 NM on 5 hits (`contact has 5 hits: focusing it ahead of the call-out`). B first paints on its own elevation only about 19-20 NM out in this setup (radar detection limit), so focus before about 17 NM is not expected here. A DCS window that is minimized or alt-tabbed freezes the sim and the log stops (`resize main window to [0, 0]` in dcs.log): keep it in front while testing.
- Forced-focus experiment (v36, `SEARCH_FOCUS_HITS` 2): NOT VIABLE, reverted to 5. At the find the track was not in stock's `radar_targets` (`focus_found: no stock target object (radar_targets entry false)`), so there is nothing to focus; the focus came at 17 NM on 6 hits, the same as with 5. A contact seen on the scope from 25 NM is raw video until stock lists it as a target after enough paints. The hold (beam on the contact's elevation, cursor on its measured bearing) is the working substitute for TARGET_FOCUS. Possible later refinement: extrapolate the track's position between paints.
- F13. Between paints a held (or steered-to) contact's position is extrapolated from its fitted bearing drift and closure (`extrapolated`, at most `EXTRAP_MAX_S` 10 s since the last sample, 3+ samples needed), for the cursor, and for the held beam's range. Reason (7b v36): the cursor lagged a closing contact between paints (az -36 -> -43 while unpainted). Log: `cursor on the extrapolated contact position`.
- F14. Stock keeps its focus on a contact that has left the scope forever (found in the crossing test: the MiG left the gimbal at az +61 / 14 NM, the track stayed `present=false` for 94+ s, the scan zone stayed `TARGET_FOCUS`, narrow, the cursor where the contact vanished). No search follows because a search needs a cue and the cue had been satisfied and removed; stock sends no new report once the contact is out of the gimbal. Rule (v38): with no lock, a focused contact unseen for `FOCUS_RELEASE_LOST_S` (20 s) has the focus, highlight and pilot highlight dropped (`Search.GainHoldUpdate`, log `the focused contact ... has been off the scope for N s: dropping the focus`). Flown: the cursor re-centered and the radar returned to a normal scan. The pilot can return to scan sooner with a context double press (stock `State.Reset()`).
- Flown at 0.73 (v40/v41): crossing MiG-21 (co-altitude, 90 deg crossing from 52 NM, -37 deg at the start): found 45-47 NM, focused after 4-8 s, steady paint across the whole crossing (hits to 718), no interference from the RWR emitter pointed away. The hold phase and the extrapolation never ran long enough to see (the find and focus are too fast at 0.73): extrapolation is still unproven in flight; the cursor lines showed only at 0.1-1.6 s. Time acceleration is not used for tests: the radar, paints and hits are per frame, so thresholds behave differently.
- L1. Lock preparation (look-down only; Search_v50). Long press of the context button with a focus or highlight on a contact more than
  `LOCKPREP_MIN_DEPR_DEG` (0.5) below the horizon, nothing locked or being locked, no search running. The reason: a lock taken with the
  contact in ground clutter can land on the ground; flights 1-8 showed no signal that separates a good lock from a bad one (see the log
  of findings below), so the pilot judges the lock and unlocks / relocks with the context button as often as needed.
  - Paint already steady at the press (`LOCKPREP_STEADY_HITS` 4 paints in `LOCKPREP_STEADY_WINDOW_S` 6 s, newest within
    `LOCKPREP_PAINT_AGE_S` 2.5 s): `Search.PrepBegin` returns false and STOCK locks at once (`fast_lock_target`: the lock starts silently,
    the stable-lock call follows the lock). Nothing is said before the lock on this path.
  - Paint not steady: Jester says Roger on the press (audible feedback that he is working on it) and the prep waits (`Search.prep`, run from `Search.GainHoldUpdate` / `Search.HoldCursor`) and fires the stock
    long-press action (`p.fire`) at the first steady paint, with the cursor first sent to the extrapolated position + `LOCKPREP_LEAD_S`
    (`lead_cursor`, held `LOCKPREP_LOCK_HOLD_S`). The gain stays where the look-down gain hold put it (0.63, `SEARCH_DOWN_GAIN`): the gain
    walk-down and the regain were removed after they showed no benefit (the two locks where the walk had found a lowest steady gain were
    both bad).
  - While the paint is lost (`LOCKPREP_LOST_S`): the cursor goes to the extrapolated az / range (`LOCKPREP_EXTRAP_MAX_S` 25 s) and the beam
    elevation zone (`AAD_SEARCH`, relative) is re-aimed whenever the extrapolated elevation moves `LOCKPREP_ELEV_STEP_DEG` (0.3) or the
    range 3 NM; stock honors the zone while a focus exists (flown).
  - `LOCKPREP_MAX_S` (25): no lock, Jester says `radar/lostlock`, the focus is kept (timeout locks landed on the ground both times).
  - Stock moves the focus out for a moment when the paint is lost: `LOCKPREP_FOCUS_GRACE_S` (4) before the prep treats the focus as gone.
  - Canceled by a short or double press, by the focus moving or going, by a search starting; a second long press locks at once.
  - Log lines `lockprep: ...`.
  - Findings, beam bias and gain (flown, removed): bias of 1.5 / 2.0 / 3.0 deg on the lock and 0.5-2.0 deg on the focus kept the contact painting but gave no better locks; the only good locks were at about 7 NM and closer (one at 8.7 NM, a single sample). Stock's lock phase points the antenna at the contact each tick (`MoveRadarAntenna:FollowTarget`) and the radar's own track takes over about 1 s after the trigger (`mlc` drops 40 to 27 NM), so a bias can only act before the track starts. Look-down gains 0.60, 0.63, 0.65 and 0.73 gave the same result. The stock radar classes are sealed (assigning to the class errors): patch the live behavior instance. The unresolved cause is the radar's own lock gate picking a ground echo near the contact's range; nothing readable in Lua separates the cases.
  Findings (flights 1-8): bad locks at 26 NM (time limit), 10, 8, 9.4, 14.6 and 24.5 NM; good at 6 and 4.5 NM. The cursor was within ~0.3 NM
  of the contact at lock time (paint 0.3-0.9 s old), so cursor lag is not the cause. `postlock:` data (intended track, locked id, track
  state, skin, radar_targets) is identical for good and bad locks: a ground lock cannot be detected from Lua here. The "lock lost or
  abandoned" lines were the pilot breaking the lock by hand.
- TEST 1 (gain) RESULT: stock gain on the level geometry found B at 30 NM and focused at 29 NM (no gain lines; knob 0.7), so stock is fine near level elevation and the 'narrow window around 0.75' from the cards no longer holds. Gain was then fixed per run: see G7 for the up/level results and the chosen 0.73 / 0.55 / 0.73. Test lesson: every deploy must be checked by reading the device file back (content, not size) and the log must show the expected `gain -> X`; a deploy that reuses an earlier staged file name sent a stale copy (that also explains the 'reverted' Config and Search files seen earlier).
- C6b. Stock BRAA reports only its closest bogey but interleaves calls for farther groups (7b). A report more than `AWACS_NEW_CUE_NM` from the current awacs cue, farther than it, while that cue was refreshed within `AWACS_NEAR_HOLD_S` (45 s), is ignored (log `keeping the nearer bandit`); it neither moves the cue nor restarts its search. Reason: it dragged the search from B to E and cost ~40 s.
- C6a. Stock AWACS hot/cold is CLOSURE only (range decreasing/increasing), never aspect. Stock gets aspect points only
  from its measured track (3 calls). EWRS's word is real aspect. Closure: both velocities known -> geometry; else
  the range trend between calls; else (one stock call) hot = our own speed along the line of sight. Velocity comes
  from successive reports of the same group and is trusted after `AWACS_VEL_MIN_REPORTS` (3).
- C7. Gimbal: cues outside `CUE_START_AZ` are kept but not searched; `Cues.Best` re-checks every second, so a cue
  comes back when we turn or the contact drifts inside. An AWACS cue lives `AWACS_MAX_AGE_S` (90 s) and is
  dead-reckoned (after 3 reports) while not being searched. An RWR cue that expired outside the forward arc can
  cue again when the emitter comes back into it.
- C8. EWRS cues (`AWACS_EWRS_CUES`): one cue per group (`ewrs:N`), at most `EWRS_MAX_CUES` (5), highest threat first.
  Grouping needs both: within `AWACS_SAME_GROUP_NM` (8 NM) sideways AND within one radar bar vertically
  (`AWACS_GROUP_ALT_DEG` 2 deg at the contact's range, 3,000 ft floor up to 10 NM, about 6,400 ft at 30 NM, 12,000 ft
  cap); the highest-threat member leads. Cues persist across the 20 s pictures by the same test (1.5x looser): moved
  <= 3 NM keeps the search state, <= `AWACS_NEW_CUE_NM` keeps the cooldown, so a contact that cannot be found is not
  searched back to back. A group the picture drops goes away unless it is being searched. A group the stock-BRAA cue
  covers, or one stock already holds a track on, gets no cue. The stock reply keeps its single `awacs` cue and is a
  deliberate request (resets state).
  Test 9 (Oct 2026, scripted picture plus Overlord's stock calls, flown) added four rules:
  - C8a. Both directions of the stock/EWRS overlap: a stock reply whose contact is in the group of a live EWRS cue gets no cue of its
    own (`Cues.EwrsCovering`, Director.lua; log `awacs cue: stock ... is the group of ewrs:N: no cue of its own`). Before, the reply
    started a second search for a group already cued and pre-empted the search on another group.
  - C8b. Matching a picture to the live cues is global, nearest first (`Cues.SyncEwrs`): every (group, cue) pair inside the 1.5x allowance
    is ranked by distance and assigned once. Before, each group took its nearest free cue in threat order, so a group whose own cue had
    already been satisfied (and removed) could take a neighboring group's cue, and the neighbor got a new cue number.
  - C8c. A cue stands for the whole group: `count` = the group's members in the picture (`group_n`), and the cue stays open until that
    many tracks belong to it. Membership (`in_ewrs_group`, Cues.lua) is within 1.25 x `AWACS_SAME_GROUP_NM` of the cue's position and within
    1.5 x the grouping height, not the usual 8 deg / 10 NM of an IFF cue, since the aircraft of a group are spread over several miles. The
    existing `more_emitters_pending` logic then resumes the search for the missing aircraft (`group found, N emitter(s) not matched yet,
    resuming`). Before, one track satisfied a two-aircraft group and the other aircraft was never searched for. A new cue is created for a
    group only when fewer than `count` of its members are held. Known risk: two groups closer than about 10 NM can count toward each
    other's cue.
  - C8d. A group that is off the scope when a picture arrives (the beam is on another elevation) is cued again even if it was found
    earlier (held counts only while the track is present, C9f); it is satisfied again within a second when painted. Intended: a lost
    contact should be found again.
  - Auto Search: the Director starts a search on the best cue it does not hold yet (highest threat, not in cooldown, ready, inside
    `CUE_START_AZ`, tracks < count) whenever nothing is focused or highlighted. While stock holds a focus, `cannot start ewrs:N (focus)`;
    the double press (focus released, auto-focus held off 20 s) lets it run. Auto and pilot searches use the same `Search.Start`; the first
    band is the correlated cue elevation, applied on the first tick. Only a cursor cue waits (`CURSOR_SETTLE_S` 0.3 s after the cursor stops).
- C9. Stepping (short context press). One list of entries, one per contact, and the pilot must be able to reach every contact in a
  stable order without anything else moving the radar or the cursor. Flown in test 8 (Oct 2026, EWRS emulator, three groups,
  two of them RWR emitters); each rule below fixed a failure seen in that log.
  - C9a. Entries and order: ordered by threat. An EWRS group within `AWACS_RWR_TOL_DEG` (+ the emitter's spread) of an RWR emitter's
    bearing is that emitter: the EWRS cue is `rwr_covered` (hidden from `Best`, `Ordered` and stepping; one to one, nearest bearing
    first) and the RWR cue takes its range/bearing through `Awacs.Elevation`. Cues outside the gimbal limits are skipped.
  - C9b. The cue order (`Cues.NextAfter`, used when no bandit is on the scope) is frozen for `STEP_FREEZE_S` (6 s) after the last press: new
    entries join at the end, gone ones drop out. The bandits are not stepped in threat or range order (stock's list is by range and
    reshuffled between presses as the contacts closed at different speeds, test 8) but as a sweep, C9c.
  - C9c. Sweep (`fix_next_bandit`, Fixes.lua; supersedes the frozen bandit order and the wrap-to-cue rule of v61-v62): the stepping list is
    ordered by azimuth, left to right. A press moves to the neighbor in the current direction; at an end it turns round and moves to
    the neighbor on the other side (A B C D from B: C D C B A B C ...), never repeating the end contact. The direction is remembered
    without a time limit and changes only at an end. With nothing highlighted the first press goes to the leftmost bandit. Stock asks for
    the next bandit twice per press with the same reference, so a repeat within 1.5 s gives the same answer (`same_press`). A press only
    ever steps: at the ends it does not start a cue search (a search started from an end ended on a contact further along and the
    neighbor was skipped, test 9). Only when there is no bandit on the scope does `Search.ContextShort` search the next cue.
  - C9g. What is in the sweep (`step_list`): stock's bandit list entries that the radar painted within `STEP_MAX_AGE_S` (15 s), contacts
    stock has not identified yet (not friendly, at least `STEP_UNID_MIN_HITS` 3 hits, painted within `STEP_MAX_AGE_S`) after a found
    contact's call-out was pre-empted, and the highlighted contact always, because a contact just found or just focused is missing from
    stock's lists for a few seconds and without it the press has no position in the sweep and jumps to an end (skip, test 9). The age
    limit matters: a contact unpainted for 20 s has its focus dropped by `FOCUS_RELEASE_LOST_S`, so stepping onto a stale contact only
    repeated the same press. A contact that is not in the sweep (off the scope, or never found) can only be reached by a search.
  - C9d. A search the pilot started (`Search.auto` false) is never pre-empted or taken over by the Director's threat logic
    (Director.lua: both pre-empt branches require `Search.auto`), and `Search.ContextShort` holds the Director's auto-starts off for
    `STEP_FREEZE_S` (`Cues.suppress_until`) on every short press, so neither moves the cursor while the pilot steps.
  - C9e. A search the pilot started holds stock's auto-focus off for its whole duration, whatever the cue (`manage_auto_focus`, capped
    by `SEARCH_AUTOFOCUS_MAX_S`). Before, only a cue with more emitters than tracks did; with a single-emitter cue stock refocused the
    nearest bandit within 0.1 s (`focus seen ... handover: focus after 0.1 s`) and the press never got past the middle contact.
  - C9f. A cue source in `CUE_NEEDS_HELD` (RWR, AWACS, which includes EWRS cues) ends when stock holds the track, so a contact the radar
    already tracks is found at once and the pilot search focuses it (`focus_found`).
- C10. Pilot slew: the cursor cue is matched against every stored contact (not only the one that became a cue), within
  the position uncertainty (about 5 NM, growing with report age), for elevation and a bearing snap within 10 deg.
- C11. Stock's background scan stands still while the engagement state is TRANSITION (a bandit inside `TRANSITION_NM`, 5 NM) or BFM
  (dawger #5). Stock already stops it when the radar is caged, CAA or in boresight, and inside 1.75 NM; this covers the uncaged
  stretch out to 5 NM. G is deliberately not used (inside 5 NM Jester is heads out). Implemented as `scan_frozen()` in
  Search.lua, checked in the `Radar.FindNextPhase` wrapper after `Search.Step` and before stock's function. Never frozen while: a
  lock is requested or held, our search is not idle, or a lock prep runs (they all use stock's phases). Our own cue searches may
  still start in TRANSITION. Resumes by itself when the state returns to BVR or NONE. Log lines `scan: stock background scan frozen|resumed`.
- C12. Scan direction for a cursor cue with no known elevation (13 Oct 2026). If the pilot has bumped the cursor up or down
  (`Modes.vert_dir`, +1/-1, nil until the first bump) and neither AWACS nor EWRS gives the cue an elevation, `build_bands` scans only
  that side: level, the bump side (5 bands up of 3.5 deg, or 4 down of 2.5 deg), then back to level and the same side again
  (`SEARCH_BUMP_LAPS` 2 laps in all). The other side is never scanned. A scan the pilot interrupted still starts with its `first_angle`.
  With no bump yet (`vert_dir` nil) the old pattern applies (level, up, then down, or down first if the stock elevation command was
  below level). RWR and BRAA cues (Director starts them with no `dir`) and cues with a known elevation are unchanged. Log line
  `search: bump up|down: N lap(s) of level then M band(s) ... only`; the cursor log says `bump up|bump down|no bump, up`.
  `vert_dir` is the last vertical move and is not cleared between searches.

## Regression sequence (replay after every change; paste the log lines that fail)

Scenario: one target about 40 NM ahead, high, so it is above the horizon; AWACS BRAA calls on. Steps 1-6 are gain and
focus; 7-9 are cue order and stepping (EWRS needs the scripted AWACS picture on).

1. RWR cue only, no BRAA yet. Expect: search starts, `level/up (elevation unknown)` 0.73, contact found, focused,
   `keeping gain 0.73 while the contact is held`. Knob stays 0.73. No `stock gain settings back`.
2. BRAA call while the contact is focused. Expect: no restart on the same contact; the elevation is learned.
3. Take control, drop focus, give control back. Expect: knob unchanged for at least 15 s, then back to stock.
4. New BRAA call with nothing focused. Expect: `search: start awacs`, cursor sent to the BRAA position,
   `look-up (contact above)` 0.73 on every bar, found and focused, `keeping gain 0.73`, knob stays 0.73.
5. New BRAA call while a focus sits on a contact that left the scope. Expect: `dropping the focus on a contact that
   left the scope`, then step 4.
6. Slew the cursor away and back during a search. Expect: `keeping look-up gain 0.73 after the pilot slew`, no dip to
   0.59 between searches.
7. Threat order: an RWR emitter ahead, and BRAA calls on a different bogey. Far (30+ NM) or cold: the emitter is
   searched first (`cue: searching rwr:... first`, BRAA listed as `waiting`). Closing fast inside about 15-20 NM: the
   BRAA wins. Turn the BRAA contact outside 58 deg: `outside the gimbal limits`, no search; turn back: it is searched.
8. Stepping: an RWR emitter on a bearing with an EWRS group in the same sector, plus a second EWRS group elsewhere.
   Setup used (needs the EWRS text; `aad_ewrs_emulator.lua` in a MISSION START DO SCRIPT sends it every 20 s from the red aircraft):
   group A at 010 deg / 40 NM / 20,000 ft inbound with its radar on, group B at 330 deg / 35 NM / 20,000 ft with its radar off, a
   third at about 037 deg / 50 NM; contacts 23-40 NM so stock's 30 NM auto-focus limit is crossed. Check `aaplus_messages.txt` has
   `EWRS : picture` lines.
   Expect `cue: ewrs:N is the emitter rwr:M ... one entry`; context presses go emitter -> other group -> cursor/stock
   cues, never the merged twin; two quick presses do not reshuffle the order.
9. Grouping and sweep (flown, Oct 2026, `aad_ewrs_emulator_v2.lua`, player 12,000 ft ~400 kt heading 360; fixed-wing pairs 5-6 NM apart at
   350/000 deg 30 NM (20,000 and 23,000 ft: one cue, 2 emitters) and 030/040 deg 30 NM (20,000 and 28,000 ft: two cues), a helicopter at
   320 deg 25 NM 12,000 ft heading 140 at ~80 kt, all radars off, Overlord on). Expect `ewrs: 4 group(s) in the picture`; the helicopter
   ranks last (`CH-47` -2.0 class); a stock call in an EWRS group logs `is the group of ewrs:N: no cue of its own`; the two-aircraft group
   is searched until both tracks exist (`ewrs:1 satisfied by 2 track(s)`); short presses sweep left to right and back with
   `fix: next bandit ... (rightwards|leftwards[, turned round]; sweep id@az ...)`, no contact in the middle skipped, no press repeated on a
   stale contact (no `off the scope ... dropping the focus` during stepping). The closure is 700 kt, much faster than real, so judge the
   first pictures. `fix: not in the sweep: ...` (temporary diagnostic) lists what was left out and why.

10. Far contact that paints well (player 3,000 ft, contact 12,000 ft, ~37 NM, 16 deg off the nose): one slew onto the
    IFF return, hands off. Expect `painted once ... aiming the beam at it` (or a direct find), `found`, `holding the beam`,
    `contact has N hits: focusing it ahead of the call-out` within about 10 s, the cursor on the contact, stock's call-out
    afterwards, no `focus_found: not focusing` line.
11. Same with the contact 25,000 ft / player 12,000 ft (+3.4 deg): known limitation (paints about once per 25 s). Expect
    the hold to run to `hold timeout` and no call-out; the player locks manually. Not a regression.
12. Cursor cue off the contact by up to 7 deg: Expect no `resuming`; the contact found is handled as in 10.
13. Scan freeze (C11): fly a bandit in from 10 NM to inside 5 NM with the radar uncaged and no lock. Expect `engagement BVR -> TRANSITION`
    then `scan: stock background scan frozen (engagement TRANSITION)`, no new `radar` phase work (the antenna stays where it was), and
    `... resumed` after the bandit goes back outside 5 NM (BVR). A manual lock inside 5 NM must still complete and the IFF challenge
    must still run. A BRAA or RWR cue inside 5 NM may still start a search (it is not frozen while the search runs).
14. Bump scan (C12; flown 13 Oct 2026, passed): with a bandit at a different elevation and no AWACS/EWRS cue, bump the cursor up (stick forward) and release it
    at the bearing. Expect `cursor: settled ... bump up first`, `search: bump up: 2 lap(s) of level then 5 band(s) up only`, band
    angles 0, 3.5 ... 17.5, 0, 3.5 ... 17.5 and no negative angle. Repeat with a bump down: 0, -2.5 ... -10, twice, no positive angle.
    First search of the mission with no bump: `no bump, up` and the full pattern (up then down). A bandit on the wrong side is NOT found
    (by design).

Pass means: the knob never reads stock between steps 1 and 6 except after the stated release.

## Known issues / later

- Stock and EWRS reports of the same contact are not fused (the cue holds the contact that last wrote it, so it can
  lose the other source's type, aspect or range trend). Idea: treat a stock and an EWRS contact within the group test
  as one; type/aspect from EWRS, range trend from the source with more reports.
- RWR contacts DO carry a distance: `range`, 0 at the scope center to 1 at the edge, about 0.0111 per NM
  (`RWR_RANGE_SCALE_NM` 90; measured 0.388 at 36 NM, 0.322 at 30 NM, 0.273 at 25 NM). Stock also has a `priority` field
  (90-120 on the live emitter, 3-5 on one behind) that is not used yet. `LOG_RWR_FIELDS` is the diagnostic (off).
- Aircraft-type filter for bearing-only RWR matches is not done.
- Gain: 0.73 up / 0.63 down (G7) were tuned on one map and a few geometries. Still to fly at 0.73: weak target (F-5/MiG-21), altitude offsets, crossing target, the long hold.
- LIMITATION (documented, no workaround yet): a contact well above the player (about +3 deg, e.g. 25,000 ft target
  seen from 12,000 ft at 36 NM) paints only about once per 25 s at the old 0.75 gain, nose-on or not, so stock never gets
  enough paints to call it out or focus it. The same contact 9,000 ft above (+2.3 deg) painted steadily and was
  called out at 33 NM. Players must start the lock themselves (HCU full action) on high-elevation contacts at long
  range. Ruled out: beam elevation, bearing, gain, scan type/zone. Unknown: antenna elevation roll-off or target
  altitude effect in the sim. Revisit if a way around it turns up.
- The scenario in `gain_card_results.md` (player 3000 ft, contact 12000 ft head-on from 45 NM) is the reference for
  a healthy paint rate.

## Shipping checklist

- DONE (13 Oct 2026): `excluded_report` / `fix: not in the sweep` and `Fixes.StepWouldReverse` removed; shipped with `LOG_TO_FILE = false`
  and `AWACS_LOG = false` (set `LOG_TO_FILE = true` for a test run; the file is `aaplus\aaplus.log`); the 90/120 s gain-hold
  limit removed (G2).
- DONE (13 Oct 2026, final cleanup): `LOG_TO_FILE = false` confirmed in the deployed Config (it had been on for the dawger #5 test);
  `Probe.lua` deleted; every file in both mods passes `luajit -b`.
- BRAA/EWRS cues need `io` de-sanitised in `Saved Games\Scripts\missionscripting.lua` and the hook
  `Scripts\Hooks\AAPlusMessages.lua`; without `io` AWACS cues stay off (one log line says so).
- `Config.AWACS_FILE` is built from `Config.SAVED_GAMES`; `AWACS_DECL` (stock 4.0, EWRS 2.5) was
  measured on Caucasus (this test map read about +5); other maps are now corrected by the table in v78.
- Report to Heatblur: radar-launched missile detection in Jester (see the survivability notes).

## Changelog (newest first)
- v80 (14 Oct 2026): a map with no entry in `Awacs.MAGVAR` (a new release) is taken as 0 degrees of variation (was the Caucasus figures), with one log line; no map name at all (old hook) still keeps the Caucasus figures. Removed the `Sinai` and `SouthAtlantic` aliases (MOOSE's `DCSMAP` names are `SinaiMap` and `Falklands`). Hook header comment no longer says 'test only'.
- v78 (14 Oct 2026): per-map magnetic variation for AWACS/EWRS bearings. The hook writes `---- simulation start ---- theatre=<map>`; `Awacs.lua` keeps a table (`Awacs.MAGVAR`, degrees east, the per-map values from MOOSE `UTILS.GetMagneticDeclination` keyed by DCS theatre name: Caucasus 6, Nevada 12, Normandy -10, PersianGulf 2, TheChannel -10, Syria 5, MarianaIslands 2, Falklands 12, SinaiMap 4.8, Kola 15, Afghanistan 3, Iraq 4.4, GermanyCW 0.1; optional override `Config.MAGVAR`) and applies `AWACS_DECL[source] + MAGVAR[map] - MAGVAR[Caucasus]`. A map not in the table and an old hook with no theatre field fall back to the Caucasus figures, with one log line. Approximate: the variation also changes with the mission date. Needs a DCS restart for the hook. Flown: not yet.
- v77 (rename, 13 Oct 2026): A/A Director -> Jester A/A+ (folder and require paths `aaplus`, launcher `LaunchAAPlus.lua`, wheel entry `A/A Plus`, log prefix `[AA+]`,
  log `aaplus\aaplus.log`, hook `AAPlusMessages.lua` writing `Logs\aaplus_messages.txt`); Survivability Suite -> Jester Survivability (folder unchanged). Internal
  identifiers (`AADLog`, `AAD_SEARCH`, event names) keep their old spelling on purpose. No logic change. Retest: wheel entry present and mode switching, a search, AWACS cues.
- v75 (13 Oct 2026): Config_v72: `SEARCH_TIMEOUT` 3 -> 0. The last elevation band used to dwell `dwell + SEARCH_TIMEOUT` (Search.lua, in `Search.Step`) before the
  search ended; it now dwells like every other band.
- v74 (scan direction, 13 Oct 2026): Search_v63 (bump-only laps, C12), Modes_v2 (`vert_dir` starts nil), Config_v71 (`SEARCH_BUMP_LAPS`).
  Flown 13 Oct 2026 (test 14): done, user satisfied.
- v73 (final cleanup, 13 Oct 2026): Config_v70 (`LOG_TO_FILE` back to false after the dawger #5 test run). No logic change. Jester Survivability cleaned
  in the same pass (temporary logger removed, its log off). Baseline: `baseline_2026-10-13_final`.
- v72 (dawger #5, 13 Oct 2026): Search_v62: `scan_frozen()` (C11, test 13). Trigger is the engagement state (TRANSITION or BFM), not dawger's
  10 NM and 4 G. Flown 13 Oct (test 13): `frozen` after NONE -> TRANSITION, `resumed` after the bandit left; user happy.
- v71 (shipping cleanup, 13 Oct 2026): Fixes_v10 (diagnostic and `StepWouldReverse` removed), Search_v61 (gain held while the contact is worked, no time limit),
  Config_v68 (`LOG_TO_FILE` and `AWACS_LOG` off, `SEARCH_UP_GAIN_HOLD_MAX_S` removed). Baseline: `baseline_2026-10-13`. Next: dawger #5 and #6.
- v63-v70 (test 9, stepping sweep and group cues): C8a-C8d, C9b/C9c rewritten, C9g added. Cues_v24 (global cue matching, `EwrsCovering`,
  group `count`, `in_ewrs_group`), Director_v25 (stock reply covered by an EWRS cue), Fixes_v9 (azimuth sweep with turn-round, remembered
  direction, highlighted contact always in the list, `STEP_MAX_AGE_S`, unidentified contacts, diagnostic), Search_v60 (end presses only
  step), Config_v67 (`STEP_MAX_AGE_S`, `STEP_UNID_MIN_HITS`; `STEP_FREEZE_S` now only for the cue order). Test 9 flown and passing.
- v61-v62 (stepping, test 8): C9 rewritten as C9a-C9f. `Search.last_cue` and next-after-last wrap (Search_v56), pilot searches not pre-empted and short presses hold off auto-starts (Search_v57, Director_v24), frozen stock bandit cycle (Fixes_v3), auto-focus held for any pilot search (Search_v58). EWRS emulator `aad_ewrs_emulator.lua` for the regression flights. Device files after this change: Search 85,408 B, Director 12,983 B, Fixes 12,860 B, Config 23,617 B; the local Fixes.lua before Fixes_v3 was older than the device's.
- v55-v60 (beam-bias experiments, all removed in Search_v55 / Config_v63): beam bias on the lock (1.5, 2.0, 3.0 deg) and on the focus (0.5, 1.0, 2.0 deg) via the pilot scan zone plus an override of `MoveRadarAntenna:UpdateAntennaData` on the live instance; look-down gain 0.65 and 0.73 flown. None separated good from bad locks (see L1 findings). Code, `LOCKPREP_BEAM_BIAS_DEG`, `FOCUS_BEAM_BIAS_DEG` and the temporary diagnostics (`focuswatch`, `hold:`, `find_catch`, `focus_found`, `focus idle`, `postlock:`, `lockprep: cursor`, `context press:`) removed; `SEARCH_DOWN_GAIN` final 0.63.
- v50-v54 (lock preparation, simplified): gain walk and regain removed (gain stays 0.63), steady-paint presses go straight to stock's lock, the prep waits silently otherwise, no Roger, timeout = lost-lock call, cursor lead at lock, focus grace. `LOCKPREP_*` now: MIN_DEPR_DEG, STEADY_HITS, STEADY_WINDOW_S, PAINT_AGE_S, LOST_S, EXTRAP_MAX_S, ELEV_STEP_DEG, FOCUS_GRACE_S, LEAD_S, LOCK_HOLD_S, MAX_S.
- v43-v45 (look-down lock preparation): L1 and the `LOCKPREP_*` settings (Config_v46), `Search.PrepBegin/PrepUpdate/PrepCursor` (Search_v41); look-down gain tests 0.60 and 0.63 flown (steady paint from about 10 and 12-14 NM against 6 NM at 0.55; the 30-14 NM flicker stays), 0.63 now set, 0.65 to be flown for data.
- v38-v42 (gain tuning and lost-focus release): gains 0.73 up/unknown, 0.55 down (G7); `FOCUS_RELEASE_LOST_S` 20 (F14); temporary `focus idle` diagnostic in `Search.GainHoldUpdate` (remove before shipping). Test flights done: 1 (gain), 2 (crossing), 4 (weak target), 6 (no RWR cue), 7c partly (gimbal exit). Test 3 (long hold / extrapolation) counted as covered by the look-down flights of Oct 2026 (hold of about 28 s with the cursor on the extrapolated position, last paint up to 9.9 s old at about 33 NM; lock-prep carried the cursor and beam for 25 s). Test 5 (altitude offsets) counted as done (look-down flown many times). Test 7c done (Oct 2026): BRAA cue at az -89 logged `outside the gimbal limits (az -89), kept until it comes inside`, no search while outside; the search started at az -57 once inside 58 deg. The same flight was a look-up search at 0.73 (`look-up (contact above)`, found at 32 NM, focused ahead of the call-out, `keeping gain 0.73`). Test 8 (stepping) flown with the EWRS emulator; after the fixes in C9b-C9e the pilot reaches all three contacts (user: working great). Still open: 9 (grouping).

- A search that has found nothing for 20 s yields to a higher-scoring cue by `CUE_STALL_MARGIN` (`CUE_STALL_S`, `Search.Age`), and to any waiting cue that is CLOSER (`Cues.RangeOf`), even one scoring lower (7b: a far unpaintable emitter held the radar 78 s while the bandit closed to 9 NM).
- Far contacts (beyond 30 NM): focus at once when they have 5+ hits, else hold the beam on them until stock calls them out instead of forcing a focus (F4); focus a far call-out (F6); aim the beam at a one-hit contact and stay on it (F5); a cursor cue never "resumes" for more emitters; knob re-asserted while holding. The follow function (old F4) was removed. Temporary diagnostics added (see shipping checklist).
- Re-aim the beam at a found contact's own elevation before the handover (F3); temporary `focuswatch` diagnostic.
- RWR scope distance (`range` x 90 NM) feeds the threat score of emitters with no AWACS contact.
- Grouping also needs an altitude test (one radar bar at the contact's range) (C8). DESIGN.md reorganized.
- EWRS cues on, one per group; EWRS groups that are RWR emitters merge into the emitter; context stepping is
  threat-ordered and frozen for 6 s after each press (C8, C9).
- Aircraft class from EWRS type; stock hot/cold treated as closure only.
- Threat order uses aspect, time to merge and measured speed; BRAA no longer restarts an RWR search; gimbal
  re-evaluation (C7).
- Threat-ordered searches (C6): `Cues.Threat`, `Cues.MoreUrgent`, `Config.CUE_THREAT`, `CUE_SWITCH_MARGIN`.

- Cleanup for shipping: tuning logs, Probe and the gain test block removed (Probe.lua is unreferenced and can be
  deleted); gains 0.73 up / 0.55 down / 0.73 unknown (G7); AWACS cues turn on only if `io` is available.

- Stock targets read through `tid()` (userdata fix) in Search.lua and Cues.lua; hold upgrades 0.65 to 0.75 once the
  contact is above the horizon; follow-hold diagnostic.

- Focus on a lost contact no longer blocks a search; carry a held gain into the next search; `preempted` keeps the
  gain; `SEARCH_UNKNOWN_GAIN` for no-elevation searches.
- "Called out" only counts as held while the track is present.
- Interrupted search keeps its gain; the knob is put back only if no search follows within 3 s.
- Gain hold after found/handover; focus beyond 30 NM; one gain per pattern; stock auto-gain skipped.

## Periodic IFF challenge (Nov 2026, Iff.lua)
- Director subsystem `iff` (1 s). Not in OFF, not in BFM. Presses the IFF challenge (Api.ClickIffButton, a task needing the hands, priority `IFF_PRIORITY` 1.5 so it is not queued behind the radar scan tasks) every `IFF_PERIOD_S` (15), with or without radar contacts; at once on a contact not seen for `IFF_NEW_FORGET_S`; at once on a lock. Minimum gap `IFF_MIN_GAP_S`; a challenge is not stacked on one still waiting; a held-back lock or new contact goes out when the gap is over.
- Gate: radar active and powered, Radar Mode not OFF/STBY, A2A context, not dogfight/boresight, Video Select in `IFF_VIDEO_RADAR_STATES` (OFF) and Screen Mode in `IFF_SCREEN_RADAR_STATES` (radar). Both read off a flight log: with the radar on the scope Video Select = OFF, Screen Mode = radar, Radar Mode = MAP. The positions for the Pave Spike and Maverick pictures have not been read; any other value refuses.
- Lesson: a wrong guess for the video position made the feature silently never fire, and stock's own ~34 s challenges looked like it working. IFF_LOG_KNOBS logs the three knob positions whenever they change.
