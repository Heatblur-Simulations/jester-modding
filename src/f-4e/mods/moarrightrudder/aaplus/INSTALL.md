# Jester A/A+ - Install guide

Version 1.0. Takes about two minutes. The basic mod is two folders, `aaplus` and `init`. AWACS, BRAA and EWRS cues need an optional hook and one security change, described below.

`Saved Games` means the folder that holds your `DCS` (or `DCS.openbeta`) and `DCS_F4E` folders. Close DCS before you start.

## Steps

1. **Drag and drop.** Open `Saved Games\DCS_F4E\jester\mods` (create the folders if they do not exist). Drag the folders `aaplus` and `init` from this download into it. When Windows asks, choose **Copy and Replace**. The folders merge into yours and only A/A+ files are added; nothing of yours is deleted.
2. **Path.** Open `Saved Games\DCS_F4E\jester\mods\aaplus\Config.lua` in Notepad and set `Config.SAVED_GAMES` (the line marked `PATH TO EDIT`) to your Saved Games folder, for example `C:\Users\Pat\Saved Games` or `A:\Saved Games`. It is the only path to edit. Save.
3. **Start DCS.** In a running mission, LShift+R restarts the mission and reloads Jester's Lua.

## Optional: AWACS, BRAA and EWRS cues

Without this, A/A+ still searches from the RWR and the cursor, and the AWACS feature stays off (one log line says so). The cues need two things:

1. **The hook.** Drag the folder `Scripts` from `_EXTRA (DCS Scripts)` into your DCS folder inside `Saved Games` (`Saved Games\DCS`, or `Saved Games\DCS.openbeta` for open beta). Choose Copy and Replace; it merges with your own `Scripts` folder and adds only the hook. It adds `Scripts\Hooks\AAPlusMessages.lua` and writes `Logs\aaplus_messages.txt`. `Config.AWACS_FILE` already points at that file.
2. **File access for Jester's Lua.** Jester's Lua must be allowed to read that file, which means turning the `io` library back on. In `<DCS install>\Scripts\MissionScripting.lua`, comment out the `sanitizeModule('io')` line. This gives every mission script access to the files on your PC, which is a risk if you load missions you do not trust. A DCS update puts the line back, and the AWACS cues stop until you repeat the edit.

Then restart DCS completely once, because hooks load only at start-up.

## What goes where

| Folder in this download | Goes to |
|---|---|
| `aaplus` | `Saved Games\DCS_F4E\jester\mods\aaplus`: the mod, `Config.lua` and `DESIGN.md`. |
| `init` | `Saved Games\DCS_F4E\jester\mods\init`: the launcher that loads the mod. |
| `_EXTRA (DCS Scripts)` (optional) | Its `Scripts` folder goes into `Saved Games\DCS` (or `DCS.openbeta`): `Scripts\Hooks\AAPlusMessages.lua`, the hook that writes AWACS and EWRS messages to a file. |

## Check it works

1. Start a mission in the F-4E.
2. Open the Jester wheel: Radar > A/A Plus. The entry should be there, and the mod starts in Unified mode.
3. For the optional hook, `Logs\aaplus_messages.txt` should exist and grow after the mission starts.

## Updating

Copy your `Config.lua` somewhere safe, drag the folders in again (Copy and Replace), then put your `Config.lua` back (copy any new keys from the new file into it). Restart DCS.

## Removing

Delete `mods\init\aaplus` to switch the mod off. Delete `mods\aaplus` to remove it completely. Delete `AAPlusMessages.lua` from your `Scripts\Hooks` folder to stop the AWACS log.

## Troubleshooting

- **No A/A Plus entry on the Radar wheel:** `mods\init\aaplus` is missing. Press LShift+R. After a respawn the entry returns in about three seconds.
- **Jester never searches:** the mode is Off, you hold the cursor (in Unified mode the status line says pilot), or the cue is more than 58 degrees from the nose.
- **AWACS cues never start:** the hook is not installed, DCS was not fully restarted, `Logs\aaplus_messages.txt` is missing or not growing, or a DCS update undid the `io` edit.
- **He searches the wrong place:** make sure the hook is the current version (it reports the map) and that the BRAA call was the one you meant.
- **Something odd, and you want to report it:** set `LOG_TO_FILE = true` in `Config.lua`, fly it again, and send `mods\aaplus\aaplus.log`. The log needs the `io` edit too.
