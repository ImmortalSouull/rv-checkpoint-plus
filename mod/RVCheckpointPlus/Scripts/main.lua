-- RV Checkpoint+  (RV There Yet?, UE4SS Lua)
-- Quick save anywhere, quick load, pick an earlier checkpoint, unstuck player, recover RV,
-- and auto-save after repairs. Host-side: everything runs on the machine that hosts the game.

local VERSION = "1.0.0"

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

local function placeRV(rv, loc, yaw, pitch, roll)
    rv:K2_SetActorLocationAndRotation(loc, { Pitch = pitch or 0, Yaw = yaw, Roll = roll or 0 }, false, {}, true)
    stopRV(rv)
    pcall(function() rv:FixTiresAfterTeleport() end)
    -- physics can keep a tiny bit of momentum from the frame we moved in
    ExecuteWithDelay(150, function() ExecuteInGameThread(function() if valid(rv) then stopRV(rv) end end) end)
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
    return v3(l.X + f.X * o[1] + r.X * o[2], l.Y + f.Y * o[1] + r.Y * o[2], l.Z + 120)
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
    lastRecover = -100,
    hooked = false,
    busyUntil = 0,
}

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

    local data = {
        v = 1, mod = VERSION, session = si.name, level = si.level, cp = si.cp, time = os.time(),
        rv = pose,
        players = {},
    }
    for _, pc in ipairs(all("BP_FirstPersonPlayerController_C")) do
        local pawn = pc.Pawn
        if valid(pawn) then
            local pl = pawn:K2_GetActorLocation()
            data.players[#data.players + 1] = { name = playerName(pc), x = pl.X, y = pl.Y, z = pl.Z,
                yaw = pawn:K2_GetActorRotation().Yaw, inRV = isInRV(pawn, rv) }
        end
    end
    if writeSidecar(si, data) then
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
    S.menu["until"] = NOW + 8
    showMenu()
end

local function unstuckPlayers(everyone)
    local rv = getRV()
    if not rv then return end
    if everyone then
        if not hostOnly() then return end
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
local function startRestore(data)
    S.restore = { data = data, stage = "wait", at = NOW + 1.5, deadline = NOW + 40 }
end

local function stepRestore()
    local R = S.restore
    if not R or NOW < R.at then return end
    if NOW > R.deadline then log("restore timed out"); S.restore = nil; return end
    local rv, pc = getRV(), localPC()
    local d = R.data
    local target = v3(d.rv.x, d.rv.y, d.rv.z)

    if R.stage == "wait" then
        if not (rv and pc and valid(pc.Pawn)) then R.at = NOW + 0.5; return end
        -- After a restart the game re-seats players in the RV, so the host may be riding along.
        -- Park the RV, frozen, just above the saved spot; whoever sits in it comes with it, and the
        -- World Partition streams the area in around the host before anything touches the ground.
        local far = dist(rv:K2_GetActorLocation(), target) > 20000
        pcall(function() rv.RootComponent:SetSimulatePhysics(false) end)
        rv:K2_SetActorLocationAndRotation(v3(target.X, target.Y, target.Z + 300),
            { Pitch = 0, Yaw = d.rv.yaw, Roll = 0 }, false, {}, true)
        if not seated(pc.Pawn) then
            local yr = math.rad(d.rv.yaw)
            teleportPlayer(pc, v3(target.X + math.sin(yr) * 420, target.Y - math.cos(yr) * 420, target.Z + 150), d.rv.yaw)
        end
        toast("Restoring your quick save...", 3)
        R.stage = "rv"; R.at = NOW + (far and 4.0 or 2.0)
    elseif R.stage == "rv" then
        if not rv then R.at = NOW + 0.5; return end
        -- a save made mid-corner can carry a lot of body roll; keep the slope, drop the lean,
        -- and let the suspension settle it
        local function clamp(a) return math.max(-20, math.min(20, a)) end
        local pitch, roll = clamp(d.rv.pitch), clamp(d.rv.roll)
        rv:K2_SetActorLocationAndRotation(v3(target.X, target.Y, target.Z + 60),
            { Pitch = pitch, Yaw = d.rv.yaw, Roll = roll }, false, {}, true)
        pcall(function() rv.RootComponent:SetSimulatePhysics(true) end)
        placeRV(rv, v3(target.X, target.Y, target.Z + 60), d.rv.yaw, pitch, roll)
        R.stage = "players"; R.at = NOW + 1.5
    elseif R.stage == "players" then
        local byName = {}
        for _, p in ipairs(d.players or {}) do byName[p.name] = p end
        for i, p in ipairs(all("BP_FirstPersonPlayerController_C")) do
            local s = byName[playerName(p)]
            if valid(p.Pawn) and seated(p.Pawn) then
                -- sitting in the RV: already where they belong
            elseif s and not s.inRV and dist(v3(s.x, s.y, s.z), target) < 4000 then
                teleportPlayer(p, v3(s.x, s.y, s.z + 30), s.yaw)
            else
                teleportPlayer(p, spotNextToRV(rv, i), d.rv.yaw)
            end
        end
        S.restore = nil
        S.safe = {}
        S.health = nil
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
    if data.cp == si.cp then startRestore(data) end
end

---------------------------------------------------------------------------
-- main loop (host): level detection, safe-spot tracking, repair autosave
---------------------------------------------------------------------------
local function tick()
    local gm = getGM()
    if not gm then S.gmAddr = nil; return end
    local addr = gm:GetAddress()
    if addr ~= S.gmAddr then S.gmAddr = addr; onLevelStart() end

    checkLoad()
    stepRestore()

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
    if S.menu and NOW < S.menu["until"] then
        local sel = S.menu.sel; S.menu = nil
        goToCheckpoint(sel)
    else
        quickLoad()
    end
end)
bind("checkpoint_menu", "F8", checkpointMenu)
bind("unstuck_player", "F6", function() unstuckPlayers(false) end)
bind("unstuck_player", "F6", function() unstuckPlayers(true) end, { ModifierKey.SHIFT })
bind("recover_rv", "F7", recoverRV)

-- expose for testing from other scripts
_G.RVCP = { quickSave = quickSave, quickLoad = quickLoad, goToCheckpoint = goToCheckpoint,
    checkpointMenu = checkpointMenu, unstuckPlayers = unstuckPlayers, recoverRV = recoverRV,
    toast = toast, state = S, version = VERSION }

log("v" .. VERSION .. " loaded, saves in " .. SAVE_DIR)
