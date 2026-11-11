-- RV Checkpoint+  (RV There Yet?, UE4SS Lua)
-- Quick save anywhere, quick load, pick an earlier checkpoint, unstuck player, recover RV,
-- and auto-save after repairs. Host-side: everything runs on the machine that hosts the game.

local VERSION = "1.1.0"

local function script_dir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return src:match("^(.*)[/\\]") or "."
end
local SCRIPT_DIR = script_dir()
local MOD_DIR = SCRIPT_DIR:match("^(.*)[/\\]Scripts$") or (SCRIPT_DIR .. "/..")
local SAVE_DIR = MOD_DIR .. "/saves/"

local okcfg, CFG = pcall(dofile, SCRIPT_DIR .. "/config.lua")
if not okcfg or type(CFG) ~= "table" then
    print("[RVCheckpointPlus] config.lua failed to load, using defaults: " .. tostring(CFG) .. "\n")
    CFG = {}
end
CFG.keys = CFG.keys or {}
local function cfg(k, d) if CFG[k] == nil then return d end return CFG[k] end

local function log(s) print("[RVCheckpointPlus] " .. tostring(s) .. "\n") end

---------------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------------
local NOW = 0.0           -- seconds, advanced by our own loop (os.clock is CPU time)
local TICK = 0.25

