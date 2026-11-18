# Jester Survivability - Install guide

Version 1.0. Takes about two minutes. The basic mod is two folders, `survivability` and `init`, and covers IR missiles and visible SAMs. Radar-guided missiles such as the AIM-7 need an optional feed, described below.

`Saved Games` means the folder that holds your `DCS` (or `DCS.openbeta`) and `DCS_F4E` folders. Close DCS before you start.

## Steps

1. **Drag and drop.** Open `Saved Games\DCS_F4E\jester\mods` (create the folders if they do not exist). Drag the folders `survivability` and `init` from this download into it. When Windows asks, choose **Copy and Replace**. The folders merge into yours and only Survivability files are added; nothing of yours is deleted.
2. **Path.** Open `Saved Games\DCS_F4E\jester\mods\survivability\Config.lua` in Notepad and set `Config.SAVED_GAMES` (the line marked `PATH TO EDIT`) to your Saved Games folder, for example `C:\Users\Pat\Saved Games` or `A:\Saved Games`. It is the only path to edit. Save.
3. **Start DCS.** In a running mission, LShift+R restarts the mission and reloads Jester's Lua.

## Optional: the object feed

The sim never hands Jester a semi-active radar missile (AIM-7, R-27R/ER and similar). The only way to see one is DCS's object export. Without the feed those missiles get no call and no countermeasures, and the singer call for a ground launch comes late or not at all.

1. **The feed script.** Drag the folder `Scripts` from `_EXTRA (DCS Scripts)` into your DCS folder inside `Saved Games` (`Saved Games\DCS`, or `Saved Games\DCS.openbeta` for open beta). Choose Copy and Replace; it merges with your own `Scripts` folder and adds only the feed script. It adds `Scripts\SurvFeed.lua`.
2. **Export.lua (one line).** This file is not drag and drop, because other programs (Tacview, SRS, DCS-BIOS) use it too and a copy would overwrite theirs. Add this line at the very end of `Saved Games\DCS\Scripts\Export.lua` on a new line, creating the file if you have none. Delete nothing else.

   ```
   pcall(function() local l=require("lfs"); dofile(l.writedir()..[[Scripts\SurvFeed.lua]]) end)
   ```
3. **File access for Jester's Lua.** Jester's Lua needs the `io` library to read the feed file. In `<DCS install>\Scripts\MissionScripting.lua`, comment out the `sanitizeModule('io')` line. This gives every mission script access to the files on your PC, which is a risk if you load missions you do not trust. A DCS update puts the line back.
4. **Multiplayer.** The server must allow object export. On a server that does not, the feed is empty.
5. **Restart DCS completely.** `Config.FEED.path` already points at the feed file, built from `Config.SAVED_GAMES`.

## What goes where

| Folder in this download | Goes to |
|---|---|
| `survivability` | `Saved Games\DCS_F4E\jester\mods\survivability`: the mod, `Config.lua` and `NOTES.md`. |
| `init` | `Saved Games\DCS_F4E\jester\mods\init`: the launcher that loads the mod. |
| `_EXTRA (DCS Scripts)` (optional) | Its `Scripts` folder goes into `Saved Games\DCS` (or `DCS.openbeta`): `SurvFeed.lua`, the feed script that Export.lua loads. |

## Check it works

1. Start a mission in the F-4E.
2. Open the Jester wheel: Systems. The Setup ALE-40 item should be there.
3. For the feed, set `LOG_TO_FILE = true` in `Config.lua` and start a mission. `mods\survivability\survivability.log` should contain a line reading `feed status: ... object export looks ON`.

## Updating

Copy your `Config.lua` somewhere safe, drag the folders in again (Copy and Replace), then put your `Config.lua` back (copy any new keys from the new file into it). Restart DCS.

## Removing

Delete `mods\init\survivability` to switch the mod off, and `mods\survivability` for a full removal. To remove the feed, delete the SurvFeed line from `Export.lua` and delete `SurvFeed.lua`.

## Troubleshooting

- **Nothing happens:** confirm `mods\init\survivability` exists. Set `LOG_TO_FILE = true` and read `mods\survivability\survivability.log`. The log needs the `MissionScripting.lua` step.
- **No call for radar-guided missiles:** the feed is not running. Look for the `feed status` line in the log, and check the Export.lua line, the `io` edit and that DCS was fully restarted.
- **Another export script stopped working:** a script before the new line is probably failing. Remove the Survivability line, restart DCS, and add it back.
- **A singer call says "unknown":** no system type was found. Send the log line to the author.
