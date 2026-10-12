# RV Checkpoint+ (RV There Yet?)

![RV Checkpoint+](showcase/nexus/final/01_cover.jpg)

The most common complaint in recent negative Steam reviews: you can only save at fixed checkpoints. One bad jump,
one glitch or one bear sends the whole group back, and a reload throws away the repairs you made since then.

RV Checkpoint+ adds:

| Key | What it does |
|---|---|
| **F5** | **Quick save.** Saves the RV right now: damage, repairs, items on it, inventory, and where it stands. |
| **F9** | **Quick load.** Takes you back to your last quick save. It does not send you back to the checkpoint. |
| **F8** | **Checkpoint menu.** Go back to any earlier checkpoint, for example to fetch an item you missed. Press F8 again to step back further, F9 to go, or wait to cancel. The RV keeps its current repairs. |
| **F7** | **Recover RV.** Flipped, stuck, or fell through the world? The first press lifts it free. A second press within a few seconds puts it back on its wheels at the last safe spot. |
| **F6** | **Unstuck.** Puts you next to the RV door. **Shift+F6** brings every player to the RV. |
| (auto) | **Repairs are saved** a few seconds after the RV gets repaired, so a reload no longer undoes them. |

More details:
- **Game over keeps your quick save.** When the RV is destroyed, the game restarts and the mod puts the RV and
  players back at your quick save, not at the checkpoint.
- **Quit mid-route.** Press F5, quit, then use *Load Game* later and you continue from the quick save.
- **Old quick saves expire.** Reaching a new checkpoint replaces the old quick save. Starting a new game that
  reuses an old name ignores the old file.
- **No bad saves.** The mod won't quick save while the RV is in the air or on its side.

## Install
1. Install **UE4SS** (experimental build, it supports UE 5.6): copy `dwmapi.dll` and the `ue4ss` folder from
   [RE-UE4SS experimental-latest](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest) next to
   `RV There Yet?\Ride\Binaries\Win64\Ride-Win64-Shipping.exe`.
2. Copy the `RVCheckpointPlus` folder into `...\Win64\ue4ss\Mods\`. It already contains `enabled.txt`.
3. Start the game.

Settings live in `RVCheckpointPlus\Scripts\config.lua`: keys, auto-save after repair, a timed auto-save, and
on-screen message length.

## Multiplayer
- Only the **host** needs the mod. Saves and checkpoints belong to the host in this game. Players without the
  mod can join.
- Players are moved with the game's own `TeleportPlayerTo`.
- I have only tested it as host on my own (single machine). Co-op with real friends is untested, so please
  report what happens.

## Uninstall
Delete `ue4ss\Mods\RVCheckpointPlus`. Quick saves live in its `saves` folder. Your normal game saves are never
changed, except by the game's own save function.

## Compatibility
- Tested on game version **v1.3.20702** (UE 5.6) on Mabutts Valley and Mt. Yurbuttsk.
- It doesn't replace any game files and uses no pak mods, so game updates are unlikely to break it.

## Credits
- Mod created by Claude (Anthropic AI) for [immortalsouul](https://www.nexusmods.com/profile/immortalsouul), who playtested it in game and publishes it.
- UE4SS by the UE4SS-RE team.
- RV There Yet? by Nuggets Entertainment.

## License
MIT (see `LICENSE`). This repository contains no game files.
