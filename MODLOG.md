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

### 2026-11-11 v1.1.0 — fixes from Nexus comments (game v1.4.1.22052, UE4SS v3.0.1-1218)
Comments: (1) co-op: after a mod reload friends saw the RV armor under the ground, touching the RV flipped/blew it up,
"save bricked"; RV spawned ~3 m up and dropped. (2) "doesn't work at all" after a game update (Vortex install).
(3) death loop: players restored mid-air -> fall -> game over -> restore again. (4) wish: 3 rotating saves.
- Game updated v1.3.20702 -> v1.4.1.22052. All classes/functions the mod uses still exist. UE4SS 1218 works.
  Vortex installs only the mod folder, not UE4SS -> new `-with-UE4SS.zip` (extract into the game folder).
- ROOT CAUSE (1), reproduced with 2 instances: `SetSimulatePhysics(false)` on the RV root is mirrored to clients
  (replicated movement bRepPhysics); after the toggle + teleport the client copy lost 42 of 119 attached parts and lay
  on its side while the host's was fine. "Bricked" = every reload ran the same restore again.
- FIX: move the RV with `AVS_Vehicle_C:TeleportVehicle(loc, rot, false)` on the host + `BP_VehicleBase_C:ForceTeleport(loc)`
  (reliable multicast `DoForceTeleport` -> every machine calls TeleportVehicle(loc, its current rotation)). Client
  copies match the host exactly (pos, yaw, parts). Never toggle physics.
- Ground: `KismetSystemLibrary:LineTraceSingle` ignoring the RV + `GetAttachedActors` (118) + pawns. RV origin is ~74-81
  above ground; saved as `rv.clear`. A miss = not streamed yet.
- Damage: hooks on BP functions fire AFTER the body (Internal_TakePlayerDamage "pre" already sees the damage) -> can't
  cancel. `BP_FirstPersonCharacter_C.Invulnerable` (not replicated) is checked on the server: set on the host it saves
  clients from a 40 m fall (control without it: 100 damage = dead).
- Restore now: protect all players -> host goes to the target first (World Partition streams around the host) ->
  RV placed on the traced ground with the saved clearance (or hovers above via repeated moveRV while the host rides it)
  -> players placed from RV-relative offsets on traced ground -> after 3 s anyone who fell through is moved again ->
  protection off 6 s later. Game over within 60 s of a restore (same process, no menu in between) -> skip the auto
  restore once; F9 forces it.
- v1.4.1: after RestartFromCheckpoint the game no longer re-seats players (driver and passenger tested).
- Backups: steam id from `%LOCALAPPDATA%\ride\Saved\Logs\Ride.log` ("SteamID: N") -> `SaveGames\<id>\<name>.sav/.meta.sav`;
  ring of 3 in `saves/<key>.b<n>.*` at quick save (+2.5 s) and checkpoint (+3 s). RestartFromCheckpoint re-reads the
  .sav from disk (verified: shield 11 -> restore older backup -> 70).
- Co-op test rig (dev only): copy `C:\Users\PC\RV_B` (exe + ue4ss, Content/Engine/Plugins junctions, steam_appid.txt),
  launched windowed WITH Steam (needed for the network version checksum). Host must load through the menu with
  Session Type = IP (console `open ...?listen` hosts but rejects joins with "Server full": no session).
  Client: remove the 3 extra local players (`GameplayStatics:RemovePlayer`), `GameInstance:SetupNetDriverForHostType(1)`,
  `open 127.0.0.1:7777`. Seat a player: `<seat>:Interact(pawn, {}, 0.0, false, {})`.
- Same Steam account on both copies -> same player name; restore matches saved players by name with a queue.
- PostMessage keys don't reach UE4SS keybinds; test through the dev bridge (`_tools/rvc.ps1`, RVCP table).
