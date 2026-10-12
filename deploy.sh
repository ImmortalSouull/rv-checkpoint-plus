#!/bin/bash
# copy the mod into the game's UE4SS Mods folder (keeps existing quick saves)
G="/c/Program Files (x86)/Steam/steamapps/common/Ride/Ride/Binaries/Win64/ue4ss/Mods/RVCheckpointPlus"
mkdir -p "$G/Scripts" "$G/saves"
cp mod/RVCheckpointPlus/Scripts/*.lua "$G/Scripts/"
cp mod/RVCheckpointPlus/enabled.txt "$G/"
echo deployed
