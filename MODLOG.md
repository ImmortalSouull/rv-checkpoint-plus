# RV Checkpoint+ — MODLOG

Goal: checkpoint quality-of-life mod for **RV There Yet?** (Steam 3949040).
Player complaints (1500 recent negative reviews, 170 mention checkpoints/restarts):
- saves only at fixed checkpoints, far apart; can't save & quit mid-route
- reload restores RV in the state it was at the checkpoint (repairs lost)
- fell through map / RV stuck -> only fix is reload checkpoint
Planned features: quicksave anywhere (host), load quicksave, checkpoint select, unstuck player/RV.

## Environment
- Game: `C:\Program Files (x86)\Steam\steamapps\common\Ride` (project name `Ride`), exe `Ride\Binaries\Win64\Ride-Win64-Shipping.exe`
- Exe FileVersion `Ride-CL-20702-...`; engine UE 5.6 (Aug log: `5.6.0-17491+++RideGamejam+rel-1.2`); IoStore paks, unsigned
- No anti-cheat. Online via EOS (RedpointEOS) / Steam. Mod tested host/solo only.
- Saves: `%LOCALAPPDATA%\ride\Saved\SaveGames\<steamid>\<name>.sav` + `<name>.meta.sav`, `PlayerProgression--1.sav`
- Backup: `%USERPROFILE%\.universal-modder\backups\rv-saves\20261012-000816.zip` (restore with `um backup restore`)
- Loader: UE4SS experimental-latest `UE4SS_v3.0.1-1164-g5e627997` (dll built 2026-10-09) -> `dwmapi.dll` + `ue4ss\` next to exe.
  Uninstall = delete those two.
- Config: `%LOCALAPPDATA%\ride\Saved\Config\Windows\GameUserSettings.ini` (`CustomConsoleKey=F1` exists!)

## Route
UE4SS Lua mod. Reason: game is UE5.6 blueprint-heavy, UE4SS already used by community mods (MoreRVers),
Lua can call the game's own save/checkpoint UFunctions without cooking assets.

## Log
### 2026-10-12 night — recon + v1.0.0 working in game
Facts (game v1.3.20702, UE 5.6):
- `GM_FirstPerson_C` (game mode BP, server only) — `SaveSession()` writes `<session>.sav` with RV damage,
  attached items, inventory, map data. `RestartFromCheckpoint(i)` = server travel reload at checkpoint i.
- `RideGameState_C.CurrentCheckpoint` = raw index (0 = Campsite start); load menu shows the same number.
  `bIsFromLoad` EUnknownBool: 2 (False) on New Game, 1 on load/restart.
- `BP_CheckPoint_C` (18 in Mabutts Valley, all loaded): `CheckpointIndex`, `VehicleDummy` (RV spawn), sphere overlap -> `TriggerCheckpoint` -> save.
- Save does NOT contain RV position: reload always spawns RV at checkpoint VehicleDummy.
- Restart without SaveSession reverts RV damage to the last save; SaveSession first keeps it (verified 90/140 shield).
- Built-in "reset vehicle" input (`RequestFixVehicle`) = full checkpoint reload.
- `GM:IsSessionSaveInProgress` stays true forever after first save -> unusable.
- HUD: `WG_PlayerHUD_C.NotificationText` (TextBlock) can be shown directly; `AddNotification` does nothing visible.
- Characters are client-authoritative (`AClientAuthoritativeCharacter`); use `TeleportPlayerTo(loc, rot)`.
  K2_TeleportTo into terrain is rejected (encroachment).
- RV teleport: K2_SetActorLocationAndRotation(teleport=true) + zero physics velocity + `FixTiresAfterTeleport()`.
  Far teleport: move host pawn first, wait ~2.5 s for World Partition streaming.
- Dev cheats exist (`BP_CheatManager_C`, auto-created by UE4SS CheatManagerEnabler): DriveWinnebago, TakeFrameDamage,
  RepairFrameDamage, TeleportToCheckpoint... Cheat repairs do NOT go through `RepairDamage` -> detect repairs by
  shield/damage delta instead.
- Gearbox manual: `v.GearBox:Server_SetCurrentGear(2)`; P toggles park, R engine.

Verified in game (session cpshow/cptest, host solo):
- F5 quick save -> sidecar in `Mods/RVCheckpointPlus/saves/<hex(level|session)>.lua`; refuses when RV on side/airborne.
- F9 quick load -> restart + restore RV within ~2 cm, player restored.
- Game over (RV destroyed) -> game auto-restarts -> mod restores quick save position.
- Quit (kill) + Load Game from menu -> restored.
- New checkpoint reached -> old quick save deleted. New Game with reused name -> sidecar ignored/deleted.
- F8 menu -> F9 go back to start: RV at start, current damage kept.
- F7 flipped RV -> back on wheels at last safe spot. F6 -> player next to RV door.
- Auto "Repair saved" 3 s after shield/damage improves.
Not tested: real second player (clients), other maps (Snow/Jungle/Beach).
- DEV GOTCHA: UE4SS hot reload (Ctrl+R) deadlocked the game when the dev bridge had hooks on per-frame vehicle functions (SetThrottleInput etc.). Restart the game instead.
- Driving from Lua: set `GearBox:Server_SetGearShiftPosition_Display({-1,-1})` + `Server_SetCurrentGear(1)` (gear alone = no drive), engine `ToggleEngine()`, inputs overridden in post-hooks of `AVS_Vehicle_C:SetThrottleInput/SetSteeringInput/CalculateSteering` (set SteeringInput + LocalSteeringInput). Positive steering = yaw increases (right).
- After a restart the game re-seats players who were in the RV (attached to seat actors).

### Showcase (2026-10-12 ~02:00)
- Take 6 (`showcase/raw/take6.mp4`, 3440x1440) driven by `showcase/director4.sh` + bridge autopilot `_bridge/ap_all.lua`.
- `showcase/rv_checkpoint_plus_16x9.mp4` (um video compile edl_wide.json), `showcase/rv_checkpoint_plus_tiktok.mp4`
  (make_vertical.py, 1080x1920, 24 MB = phone copy). RV destruction in the demo is staged with the dev cheat.
- Fixes found while filming: quick save while mid-corner restored the RV rolled 40 deg -> now saves the last steady spot;
  restore with host seated in the RV far from checkpoint -> RV frozen above target while world streams.
- Footage still shows the old long F7 message; mod text was shortened afterwards.
