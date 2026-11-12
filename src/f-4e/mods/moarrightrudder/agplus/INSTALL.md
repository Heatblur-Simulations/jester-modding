# Jester A/G+ - Install guide

Version 1.0.0. Takes about five minutes. Jester's own Lua cannot read DCS's stores, cockpit buttons or terrain, so A/G+ uses small read-only "feed" scripts that run inside DCS and write text files for the mod to read. They change nothing in the sim.

`Saved Games` means the folder that holds your `DCS` (or `DCS.openbeta`) and `DCS_F4E` folders. Close DCS before you start.

## Steps

1. **The mod.** Open `Saved Games\DCS_F4E\jester\mods` (create the `mods` folder if it is missing). Drag the folders `agplus` and `init` from this download into it. When Windows asks, choose **Copy and Replace**. The folders merge into yours and only A/G+ files are added; nothing of yours is deleted.
2. **The feeds.** Open the folder `_EXTRA (DCS Scripts)` and drag the folder `Scripts` into `Saved Games\DCS`. Open beta: drag it into `Saved Games\DCS.openbeta` instead. Choose **Copy and Replace**; only A/G+ files are added.
3. **Export.lua.** This is the one file you must not simply copy over, because other programs (Tacview, SRS, DCS-BIOS) use it too and a copy would overwrite theirs. Open the folder `Export.lua` inside `_EXTRA (DCS Scripts)`; its `READ ME.txt` repeats this step.
   - **You have no `Saved Games\DCS\Scripts\Export.lua`:** drag and drop the `Export.lua` from that folder into `Saved Games\DCS\Scripts` (`DCS.openbeta` for open beta). Done.
   - **You already have an `Export.lua`:** leave it where it is. Open it in Notepad, go to the very end, and paste this line on a new line. Save. Do not delete anything else.

   ```
   pcall(function() local l=require("lfs"); dofile(l.writedir()..[[Scripts\AGPlus\AGPlusLoad.lua]]) end)
   ```
4. **Paths.** Open `Saved Games\DCS_F4E\jester\mods\agplus\Config.lua` in Notepad and set the three paths in section 1: `SAVED_GAMES` (your Saved Games folder), `DCS_SAVED_FOLDER` (`'DCS'` or `'DCS.openbeta'`) and `DCS_INSTALL` (your DCS World folder). Save.
5. **Restart DCS.** Feeds and hooks load only when DCS starts; a mission restart is not enough.

## What goes where

| Folder | Contents |
|---|---|
| `DCS_F4E\jester\mods\agplus` | The mod. |
| `DCS_F4E\jester\mods\init\agplus` | The launcher that loads it. |
| `DCS\Scripts\AGPlus` | The feeds (`AGPlusFeed.lua`, `BombBtnFeed.lua`, `PaveProbeFeed.lua`), the loader `AGPlusLoad.lua` and `MessageOverlay.dlg`. |
| `DCS\Scripts\Hooks` | `PaveProbeHook.lua` and `PaveDebugHook.lua`. |

What each feed does: `AGPlusFeed` gives the Weapon readout, Mavericks, bomb types and After Launch. `BombBtnFeed` lets Jester see your pickle and ARR button (Maverick hand-over, launch detection, pod freeze on release). `PaveProbeFeed` and `PaveProbeHook` give look-there, searches and line of sight. `PaveDebugHook` and `MessageOverlay.dlg` show Jester's on-screen messages and target lists. Without a feed the matching feature does nothing; the rest still works. To switch one feed off, delete its name from `AGPlusLoad.lua`.

## Check it works

1. Start a mission in the F-4E and wait about ten seconds.
2. In `Saved Games\<DCS folder>\Logs` these files should exist: `agplus_payload.txt`, `bombbtn.txt` and `pavespike_probe_view.txt`.
3. In the cockpit, open the Jester wheel: Air To Ground > A/G Plus. The center text names the weapons you have loaded.

If a file is missing, open `Logs\dcs.log` and search for `AGPLUSFEED`, `BOMBBTN` or `PAVEPROBE`. For a bug report, set `LOG_TO_FILE = true` in `Config.lua` and send `agplus\agplus.log` with the mission.

## Updating

Copy your `Config.lua` somewhere safe, drag `agplus` and `init` in again and the `Scripts` folder again (Copy and Replace), then put your `Config.lua` back (copy any new keys from the new file into it). Restart DCS. If you installed an older version that added three lines to `Export.lua`, delete those three and use the single line instead.

## Removing

Delete `mods\init\agplus` to switch the mod off. To remove the feeds, delete the A/G+ line from `Export.lua`, the two hook files from `Scripts\Hooks` and the `Scripts\AGPlus` folder.

## Troubleshooting

- **Weapon shows nothing / Mavericks not recognized:** `agplus_payload.txt` is missing or empty. Check the `Export.lua` line and `DCS_SAVED_FOLDER`.
- **Jester does not hand over when you press ARR:** `bombbtn.txt` is missing or has no `aar=` field. Check that `BombBtnFeed.lua` is in `Scripts\AGPlus` and restart DCS.
- **No on-screen messages (no Context List):** `PaveDebugHook.lua` or `Scripts\AGPlus\MessageOverlay.dlg` is missing, or DCS was not restarted.
- **Look-there or search does nothing:** `PaveProbeFeed.lua` or `PaveProbeHook.lua` is missing, DCS was not restarted, or the server has object export off.
- **Another export script stopped working:** a script before the new line is probably failing. Remove the A/G+ line, restart DCS, and add it back.