local function valid(o) return o ~= nil and o:IsValid() end
local function first(cls) local o = FindFirstOf(cls); if valid(o) then return o end; return nil end
local function all(cls)
    local out = {}
    for _, o in ipairs(FindAllOf(cls) or {}) do if valid(o) then out[#out + 1] = o end end
    return out
end
local function v3(x, y, z) return { X = x, Y = y, Z = z } end
local function dist(a, b) local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z; return math.sqrt(dx * dx + dy * dy + dz * dz) end

local function getGM() return first("GM_FirstPerson_C") end
local function getGS() return first("RideGameState_C") end
local function getRV() return first("BP_Vehicle_Winnebago_01_C") end
local function isHost() return getGM() ~= nil end

local function localPC()
    for _, pc in ipairs(all("BP_FirstPersonPlayerController_C")) do
        local ok, isLocal = pcall(function() return pc:IsLocalController() end)
        if ok and isLocal then return pc end
    end
    return nil
end

local function playerName(pc)
    local ok, n = pcall(function() return pc.PlayerState:GetPlayerName():ToString() end)
    if ok and n then return n end
    return "?"
end

local function sessionInfo()
    local gs = getGS()
    if not gs then return nil end
    local name = gs.SessionName:ToString()
    local level = (gs:GetFullName():match("(/Game/[^%.]+)%.") or "?")
    return { name = name, level = level, cp = gs.CurrentCheckpoint, gs = gs }
end

local function checkpointCount()
    local maxi = -1
    for _, c in ipairs(all("BP_CheckPoint_C")) do if c.CheckpointIndex > maxi then maxi = c.CheckpointIndex end end
    return maxi + 1
end

---------------------------------------------------------------------------
-- on-screen messages (re-uses the game's own HUD notification text)
---------------------------------------------------------------------------
local msgSerial = 0
local function toast(text, seconds)
    log(text)
    local hud = first("WG_PlayerHUD_C")
    if not hud then return end
    local tb = hud.NotificationText
    if not valid(tb) then return end
    msgSerial = msgSerial + 1
    local mine = msgSerial
    tb:SetText(FText(text))
    -- the game's notification text has no outline; add a soft shadow so it reads on snow/sand
    pcall(function() tb:SetShadowOffset({ X = 2.0, Y = 2.0 }) end)
    pcall(function() tb:SetShadowColorAndOpacity({ R = 0.0, G = 0.0, B = 0.0, A = 0.85 }) end)
    tb:SetRenderOpacity(1.0)
    tb:SetVisibility(3) -- HitTestInvisible
    local ms = math.floor((seconds or cfg("message_seconds", 3.0)) * 1000)
    ExecuteWithDelay(ms, function()
        ExecuteInGameThread(function()
            if mine ~= msgSerial then return end
            local h = first("WG_PlayerHUD_C")
            if h and valid(h.NotificationText) then h.NotificationText:SetVisibility(1) end
        end)
    end)
end

---------------------------------------------------------------------------
-- quick save files  (one per session, Lua table literal)
---------------------------------------------------------------------------
local function fileKey(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local function sidecarPath(si) return SAVE_DIR .. fileKey(si.level .. "|" .. si.name) .. ".lua" end

local function ser(v)
    local t = type(v)
    if t == "number" then return string.format("%.17g", v)
    elseif t == "string" then return string.format("%q", v)
    elseif t == "boolean" then return tostring(v)
    elseif t == "table" then
        local parts = {}
        for k, x in pairs(v) do
            local key = type(k) == "string" and ("[" .. string.format("%q", k) .. "]") or ("[" .. k .. "]")
            parts[#parts + 1] = key .. "=" .. ser(x)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "nil"
end

local function writeSidecar(si, data)
    local f, err = io.open(sidecarPath(si), "wb")
    if not f then log("cannot write quick save: " .. tostring(err)); return false end
    f:write("return " .. ser(data) .. "\n"); f:close()
    return true
end
local function readSidecar(si)
    local f = io.open(sidecarPath(si), "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    local fn = load(s, "sidecar", "t", {})
    if not fn then return nil end
    local ok, data = pcall(fn)
    if ok and type(data) == "table" then return data end
    return nil
end
local function deleteSidecar(si) os.remove(sidecarPath(si)) end

---------------------------------------------------------------------------
-- rotating backups of the game's own session save (<name>.sav + <name>.meta.sav)
---------------------------------------------------------------------------
local function readFile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end
local function exists(p)
    local f = io.open(p, "rb"); if not f then return false end
    f:close(); return true
end
local function writeFile(p, s)
    local f = io.open(p, "wb"); if not f then return false end
    f:write(s); f:close(); return true
end

-- %LOCALAPPDATA%\ride\Saved\SaveGames\<steam id>\  (the id comes from the game's own log)
local saveGameDir = nil
local function findGameSave(name)
    local la = os.getenv("LOCALAPPDATA")
    if not la then return nil end
    local base = la .. "/ride/Saved/SaveGames/"
    if saveGameDir and exists(saveGameDir .. name .. ".sav") then return saveGameDir end
    local ids = {}
    local logText = readFile(la .. "/ride/Saved/Logs/Ride.log") or ""
    for id in logText:gmatch("SteamID: (%d+)") do ids[#ids + 1] = id end
    for id in logText:gmatch("for user (%w+)") do ids[#ids + 1] = id end
    ids[#ids + 1] = ""
    for _, id in ipairs(ids) do
        local dir = base .. (id ~= "" and (id .. "/") or "")
        if exists(dir .. name .. ".sav") then saveGameDir = dir; return dir end
    end
    return nil
end

local function backupIndexPath(si) return SAVE_DIR .. fileKey(si.level .. "|" .. si.name) .. ".backups.lua" end
local function backupFile(si, n, ext) return SAVE_DIR .. fileKey(si.level .. "|" .. si.name) .. ".b" .. n .. ext end

local function readBackupIndex(si)
    local s = readFile(backupIndexPath(si))
    if s then
        local fn = load(s, "backups", "t", {})
        local ok, data = pcall(fn or function() end)
        if ok and type(data) == "table" and type(data.list) == "table" then return data end
    end
    return { last = 0, list = {} }
end

-- Copy the game's save files (+ our quick save, if any) into the next of N rotating slots.
local function makeBackup(si, why)
    local keep = cfg("keep_backups", 3)
    if not keep or keep <= 0 then return end
    local dir = findGameSave(si.name)
    if not dir then log("backup skipped: can't find the game's save file for '" .. si.name .. "'"); return end
    local sav, meta = readFile(dir .. si.name .. ".sav"), readFile(dir .. si.name .. ".meta.sav")
    if not sav then return end
    local idx = readBackupIndex(si)
    local n = (idx.last % keep) + 1
    writeFile(backupFile(si, n, ".sav"), sav)
    if meta then writeFile(backupFile(si, n, ".meta.sav"), meta) end
    local side = readFile(sidecarPath(si))
    if side then writeFile(backupFile(si, n, ".lua"), side) else os.remove(backupFile(si, n, ".lua")) end
    local list = {}
    for _, e in ipairs(idx.list) do if e.n ~= n and e.n <= keep then list[#list + 1] = e end end
    list[#list + 1] = { n = n, time = os.time(), cp = si.cp, why = why, quick = side ~= nil }
    writeFile(backupIndexPath(si), "return " .. ser({ last = n, list = list }) .. "\n")
    log(string.format("backup %d saved (%s, cp %d)", n, why, si.cp))
end

-- newest first
local function backupList(si)
    local idx = readBackupIndex(si)
    local list = {}
    for _, e in ipairs(idx.list) do
        if exists(backupFile(si, e.n, ".sav")) then list[#list + 1] = e end
    end
    table.sort(list, function(a, b) return a.time > b.time end)
    return list
end

-- Put a backup back in place of the game's save. Returns the checkpoint index it belongs to.
local function applyBackup(si, e)
    local dir = findGameSave(si.name)
    if not dir then return nil end
    local sav, meta = readFile(backupFile(si, e.n, ".sav")), readFile(backupFile(si, e.n, ".meta.sav"))
    if not sav then return nil end
    -- keep what is there now as well, in case the backup turns out worse
    local cur = readFile(dir .. si.name .. ".sav")
    if cur then writeFile(SAVE_DIR .. fileKey(si.level .. "|" .. si.name) .. ".before-restore.sav", cur) end
    writeFile(dir .. si.name .. ".sav", sav)
    if meta then writeFile(dir .. si.name .. ".meta.sav", meta) end
    local side = readFile(backupFile(si, e.n, ".lua"))
    if side then writeFile(sidecarPath(si), side) else deleteSidecar(si) end
    return e.cp
end

---------------------------------------------------------------------------
-- RV state helpers
---------------------------------------------------------------------------
-- "upright" = not on its side / roof. Driving over rough ground easily reaches 30-40 degrees, so be generous.
local function rvUpright(r) return math.abs(r.Pitch) < 60 and math.abs(r.Roll) < 60 end
local function rvLevelEnough(r) return math.abs(r.Pitch) < 35 and math.abs(r.Roll) < 35 end
-- a pose that will still be a good place to put the RV back later
local function rvSteady(r, vel) return math.abs(r.Pitch) < 20 and math.abs(r.Roll) < 15 and math.abs(vel.Z) < 250 end

local function rvHealth(rv)
    local ok, h = pcall(function()
        local dmg = 0
        local arr = rv.CurrentDamage
        for i = 1, #arr do dmg = dmg + arr[i].Value end
        return { shield = rv.CurrentShieldHealth, damage = dmg }
    end)
    if ok then return h end
    return nil
end

local function stopRV(rv)
    local root = rv.RootComponent
    pcall(function() root:SetPhysicsLinearVelocity(v3(0, 0, 0), false, FName("None")) end)
    pcall(function() root:SetPhysicsAngularVelocityInDegrees(v3(0, 0, 0), false, FName("None")) end)
end

-- Move the RV. The host's copy gets the exact spot and heading through the vehicle's own teleport
-- (chassis + wheels together), then the game's ForceTeleport multicast makes every machine move its own
-- copy the same way the game does it. Physics is never switched off: clients mirror that switch, and
-- their RV then came back with its armor panels left under the ground.
local function moveRV(rv, loc, yaw, pitch, roll)
    local rot = { Pitch = pitch or 0, Yaw = yaw, Roll = roll or 0 }
    if not pcall(function() rv:TeleportVehicle(loc, rot, false) end) then
        rv:K2_SetActorLocationAndRotation(loc, rot, false, {}, true)
    end
    pcall(function() rv:ForceTeleport(loc) end)
    stopRV(rv)
    pcall(function() rv:FixTiresAfterTeleport() end)
end

local function placeRV(rv, loc, yaw, pitch, roll)
    moveRV(rv, loc, yaw, pitch, roll)
    -- physics can keep a tiny bit of momentum from the frame we moved in
    ExecuteWithDelay(150, function() ExecuteInGameThread(function() if valid(rv) then stopRV(rv) end end) end)
end

-- the RV and everything bolted onto it (panels, seats, shelves...)
local function rvParts(rv)
    local out = { rv }
    pcall(function()
        local arr = {}
        rv:GetAttachedActors(arr, true, true)
        for i = 1, #arr do out[#out + 1] = arr[i]:get() end
    end)
    return out
end

local KSL
local NOCOLOR = { R = 0, G = 0, B = 0, A = 0 }
-- Height of whatever is under (x, y) between fromZ and toZ, or nil when nothing is there
-- (also nil while that part of the world hasn't streamed in yet).
local function groundZ(ctx, x, y, fromZ, toZ, ignore)
    KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local hit = {}
    local ok, did = pcall(function()
        return KSL:LineTraceSingle(ctx, v3(x, y, fromZ), v3(x, y, toZ), 0, false, ignore or {}, 0, hit, true, NOCOLOR, NOCOLOR, 0)
    end)
    if ok and did and hit.ImpactPoint then return hit.ImpactPoint.Z end
    return nil
end

-- the game's own respawn protection flag; the server checks it for every player's damage
local function setInvulnerable(pawn, on)
    pcall(function() pawn.Invulnerable = on end)
end

-- Put a player somewhere near a point, using the game's own client-safe teleport.
local function teleportPlayer(pc, loc, yaw)
    local pawn = pc.Pawn
    if not valid(pawn) then return false end
    local rot = { Pitch = 0, Yaw = yaw or pawn:K2_GetActorRotation().Yaw, Roll = 0 }
    local ok = pcall(function() pawn:TeleportPlayerTo(loc, rot) end)
    if not ok then ok = pcall(function() pawn:K2_TeleportTo(loc, rot) end) end
    return ok
end

-- spots around the RV: left door side first, then behind, right, front
local function spotNextToRV(rv, i)
    local l = rv:K2_GetActorLocation()
    -- use the heading only: a tilted RV would otherwise put the spot inside its own body
    local y = math.rad(rv:K2_GetActorRotation().Yaw)
    local f = v3(math.cos(y), math.sin(y), 0)
    local r = v3(-math.sin(y), math.cos(y), 0)
    local offs = { { 0, -380 }, { -650, 0 }, { 0, 380 }, { 650, 0 }, { -350, -380 }, { -350, 380 }, { 350, -380 }, { 350, 380 } }
    local o = offs[((i - 1) % #offs) + 1]
    local x, yy = l.X + f.X * o[1] + r.X * o[2], l.Y + f.Y * o[1] + r.Y * o[2]
    -- stand on the ground there, not 1 m above a slope (or 5 m above a ditch)
    local g = groundZ(rv, x, yy, l.Z + 400, l.Z - 1500, rvParts(rv))
    return v3(x, yy, (g and (g + 100)) or (l.Z + 120))
end

-- RV-local offset <-> world, heading only
local function toLocal(rvLoc, rvYaw, p)
    local y = math.rad(rvYaw)
    local dx, dy = p.X - rvLoc.X, p.Y - rvLoc.Y
    return { x = dx * math.cos(y) + dy * math.sin(y), y = -dx * math.sin(y) + dy * math.cos(y), z = p.Z - rvLoc.Z }
end
local function toWorld(rvLoc, rvYaw, o)
    local y = math.rad(rvYaw)
    return v3(rvLoc.X + o.x * math.cos(y) - o.y * math.sin(y), rvLoc.Y + o.x * math.sin(y) + o.y * math.cos(y), rvLoc.Z + o.z)
end

-- seated somewhere (driver seat, sofa, passenger seat...): the character is attached to an actor
local function seated(pawn)
    local ok, parent = pcall(function() return pawn:GetAttachParentActor() end)
    return ok and valid(parent)
end

local function isInRV(pawn, rv)
    local ok, parent = pcall(function() return pawn:GetAttachParentActor() end)
    if ok and valid(parent) and parent:GetAddress() == rv:GetAddress() then return true end
    return dist(pawn:K2_GetActorLocation(), rv:K2_GetActorLocation()) < 600
end

---------------------------------------------------------------------------
-- state
---------------------------------------------------------------------------
local S = {
    gmAddr = nil,
    levelStart = 0,
    restore = nil,         -- pending restore { data=..., stage=..., at=... }
    safe = {},             -- ring of {t, loc, yaw}
    lastSafeSample = 0,
    repairDirtyAt = nil,
    lastAutosave = 0,
    menu = nil,            -- { sel=, until= }
    bmenu = nil,           -- backup menu { list=, sel=, until= }
    lastRecover = -100,
    hooked = false,
    busyUntil = 0,
    forceRestore = false,  -- set by F9: load the quick save even if the last load ended badly
    protectUntil = 0,      -- players can't be hurt until then (restore in progress)
    protected = {},        -- pawn address -> pawn we made invulnerable
}

-- Keep every player invulnerable while a restore moves people around (and a few seconds after),
-- so a bad spot can't kill anyone and turn the reload into a game-over loop.
local function protectPlayers(seconds)
    S.protectUntil = math.max(S.protectUntil, NOW + seconds)
end
local function updateProtection()
    if NOW < S.protectUntil then
        for _, pc in ipairs(all("BP_FirstPersonPlayerController_C")) do
            local p = pc.Pawn
            if valid(p) then
                local a = p:GetAddress()
                if not S.protected[a] then
                    local was = false
                    pcall(function() was = p.Invulnerable end)
                    if not was then S.protected[a] = p; setInvulnerable(p, true) end
                end
            end
        end
    elseif next(S.protected) then
        for _, p in pairs(S.protected) do if valid(p) then setInvulnerable(p, false) end end
        S.protected = {}
    end
end

local function busy()
    if NOW < S.busyUntil then return true end
    if S.restore then return true end
    return false
end

local function cpLabel(i, count)
    if i == 0 then return "the start" end
    return string.format("checkpoint %d of %d", i, math.max(count - 1, i))
end

---------------------------------------------------------------------------
-- actions
---------------------------------------------------------------------------
local function hostOnly()
    if isHost() then return true end
    toast("RV Checkpoint+: only the host can do that")
    return false
end

-- GM:IsSessionSaveInProgress stays true forever after the first save in 1.3.20702,
-- so we only guard against our own saves stacking up.
local lastSaveAt = -100
local function saveInProgress(gm) return (NOW - lastSaveAt) < 1.5 end
local function saveSession(gm) lastSaveAt = NOW; gm:SaveSession() end

local function quickSave(reason)
    if not hostOnly() or busy() then return end
    local gm, rv, si = getGM(), getRV(), sessionInfo()
    if not (gm and rv and si) then return end
    local r = rv:K2_GetActorRotation()
    local vel = rv:GetVelocity()
    if not rvUpright(r) then log(string.format("refused: pitch %.0f roll %.0f", r.Pitch, r.Roll)); toast("Can't quick save: the RV is on its side (F7 to recover)"); return end
    if math.abs(vel.Z) > 600 then toast("Can't quick save while the RV is in the air"); return end
    if saveInProgress(gm) then toast("Saving... try again in a second"); return end

    -- Where to put the RV back: right here if it's steady, otherwise the last steady spot it passed
    -- (a save made halfway up a bank or mid-corner would slide off when restored).
    local l = rv:K2_GetActorLocation()
    local pose = { x = l.X, y = l.Y, z = l.Z, pitch = r.Pitch, yaw = r.Yaw, roll = r.Roll }
    local fromSteady = false
    if not rvSteady(r, vel) then
        local pick
        for i = #S.safe, 1, -1 do
            if NOW - S.safe[i].t <= 15 then pick = S.safe[i]; break end
        end
        if not pick then
            log(string.format("refused: pitch %.0f roll %.0f vz %.0f", r.Pitch, r.Roll, vel.Z))
            toast("Can't quick save here: the RV isn't steady")
            return
        end
        pose = { x = pick.loc.X, y = pick.loc.Y, z = pick.loc.Z, pitch = pick.pitch, yaw = pick.yaw, roll = pick.roll }
        fromSteady = true
    end

    saveSession(gm)

    -- how high the RV's origin sits above the ground, so a restore can put it straight onto its wheels
    local parts = rvParts(rv)
    local g = groundZ(rv, pose.x, pose.y, pose.z + 300, pose.z - 2000, parts)
    pose.clear = g and math.max(40, math.min(250, pose.z - g)) or nil

    local data = {
        v = 2, mod = VERSION, session = si.name, level = si.level, cp = si.cp, time = os.time(),
        rv = pose,
        players = {},
    }
    -- players are stored relative to the RV: they come back around it, wherever it lands
    local rvLoc = v3(pose.x, pose.y, pose.z)
    for _, pc in ipairs(all("BP_FirstPersonPlayerController_C")) do
        local pawn = pc.Pawn
        if valid(pawn) then
            local pl = pawn:K2_GetActorLocation()
            local falling = false
            pcall(function() falling = pawn.CharacterMovement:IsFalling() end)
            local e = { name = playerName(pc), yaw = pawn:K2_GetActorRotation().Yaw - pose.yaw, inRV = isInRV(pawn, rv) }
            -- only remember a spot that was safe to stand on and near the RV
            if not falling and dist(pl, rvLoc) < 3000 then e.rel = toLocal(rvLoc, pose.yaw, pl) end
            data.players[#data.players + 1] = e
        end
    end
    if writeSidecar(si, data) then
        ExecuteWithDelay(2500, function() ExecuteInGameThread(function()
            local s2 = sessionInfo()
            if s2 and s2.name == si.name then pcall(makeBackup, s2, "quick save") end
        end) end)
        S.lastAutosave = NOW
        if reason == "auto" then toast("Auto saved")
        elseif fromSteady then toast("Quick saved  (at the last steady spot)")
        else toast("Quick saved  (" .. cpLabel(si.cp, checkpointCount()) .. ")") end
    end
end

local function quickLoad()
    if not hostOnly() or busy() then return end
    local gm, si = getGM(), sessionInfo()
    if not (gm and si) then return end
    local data = readSidecar(si)
    if not data or data.cp ~= si.cp then
        toast("No quick save since the last checkpoint  (F5 to quick save)")
        return
    end
    toast("Loading quick save...", 5)
    S.busyUntil = NOW + 5
    S.forceRestore = true
    gm:RestartFromCheckpoint(data.cp)
end

local function goToCheckpoint(idx)
    if not hostOnly() then return end
    local gm, si = getGM(), sessionInfo()
    if not (gm and si) then return end
    -- keep the RV exactly as it is now (damage, parts, items) when going back
    saveSession(gm)
    deleteSidecar(si)
    toast("Going back to " .. cpLabel(idx, checkpointCount()) .. "...", 5)
    S.busyUntil = NOW + 5
    ExecuteWithDelay(400, function()
        ExecuteInGameThread(function()
            local g = getGM()
            if g then g:RestartFromCheckpoint(idx) end
        end)
    end)
end

local function showMenu()
    local si = sessionInfo()
    if not si then return end
    local count = checkpointCount()
    local m = S.menu
    toast(string.format("Go back to:  %s\n(you are at %s)\n[%s] earlier     [%s] go     wait = cancel",
        cpLabel(m.sel, count), cpLabel(si.cp, count),
        CFG.keys.checkpoint_menu or "F8", CFG.keys.quick_load or "F9"), 8)
end

local function checkpointMenu()
    if not hostOnly() or busy() then return end
    local si = sessionInfo()
    if not si then return end
    if S.menu and NOW < S.menu["until"] then
        S.menu.sel = S.menu.sel - 1
        if S.menu.sel < 0 then S.menu.sel = si.cp end
    else
        S.menu = { sel = si.cp }
    end
    S.bmenu = nil
    S.menu["until"] = NOW + 8
    showMenu()
end

-- Shift+F9: step through the rotating backups (newest first), F9 restores the selected one.
local function backupLabel(e, count, i)
    local what = e.quick and "quick save" or (e.why or "save")
    return string.format("backup %d of %d: %s, %s (%s)", i, count, os.date("%H:%M", e.time), what, cpLabel(e.cp, checkpointCount()))
end

local function backupMenu()
    if not hostOnly() or busy() then return end
    local si = sessionInfo()
    if not si then return end
    if cfg("keep_backups", 3) <= 0 then toast("Backups are turned off in config.lua"); return end
    if S.bmenu and NOW < S.bmenu["until"] then
        S.bmenu.sel = S.bmenu.sel % #S.bmenu.list + 1
    else
        local list = backupList(si)
        if #list == 0 then toast("No backups yet: one is made at every quick save and checkpoint"); return end
        S.bmenu = { list = list, sel = 1 }
    end
    S.menu = nil
    S.bmenu["until"] = NOW + 8
    local e = S.bmenu.list[S.bmenu.sel]
    toast(string.format("Restore %s\n[Shift+%s] older     [%s] restore     wait = cancel",
        backupLabel(e, #S.bmenu.list, S.bmenu.sel), CFG.keys.quick_load or "F9", CFG.keys.quick_load or "F9"), 8)
end

local function restoreBackup()
    local m = S.bmenu; S.bmenu = nil
    local gm, si = getGM(), sessionInfo()
    if not (m and gm and si) then return end
    local e = m.list[m.sel]
    local cp = applyBackup(si, e)
    if not cp then toast("Couldn't restore that backup (save file not found)"); return end
    toast("Restoring backup from " .. os.date("%H:%M", e.time) .. "...", 5)
    S.busyUntil = NOW + 5
    S.forceRestore = true
    gm:RestartFromCheckpoint(cp)
end

local function unstuckPlayers(everyone)
    local rv = getRV()
    if not rv then return end
    if everyone then
        if not hostOnly() then return end
        protectPlayers(4)
        local n = 0
        for i, pc in ipairs(all("BP_FirstPersonPlayerController_C")) do
            if valid(pc.Pawn) and not isInRV(pc.Pawn, rv) then
                teleportPlayer(pc, spotNextToRV(rv, i), rv:K2_GetActorRotation().Yaw); n = n + 1
            end
        end
        toast(string.format("Brought %d player%s to the RV", n, n == 1 and "" or "s"))
    else
        local pc = localPC()
        if not pc then return end
        if not isHost() then
            -- clients move their own character (client authoritative movement)
            local ok = teleportPlayer(pc, spotNextToRV(rv, 1), rv:K2_GetActorRotation().Yaw)
            toast(ok and "Back at the RV" or "Couldn't move you")
            return
        end
        protectPlayers(4)
        teleportPlayer(pc, spotNextToRV(rv, 1), rv:K2_GetActorRotation().Yaw)
        toast("Back at the RV")
    end
end

local function recoverRV()
    if not hostOnly() or busy() then return end
    if not cfg("allow_recover_rv", true) then toast("RV recovery is turned off in config.lua"); return end
    local rv = getRV()
    if not rv then return end
    local l, r = rv:K2_GetActorLocation(), rv:K2_GetActorRotation()
    local vel = rv:GetVelocity()
    local second = (NOW - S.lastRecover) < 6
    S.lastRecover = NOW

    if not second and rvLevelEnough(r) and math.abs(vel.Z) < 400 then
        -- stuck but upright: lift it a little and let it settle
        placeRV(rv, v3(l.X, l.Y, l.Z + 160), r.Yaw, 0, 0)
        toast("RV lifted free  (F7 again = last safe spot)")
        return
    end
    -- flipped, falling or second press: newest safe spot that is at least 2 s old
    local pick
    for i = #S.safe, 1, -1 do
        local s = S.safe[i]
        if NOW - s.t >= 2.0 then pick = s; break end
    end
    if pick then
        placeRV(rv, v3(pick.loc.X, pick.loc.Y, pick.loc.Z + 60), pick.yaw, 0, 0)
        S.safe = {}  -- don't bounce between the same spots
        toast("RV put back on its wheels")
    else
        placeRV(rv, v3(l.X, l.Y, l.Z + 250), r.Yaw, 0, 0)
        toast("RV turned upright")
    end
end

---------------------------------------------------------------------------
-- restore after a (re)load: put RV + players back where the quick save was made
---------------------------------------------------------------------------
local function clamp20(a) return math.max(-20, math.min(20, a or 0)) end

local function startRestore(data)
    S.restore = { data = data, stage = "wait", at = NOW + 1.5, deadline = NOW + 45 }
    protectPlayers(60)
end

-- what a ground trace must not hit: the RV, its parts and the players
local function traceIgnore(rv)
    local ign = rvParts(rv)
    for _, pc in ipairs(all("BP_FirstPersonPlayerController_C")) do
        if valid(pc.Pawn) then ign[#ign + 1] = pc.Pawn end
    end
    return ign
end

-- A player's saved spot around the RV if it was a safe one, otherwise next to the door.
-- Always on the ground (the RV floor counts, so people who stood inside stay inside).
local function playerSpot(rv, s, i)
    if s and s.rel then
        local p = toWorld(rv:K2_GetActorLocation(), rv:K2_GetActorRotation().Yaw, s.rel)
        local ign = {}
        for _, pc in ipairs(all("BP_FirstPersonPlayerController_C")) do
            if valid(pc.Pawn) then ign[#ign + 1] = pc.Pawn end
        end
        local g = groundZ(rv, p.X, p.Y, p.Z + 150, p.Z - 600, ign)
        if g then return v3(p.X, p.Y, g + 100) end
    end
    return spotNextToRV(rv, i)
end

local function stepRestore()
    local R = S.restore
    if not R or NOW < R.at then return end
    if NOW > R.deadline then log("restore timed out"); S.restore = nil; S.protectUntil = NOW + 5; return end
    local rv, pc = getRV(), localPC()
    local d = R.data
    local target = v3(d.rv.x, d.rv.y, d.rv.z)

    if R.stage == "wait" then
        if not (rv and pc and valid(pc.Pawn)) then R.at = NOW + 0.5; return end
        -- After a restart the game re-seats players who were in the RV, so the host may be riding along.
        -- The world only streams in around the host: either the host rides the RV over there, or the
        -- host goes first and the RV follows once there is ground under the saved spot.
        R.hostSeated = seated(pc.Pawn)
        if not R.hostSeated then
            local yr = math.rad(d.rv.yaw)
            teleportPlayer(pc, v3(target.X + math.sin(yr) * 420, target.Y - math.cos(yr) * 420, target.Z + 150), d.rv.yaw)
        end
        toast("Restoring your quick save...", 3)
        R.stage = "ground"; R.giveUp = NOW + 20; R.at = NOW + 0.5
    elseif R.stage == "ground" then
        if not rv then R.at = NOW + 0.5; return end
        local g = groundZ(rv, target.X, target.Y, target.Z + 1500, target.Z - 1500, traceIgnore(rv))
        if g or NOW > R.giveUp then
            -- straight onto its wheels: the saved height above the ground, plus a few cm.
            -- A save made mid-corner can carry body roll; keep the slope, drop the lean.
            local z = g and (g + (d.rv.clear or 90) + 15) or (target.Z + 60)
            if not g then log("restore: no ground under the saved spot, placing at the saved height") end
            placeRV(rv, v3(target.X, target.Y, z), d.rv.yaw, clamp20(d.rv.pitch), clamp20(d.rv.roll))
            R.stage = "players"; R.at = NOW + 1.5
        else
            -- not streamed in yet: keep the RV (and whoever rides it) hovering right above the spot
            if R.hostSeated then moveRV(rv, v3(target.X, target.Y, target.Z + 400), d.rv.yaw, 0, 0) end
            R.at = NOW + 0.25
        end
    elseif R.stage == "players" then
        -- match saved players by name (a queue per name: two players can share one)
        local byName = {}
        for _, p in ipairs(d.players or {}) do
            byName[p.name] = byName[p.name] or {}
            table.insert(byName[p.name], p)
        end
        R.expect = {}
        for i, p in ipairs(all("BP_FirstPersonPlayerController_C")) do
            local q = byName[playerName(p)]
            local s = q and table.remove(q, 1)
            if valid(p.Pawn) and not seated(p.Pawn) then
                local spot = playerSpot(rv, s, i)
                teleportPlayer(p, spot, s and s.rel and (d.rv.yaw + (s.yaw or 0)) or d.rv.yaw)
                R.expect[#R.expect + 1] = { pc = p, spot = spot, i = i }
            end
        end
        R.stage = "check"; R.at = NOW + 3.0
    elseif R.stage == "check" then
        -- someone whose world hadn't streamed in yet may have dropped through the ground: try again
        for _, e in ipairs(R.expect or {}) do
            local p = e.pc
            if valid(p) and valid(p.Pawn) and not seated(p.Pawn) then
                local l = p.Pawn:K2_GetActorLocation()
                if l.Z < e.spot.Z - 500 or dist(l, e.spot) > 3000 then
                    log("restore: " .. playerName(p) .. " ended up away from the RV, moving again")
                    teleportPlayer(p, spotNextToRV(rv, e.i), d.rv.yaw)
                end
            end
        end
        S.restore = nil
        S.safe = {}
        S.health = nil
        S.protectUntil = NOW + 6
        toast("Quick save loaded")
    end
end

---------------------------------------------------------------------------
-- hooks into the game
---------------------------------------------------------------------------
local function tryHook(path, fn)
    local ok, err = pcall(RegisterHook, path, fn)
    if not ok then log("hook failed " .. path .. ": " .. tostring(err)) end
    return ok
end

local function installHooks()
    if S.hooked then return end
    S.hooked = true
    local repaired = function() S.repairDirtyAt = NOW end
    tryHook("/Game/Ride/Vehicle/Blueprints/BP_VehicleBase.BP_VehicleBase_C:RepairDamage", repaired)
    tryHook("/Game/Ride/Vehicle/Blueprints/BP_VehicleBase.BP_VehicleBase_C:RepairShield", repaired)
    -- reaching a new checkpoint makes the old quick save obsolete
    tryHook("/Game/Ride/Game/BP_CheckPoint.BP_CheckPoint_C:TriggerCheckpoint", function()
        ExecuteWithDelay(500, function() ExecuteInGameThread(function()
            local si = sessionInfo()
            if si then
                local d = readSidecar(si)
                if d and d.cp ~= si.cp then deleteSidecar(si) end
            end
        end) end)
        -- the game saves at the checkpoint: keep a copy of that save in the backup rotation
        ExecuteWithDelay(3000, function() ExecuteInGameThread(function()
            local si = sessionInfo()
            if si and isHost() and S.lastCpBackup ~= si.name .. "|" .. si.cp then
                S.lastCpBackup = si.name .. "|" .. si.cp
                pcall(makeBackup, si, "checkpoint")
            end
        end) end)
    end)
end

local function onLevelStart()
    S.levelStart = NOW
    S.restore = nil
    S.safe = {}
    S.menu = nil
    S.repairDirtyAt = nil
    S.health = nil
    S.lastAutosave = NOW
    S.checkLoad = { at = NOW + 1.0, deadline = NOW + 30 }
    installHooks()
end

local function checkLoad()
    local c = S.checkLoad
    if not c or NOW < c.at then return end
    if NOW > c.deadline then S.checkLoad = nil; return end
    local si = sessionInfo()
    if not si or si.name == "" or not getRV() then c.at = NOW + 0.5; return end
    S.checkLoad = nil
    local fromLoad = si.gs.bIsFromLoad
    local data = readSidecar(si)
    log(string.format("level start: session=%s level=%s cp=%d fromLoad=%s quicksave=%s",
        si.name, si.level, si.cp, tostring(fromLoad), data and ("cp " .. tostring(data.cp)) or "none"))
    if not data then return end
    if fromLoad == 2 then
        -- a brand new game that happens to reuse an old name
        deleteSidecar(si); return
    end
    if data.cp ~= si.cp then return end
    local forced = S.forceRestore
    S.forceRestore = false
    -- The level restarted (game over) within a minute of loading this quick save: loading it again
    -- would most likely end the same way (a deadly spot, a wreck...) and loop forever.
    -- Stay at the checkpoint this time; F9 still loads it.
    local key = sidecarPath(si)
    local last = S.lastRestore
    S.lastRestore = nil
    if not forced and last and last.key == key and NOW - last.at < 60 then
        log(string.format("quick save not restored: the last load ended in a game over %.0f s later", NOW - last.at))
        toast("Quick save not loaded: the last load ended in a game over.\n[" .. (CFG.keys.quick_load or "F9") .. "] = load it anyway", 7)
        return
    end
    S.lastRestore = { key = key, at = NOW }
    startRestore(data)
end

---------------------------------------------------------------------------
-- main loop (host): level detection, safe-spot tracking, repair autosave
---------------------------------------------------------------------------
local function tick()
    local gm = getGM()
    if not gm then S.gmAddr = nil; S.lastRestore = nil; return end  -- main menu
    local addr = gm:GetAddress()
    if addr ~= S.gmAddr then S.gmAddr = addr; onLevelStart() end

    checkLoad()
    stepRestore()
    updateProtection()

    local rv = getRV()
    if rv and not S.restore and NOW - S.lastSafeSample >= 0.5 then
        S.lastSafeSample = NOW
        local r, vel = rv:K2_GetActorRotation(), rv:GetVelocity()
        if rvSteady(r, vel) then
            S.safe[#S.safe + 1] = { t = NOW, loc = rv:K2_GetActorLocation(), yaw = r.Yaw, pitch = r.Pitch, roll = r.Roll }
            if #S.safe > 60 then table.remove(S.safe, 1) end
        end
    end

    -- repairs: any rise in shield or drop in damage (welder, spare parts, wheels put back...)
    if rv then
        local h = rvHealth(rv)
        if S.health and h and (h.shield > S.health.shield or h.damage < S.health.damage) then
            S.repairDirtyAt = NOW
        end
        S.health = h
    end

    if S.repairDirtyAt and NOW - S.repairDirtyAt > 3.0 and not busy() then
        S.repairDirtyAt = nil
        if cfg("autosave_after_repair", true) and not saveInProgress(gm) then
            saveSession(gm)
            toast("Repair saved")
        end
    end

    local mins = cfg("autosave_minutes", 0)
    if mins and mins > 0 and NOW - S.lastAutosave > mins * 60 and not busy() then
        S.lastAutosave = NOW
        local r = rv and rv:K2_GetActorRotation()
        if rv and rvUpright(r) and math.abs(rv:GetVelocity().Z) < 300 then quickSave("auto") end
    end

    if S.menu and NOW >= S.menu["until"] then S.menu = nil end
    if S.bmenu and NOW >= S.bmenu["until"] then S.bmenu = nil end
end

LoopAsync(math.floor(TICK * 1000), function()
    NOW = NOW + TICK
    ExecuteInGameThread(function()
        local ok, err = pcall(tick)
        if not ok then log("tick error: " .. tostring(err)) end
    end)
    return false
end)

---------------------------------------------------------------------------
-- keys
---------------------------------------------------------------------------
local function bind(name, default, fn, mods)
    local keyName = CFG.keys[name] or default
    local key = Key[keyName]
    if not key then log("unknown key '" .. tostring(keyName) .. "' for " .. name); return end
    local cb = function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then log(name .. " error: " .. tostring(err)) end
        end)
    end
    if mods then RegisterKeyBind(key, mods, cb) else RegisterKeyBind(key, cb) end
end

bind("quick_save", "F5", function() quickSave("key") end)
bind("quick_load", "F9", function()
    if S.bmenu and NOW < S.bmenu["until"] then
        restoreBackup()
    elseif S.menu and NOW < S.menu["until"] then
        local sel = S.menu.sel; S.menu = nil
        goToCheckpoint(sel)
    else
        quickLoad()
    end
end)
bind("quick_load", "F9", backupMenu, { ModifierKey.SHIFT })
bind("checkpoint_menu", "F8", checkpointMenu)
bind("unstuck_player", "F6", function() unstuckPlayers(false) end)
bind("unstuck_player", "F6", function() unstuckPlayers(true) end, { ModifierKey.SHIFT })
bind("recover_rv", "F7", recoverRV)

-- expose for testing from other scripts
_G.RVCP = { quickSave = quickSave, quickLoad = quickLoad, goToCheckpoint = goToCheckpoint,
    checkpointMenu = checkpointMenu, unstuckPlayers = unstuckPlayers, recoverRV = recoverRV,
    backupMenu = backupMenu, restoreBackup = restoreBackup, toast = toast, state = S, version = VERSION }

log("v" .. VERSION .. " loaded, saves in " .. SAVE_DIR)
