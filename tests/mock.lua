-- Mock test for CyberslopKiroshiNetLink\init.lua 1.7.1. Run from an empty temp folder (it writes config.json):
--   luajit mock.lua "<path to init.lua>"
-- The world here is a small physical model: a car / V that move every frame, a rendered camera whose pose
-- the camera system reports renderLag frames late, teleports that land tpLag frames late, a device that
-- rides V's body root once bound (keepWorldTransform true = stays where it is; false = old world coordinates
-- become the offset, as seen in game with 1.7.0), and a device camera / screen with local transforms.
local fails, checks = 0, 0
local function check(c, label) checks = checks + 1; if c then print('ok   ' .. label) else fails = fails + 1; print('FAIL ' .. label) end end
local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-4) end

------------------------------------------------------------------ CET / game stubs
local hotkeys, events, observers = {}, {}, {}
function registerHotkey(id, label, fn) hotkeys[id] = { label = label, fn = fn } end
function registerForEvent(e, fn) events[e] = fn end
function ObserveAfter(c, m, fn) observers[c .. '.' .. m] = fn end
function IsDefined(x) return x ~= nil end
local printed = {}
local realPrint = print
function print(...) local t = table.concat({ ... }, ' '); table.insert(printed, t); realPrint(t) end
local function printedHas(text, from)
    for i = from or 1, #printed do if printed[i]:find(text, 1, true) then return true end end
    return false
end
local savedCfg = nil
json = { encode = function(t) savedCfg = {}; for k, val in pairs(t) do savedCfg[k] = val end; return '{}' end,
         decode = function() return savedCfg or {} end }
ImGui = {}
function ToVariant(x) return x end
gameSimpleScreenMessage = { new = function() return {} end }
Enum = { new = function(n, x) return n .. ':' .. tostring(x) end }
EntityID = { new = function() return { hash = 0 } end }
Vector4 = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
local Q = {}
Q.__index = Q
function Q:ToEulerAngles() return { quat = { i = self.i, j = self.j, k = self.k, r = self.r } } end
Quaternion = { new = function(i, j, k, r) return setmetatable({ i = i, j = j, k = k, r = r }, Q) end }
Transform = { new = function() return {} end }
DynamicEntitySpec = { new = function() return {} end }
Matrix = { GetTranslation = function(m) return m.t end, ToQuat = function(m) return m.q end }

------------------------------------------------------------------ pose maths (own copy, independent of the mod)
local function qmul(a, b)
    return { i = a.r * b.i + a.i * b.r + a.j * b.k - a.k * b.j, j = a.r * b.j - a.i * b.k + a.j * b.r + a.k * b.i,
             k = a.r * b.k + a.i * b.j - a.j * b.i + a.k * b.r, r = a.r * b.r - a.i * b.i - a.j * b.j - a.k * b.k }
end
local function qconj(a) return { i = -a.i, j = -a.j, k = -a.k, r = a.r } end
local function qrot(a, p)
    local u = qmul(qmul(a, { i = p.x, j = p.y, k = p.z, r = 0 }), qconj(a))
    return { x = u.i, y = u.j, z = u.k }
end
local function yawQ(deg) local h = math.rad(deg) / 2; return { i = 0, j = 0, k = math.sin(h), r = math.cos(h) } end
local function pitchQ(deg) local h = math.rad(deg) / 2; return { i = math.sin(h), j = 0, k = 0, r = math.cos(h) } end
local function P(x, y, z, r) return { p = { x = x, y = y, z = z }, r = r or yawQ(0) } end
local function pmul(a, b)
    local o = qrot(a.r, b.p)
    return { p = { x = a.p.x + o.x, y = a.p.y + o.y, z = a.p.z + o.z }, r = qmul(a.r, b.r) }
end
local function pinv(a)
    local c = qconj(a.r)
    local o = qrot(c, a.p)
    return { p = { x = -o.x, y = -o.y, z = -o.z }, r = c }
end
local function pdist(a, b)
    local dx, dy, dz = a.p.x - b.p.x, a.p.y - b.p.y, a.p.z - b.p.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
local function pang(a, b)
    local d = math.abs(a.r.i * b.r.i + a.r.j * b.r.j + a.r.k * b.r.k + a.r.r * b.r.r)
    return math.deg(2 * math.acos(math.min(1, d)))
end

------------------------------------------------------------------ world
local DT = 0.016
local SEAT = P(-0.4, 0.1, 0.3)                       -- V's body root in the car
local CAR_EYE = P(-0.4, 0.2, 1.2, pitchQ(-4))        -- V's eyes in the car
local CAR_TPP = P(0, -6, 2.5, pitchQ(-10))           -- chase camera
local EYE = P(0, 0, 1.7)                             -- V's eyes on foot
local world = { frame = 0, now = 0, renderLag = 1, simLag = 0, tpLag = 1, bindMode = 'ok', camIgnoresLocal = false }
local player = { pose = P(-1500, 2800, 30), dead = false }
local vehicle = nil                                  -- { pose, speed (m/s), yawRate (deg/s) }
local tppOn, cine = false, false
local bb = { IsUIZoomDevice = false, IsInteractingWithDevice = false, UIZoomDeviceID = { hash = 0 }, SceneTier = 1 }
local bd = { IsActive = false }
local screen, sounds, teleports, queued, binds = {}, {}, {}, {}, {}
local unbinds = 0
local spawnDelay, zoomWorks = 3, true
local entities, nextId, created, deleted = {}, 100, {}, {}
local timers, pendingTp = {}, {}
deletedWhileZoomed = false
local MESH_ROT = { i = 0.0, j = -0.70710678, k = 0.70710678, r = 0.0 }

local function playerRoot() return vehicle and pmul(vehicle.pose, SEAT) or player.pose end
local function vCam()
    if vehicle then return pmul(vehicle.pose, tppOn and CAR_TPP or CAR_EYE) end
    return pmul(player.pose, EYE)
end
local function devCam(d)
    if world.camIgnoresLocal then return d.world end
    return pmul(d.world, d.camLocal)
end
local function zoomedDevice()
    if not bb.IsUIZoomDevice then return nil end
    local e = entities[bb.UIZoomDeviceID.hash]
    return e and e.dev
end
local vHist, lagged = {}, nil
local function activeCam() -- what the camera system reports: the rendering camera, renderLag frames late
    local d = zoomedDevice()
    local hist = d and d.hist or vHist
    return hist[world.frame - world.renderLag] or hist[world.frame] or vCam()
end

function player:GetEntityID() return { hash = 1 } end
function player:GetWorldPosition() return playerRoot().p end
function player:GetWorldOrientation() return playerRoot().r end
function player:IsDead() return self.dead end
function player:GetEntity() return { player = true } end
function player:GetFPPCameraComponent()
    return { GetLocalToWorld = function() local c = vCam(); return { t = c.p, q = c.r } end, Activate = function() end,
             GetName = function() return { value = 'camera' } end }
end
function GetMountedVehicle()
    if not vehicle then return nil end
    return { GetWorldPosition = function() return vehicle.pose.p end, GetWorldOrientation = function() return vehicle.pose.r end,
             GetEntityID = function() return { hash = vehicle.id or 777 } end }
end

local function makeDevice(id, spec)
    local d = { id = id, comps = {}, world = { p = spec.position, r = spec.orientation }, camLocal = P(0, 0, 0),
                meshPos = nil, meshRot = MESH_ROT, hist = {}, simHist = {} }
    d.comps.cameraZoomComponent = {
        SetFOV = function(self, f) self.fov = f end,
        SetLocalPosition = function(_, p) d.camLocal = { p = { x = p.x, y = p.y, z = p.z }, r = d.camLocal.r } end,
        SetLocalOrientation = function(_, r) d.camLocal = { p = d.camLocal.p, r = { i = r.i, j = r.j, k = r.k, r = r.r } } end,
        GetLocalToWorld = function() local c = d.simHist[world.frame - world.simLag] or devCam(d); return { t = c.p, q = c.r } end }
    d.comps.computer = {
        SetLocalPosition = function(_, p) d.meshPos = { x = p.x, y = p.y, z = p.z } end,
        SetLocalOrientation = function(_, r) d.meshRot = { i = r.i, j = r.j, k = r.k, r = r.r } end,
        GetLocalOrientation = function() return d.meshRot end }
    local root = { SetOpacity = function(self, o) self.opacity = o end }
    d.root = root
    d.comps.terminalui = { GetGameController = function() return { GetRootWidget = function() return root end } end }
    function d:RegisterPlayerInputListener() end
    function d:SetZoomBlackboardValues(on) d.released = true; bb.IsUIZoomDevice = on; if not on then bb.UIZoomDeviceID = { hash = 0 } end end
    function d:ToggleCameraZoom() end
    function d:FindComponentByName(n) return self.comps[n] end
    function d:GetEntity() return { dev = d } end
    function d:GetWorldPosition() return d.world.p end
    function d:GetDevicePS()
        if not self.ready then return nil end
        return { ActionQuestForceCameraZoom = function(_, on, instant) return { dev = d, on = on, instant = instant } end,
                 SetAdvancedInteractionModeOn = function() end }
    end
    return d
end

-- the engine binding: bindMode ok = as vanilla, off = the call does nothing, garbage = keepWorldTransform acts as false
local function doBind(d, comp, keep)
    table.insert(binds, { comp = comp, keep = keep })
    if world.bindMode == 'off' then return end
    d.bound = true
    if keep and world.bindMode ~= 'garbage' then d.rootRel = pmul(pinv(playerRoot()), d.world) else d.rootRel = d.world end
end
local function doUnbind(d) unbinds = unbinds + 1; d.bound = false end

local function after(sec, fn) table.insert(timers, { at = world.now + sec, fn = fn }) end

local des = {
    CreateEntity = function(_, spec) nextId = nextId + 1; local id = { hash = nextId }
        entities[nextId] = { spec = spec, frames = 0, dev = makeDevice(id, spec) }; table.insert(created, spec); return id end,
    IsSpawned = function(_, id) local e = entities[id.hash]; return e ~= nil and e.frames >= spawnDelay end,
    GetEntity = function(_, id) local e = entities[id.hash]; return e and e.dev end,
    DeleteEntity = function(_, id)
        if bb.IsUIZoomDevice and bb.UIZoomDeviceID.hash == id.hash then deletedWhileZoomed = true end
        table.insert(deleted, id.hash); entities[id.hash] = nil; return true end,
    DeleteTagged = function() end,
}

local teleportFacility = { Teleport = function(_, ent, p, e)
    table.insert(teleports, { ent = ent, p = p, q = e.quat })
    table.insert(pendingTp, { at = world.frame + world.tpLag, ent = ent, pose = { p = { x = p.x, y = p.y, z = p.z }, r = e.quat } })
end }

Game = {
    GetPlayer = function() return setmetatable({}, { __index = player }) end,
    GetCameraSystem = function() return {
        GetActiveCameraWorldTransform = function(_, t) local c = activeCam(); t.position = c.p; t.orientation = c.r; return true end,
        GetActiveCameraFOV = function() return 68 end } end,
    GetSettingsSystem = function() return { GetVar = function() return { GetValue = function() return 80 end } end } end,
    GetDynamicEntitySystem = function() return des end,
    GetTeleportationFacility = function() return teleportFacility end,
    GetPersistencySystem = function() return { QueuePSDeviceEvent = function(_, a)
        table.insert(queued, a)
        if not entities[a.dev.id.hash] then return end
        if a.on then
            if zoomWorks then after(0.02, function() bb.IsUIZoomDevice = true; bb.UIZoomDeviceID = a.dev.id end) end
        else
            after(0.5, function() bb.IsUIZoomDevice = false; bb.UIZoomDeviceID = { hash = 0 } end)
        end
    end } end,
    GetBlackboardSystem = function() return {
        GetLocalInstanced = function() return {
            GetBool = function(_, k) return bb[k] end, GetInt = function(_, k) return bb[k] end,
            GetEntityID = function(_, k) return bb[k] end, SetBool = function(_, k, x) bb[k] = x end,
            SetEntityID = function(_, k, x) bb[k] = x end } end,
        Get = function(_, defs)
            if defs == 'BD' then return { GetBool = function() return bd.IsActive end } end
            if defs == 'AV' then return { GetBool = function() return tppOn end } end
            if defs == 'AD' then return { GetBool = function() return cine end } end
            return { SetVariant = function(_, _, x) table.insert(screen, x.message) end } end } end,
    GetUISystem = function() return { PopGameContext = function() end } end,
}
GameObject = { PlaySoundEvent = function(_, n) table.insert(sounds, n) end }
function GetAllBlackboardDefs()
    return {
        PlayerStateMachine = { IsUIZoomDevice = 'IsUIZoomDevice', IsInteractingWithDevice = 'IsInteractingWithDevice',
            UIZoomDeviceID = 'UIZoomDeviceID', SceneTier = 'SceneTier' },
        Braindance = 'BD', UI_ActiveVehicleData = 'AV', UI_AutodriveData = 'AD',
        UI_Notifications = { OnscreenMessage = 1 },
    }
end
CyberslopNetLinkBind = function(child, target, comp, keep) doBind(child, comp, keep); return true end
CyberslopNetLinkUnbind = function(child) doUnbind(child); return true end

------------------------------------------------------------------ load + frame loop
local mod = dofile(arg[1])
events.onInit()
local st, cfg = mod._state, mod._cfg
cfg.sounds = true

local function tick(sec)
    local n = math.max(1, math.floor(sec / DT + 0.5))
    for _ = 1, n do
        world.frame = world.frame + 1
        local DT = DT * (1 + (world.jitter or 0) * math.sin(world.frame * 1.7)) -- uneven frame times when asked
        world.now = world.now + DT
        local due = {}
        for i = #timers, 1, -1 do if timers[i].at <= world.now then table.insert(due, timers[i]); table.remove(timers, i) end end
        for _, t in ipairs(due) do t.fn() end
        -- motion
        if vehicle and vehicle.speed then
            local fwd = qrot(vehicle.pose.r, { x = 0, y = vehicle.speed * DT, z = 0 })
            local rot = vehicle.yawRate and qmul(vehicle.pose.r, yawQ(vehicle.yawRate * DT)) or vehicle.pose.r
            vehicle.pose = { p = { x = vehicle.pose.p.x + fwd.x, y = vehicle.pose.p.y + fwd.y, z = vehicle.pose.p.z + fwd.z }, r = rot }
        elseif player.speed then
            player.pose = { p = { x = player.pose.p.x, y = player.pose.p.y + player.speed * DT, z = player.pose.p.z }, r = player.pose.r }
        end
        -- teleports that land this frame
        for i = #pendingTp, 1, -1 do
            local t = pendingTp[i]
            if t.at <= world.frame then
                if t.ent.bound then t.ent.rootRel = t.pose else t.ent.world = t.pose end -- bound: it is a local offset
                table.remove(pendingTp, i)
            end
        end
        -- bound devices ride V's body root
        local pr = playerRoot()
        for _, e in pairs(entities) do
            e.frames = e.frames + 1
            if e.frames >= spawnDelay + 2 then e.dev.ready = true end
            if e.dev.bound then e.dev.world = pmul(pr, e.dev.rootRel) end
            e.dev.hist[world.frame] = devCam(e.dev)
            e.dev.simHist[world.frame] = devCam(e.dev)
        end
        vHist[world.frame] = vCam()
        events.onUpdate(DT)
    end
end
local function press() hotkeys.netlink.fn() end
local function device() local _, e = next(entities); return e and e.dev end
local function viewError() local d = device(); return pdist(devCam(d), vCam()), pang(devCam(d), vCam()) end
local function closeIt() if st.state ~= 'idle' then press(); tick(1.6) end; assert(st.state == 'idle', 'not idle: ' .. st.state) end
-- the screen sits where 1.6.1 put it, seen from the device camera
local function screenOk()
    local d = device()
    local rel = pmul(pinv(d.camLocal), { p = d.meshPos, r = d.meshRot })
    return near(rel.p.x, 0.0049 + cfg.offsetX, 1e-3) and near(rel.p.y, 0.0077 + st.dist, 1e-3) and near(rel.p.z, -0.09745 + cfg.offsetZ, 1e-3)
        and pang({ r = rel.r }, { r = MESH_ROT }) < 0.1
end

check(hotkeys.netlink and hotkeys.netlink.label == 'Open / close Kiroshi NetLink', 'binding registered')
check(observers['PlayerPuppet.OnGameAttached'] ~= nil, 'session reset observer registered')

------------------------------------------------------------------ 1. on foot, standing
press()
check(st.state == 'spawning', 'press -> spawning')
local spec = created[#created]
check(spec.templatePath == 'base\\cyberslop\\kiroshi_netlink\\netlink_screen.ent', 'spawns netlink_screen.ent')
check(spec.tags[1] == 'CyberslopKiroshiNetLink' and spec.persistSpawn == false and spec.persistState == false, 'tagged, not persisted')
tick(0.6)
check(st.state == 'open' and st.mode == 'bound' and st.bindVia == 'redscript', 'open, device bound to V through redscript')
check(binds[#binds].comp == 'slots' and binds[#binds].keep == true, 'bound to the body root with keepWorldTransform true')
check(#teleports == 0, 'no teleport at all while bound')
local e1 = viewError()
check(e1 < 0.001, string.format('standing: device camera on V\'s eyes (%.4f m)', e1))
check(device().comps.cameraZoomComponent.fov ~= nil and sounds[#sounds] == 'ui_focus_mode_zooming_in_enter', 'FOV set, open sound')
check(device().root.opacity == 0.90, 'default opacity on the UI root')
check(queued[#queued].on == true and queued[#queued].instant == true, 'zoom on queued (instant)')
-- V walks off at 7 m/s
player.speed = 7
tick(2.0)
e1 = viewError()
check(e1 < 0.02 and #teleports == 0 and st.mode == 'bound', string.format('running 2 s: still on V\'s eyes (%.4f m), no teleport', e1))
player.speed = nil
closeIt()
check(next(entities) == nil and printedHas('Follow was bound to V'), 'closed, device deleted, follow logged')

------------------------------------------------------------------ 2. geometry clamp (1.6.0)
do
    local g = mod._geometry
    local d80, f80 = g(60)
    check(d80 >= 0.115 and f80 == 60, string.format('FOV 60: %.3f m, camera FOV unchanged', d80))
    local d110, f110 = g(110)
    check(near(d110, 0.115) and f110 < 110, string.format('FOV 110: clamped to 0.115 m, camera FOV %.1f', f110))
end

------------------------------------------------------------------ 3. car at 108 km/h, first person (autodrive)
vehicle = { pose = P(-1400, 2700, 31, yawQ(30)), speed = 30 }
tick(0.3)
local p0 = #printed
press()
local worst, sawOpen = 0, false
for _ = 1, 60 do
    tick(DT)
    if st.state == 'open' then sawOpen = true; worst = math.max(worst, (viewError())) end
end
check(sawOpen and st.mode == 'bound', 'opens while driving, bound')
check(printedHas('Pre-aligned', p0), 'device pre-aligned before the zoom')
check(worst < 0.75, string.format('first frames after the zoom: view at most %.2f m off (one frame of travel is 0.48 m)', worst))
tick(0.3)
local e3, a3 = viewError()
check(e3 < 0.01 and a3 < 0.1, string.format('after the line-up: %.4f m / %.2f deg from V\'s eyes', e3, a3))
check(screenOk(), 'screen still centred in front of the device camera')
local worstHold = 0
for _ = 1, 190 do tick(DT); worstHold = math.max(worstHold, (viewError())) end
check(worstHold < 0.01 and #teleports == 0, string.format('3 s of driving: worst %.4f m, no teleport', worstHold))
check(printedHas('View lined up', p0) or printedHas('View holds', p0), 'line-up logged')
closeIt()
check(cfg.simBiasN >= 1 and near(cfg.simBias, -DT, 0.004), string.format('learned gap between component and rendered view: %.4f s', cfg.simBias))
-- second open: the learned gap makes the pre-alignment exact
p0 = #printed
press(); worst = 0
for _ = 1, 60 do tick(DT); if st.state == 'open' then worst = math.max(worst, (viewError())) end end
check(worst < 0.03, string.format('second open: never more than %.3f m off, from the first frame', worst))
check(printedHas('View holds', p0) and not printedHas('View lined up', p0), 'second open needs no correction')
closeIt()

------------------------------------------------------------------ 4. turning car
vehicle.yawRate = 20; vehicle.speed = 20
tick(0.2); press(); tick(1.0)
worstHold = 0
for _ = 1, 120 do tick(DT); worstHold = math.max(worstHold, (viewError())) end
check(st.mode == 'bound' and worstHold < 0.03, string.format('in a bend at 72 km/h: worst %.4f m', worstHold))
closeIt()
vehicle.yawRate = nil; vehicle.speed = 30

------------------------------------------------------------------ 5. third person
tppOn = true
tick(0.2); press(); tick(1.0)
e3 = viewError()
check(st.mode == 'bound' and e3 < 0.02, string.format('third person at 108 km/h: on the chase camera (%.4f m)', e3))
-- camera toggle while open closes the feed
tppOn = false
tick(0.6)
check(st.state == 'closing' and printedHas('Camera toggled: closing'), 'camera toggle while open: closes')
tick(1.2)
check(st.state == 'idle', 'closed')

------------------------------------------------------------------ 6. V leaves the car while open
press(); tick(1.0)
check(st.state == 'open', 'open in the car')
player.pose = pmul(vehicle.pose, SEAT)
vehicle = nil
tick(0.6)
check(st.state == 'closing' and printedHas('V got in / out of a vehicle: closing'), 'leaving the car while open: closes')
tick(1.2)
check(st.state == 'idle', 'closed')
vehicle = { pose = P(-1300, 2600, 31, yawQ(-50)), speed = 30 }
tick(0.2)

------------------------------------------------------------------ 7. the binding call does nothing
world.bindMode = 'off'
p0 = #printed
press(); tick(1.5)
check(st.state == 'open' and st.mode == 'teleport' and printedHas('Native follow off (device does not ride with V', p0), 'binding that does not hold: found by the line-up, teleport follow')
worstHold = 0
for _ = 1, 120 do tick(DT); worstHold = math.max(worstHold, (viewError())) end
check(worstHold < 0.03 and #teleports > 0, string.format('teleport follow with its lag taken out: worst %.4f m', worstHold))
check(screenOk(), 'screen centred in teleport follow')
closeIt()

------------------------------------------------------------------ 8. keepWorldTransform ignored by the engine (device km away)
world.bindMode = 'garbage'
p0 = #printed
press(); tick(1.5)
check(st.state == 'open' and st.mode == 'teleport' and printedHas('Pre-alignment skipped', p0), 'device km away after the bind: not pre-aligned, given up')
e3 = viewError()
check(e3 < 0.03, string.format('held by teleport instead (%.4f m)', e3))
closeIt()
world.bindMode = 'ok'

------------------------------------------------------------------ 9. no binding calls at all (redscript file missing, CET call fails)
local keepBind, keepUnbind = CyberslopNetLinkBind, CyberslopNetLinkUnbind
CyberslopNetLinkBind, CyberslopNetLinkUnbind = nil, nil
p0 = #printed
press(); tick(1.5)
check(st.state == 'open' and st.mode == 'teleport' and printedHas('Follow: teleport, anchor vehicle', p0), 'no binding available: teleport follow from the start')
e3 = viewError()
check(e3 < 0.03, string.format('lined up all the same (%.4f m)', e3))
closeIt()
-- straight from CET
EntityGameInterface = {
    BindToComponent = function(c, tgt, comp, slot, keep) assert(tgt.player and slot == 'None'); doBind(c.dev, comp, keep) end,
    UnbindTransform = function(c) doUnbind(c.dev) end }
press(); tick(1.0)
check(st.mode == 'bound' and st.bindVia == 'CET' and (viewError()) < 0.01, 'without netlink_bind.reds: bound straight from CET, lined up')
closeIt()
EntityGameInterface = nil
CyberslopNetLinkBind, CyberslopNetLinkUnbind = keepBind, keepUnbind

------------------------------------------------------------------ 10. device camera ignores its local transform
world.camIgnoresLocal = true
cfg.simBias, cfg.simBiasN = 0, 0
p0 = #printed
press(); tick(2.5)
check(printedHas('ignores its local transform', p0) and st.mode == 'teleport', 'ignored camera transform found, teleport follow')
e3 = viewError()
check(st.state == 'open' and e3 < 0.03, string.format('corrected through the teleport offset (%.4f m)', e3))
check(screenOk(), 'screen back in front of the camera')
closeIt()
world.camIgnoresLocal = false

------------------------------------------------------------------ 11. component transform one frame stale as well
world.simLag = 1
cfg.simBias, cfg.simBiasN = 0, 0
press(); tick(1.2)
e3 = viewError()
check(st.mode == 'bound' and e3 < 0.01, string.format('stale component transform: still lined up (%.4f m)', e3))
closeIt()
world.simLag = 0

------------------------------------------------------------------ 11b. uneven frame times (+-30 %) at 108 km/h
world.jitter = 0.3
p0 = #printed
press(); tick(1.5)
e3 = viewError()
check(st.state == 'open' and st.mode == 'bound' and not printedHas('Native follow off', p0), 'uneven frame times: binding kept')
check(e3 < 0.10, string.format('uneven frame times: lined up within %.3f m', e3))
worstHold = 0
local tel0 = #teleports
for _ = 1, 150 do tick(DT); worstHold = math.max(worstHold, (viewError())) end
check(math.abs(worstHold - e3) < 0.005 and #teleports == tel0, string.format('and steady from then on (%.3f m, no teleport)', worstHold))
closeIt()
world.bindMode = 'off' -- teleport follow under the same frame times
press(); tick(2.0)
worstHold = 0
for _ = 1, 150 do tick(DT); worstHold = math.max(worstHold, (viewError())) end
check(st.state == 'open' and st.mode == 'teleport' and worstHold < 0.45, string.format('teleport follow, uneven frames: worst %.3f m (its frame-time shake stays)', worstHold))
closeIt()
world.bindMode = 'ok'
world.jitter = nil

------------------------------------------------------------------ 12. vanilla UI_Exit, hotkey close, refusals, timeouts
vehicle = nil
player.pose = P(-1500, 2800, 30)
tick(0.1)
press(); tick(0.6)
bb.IsUIZoomDevice = false; bb.UIZoomDeviceID = { hash = 0 }
tick(0.05)
check(st.state == 'closing', 'exit seen -> closing')
tick(0.75)
check(st.state == 'idle' and next(entities) == nil, 'entity deleted after exit')
press(); tick(0.6)
press()
check(queued[#queued].on == false, 'hotkey queues zoom off')
tick(0.3)
check(next(entities) ~= nil and st.state == 'closing', 'entity kept while IsUIZoomDevice still true')
tick(1.2)
check(st.state == 'idle' and next(entities) == nil, 'deleted once the zoom flag is gone')

local before = #created
bb.SceneTier = 4; screen = {}
press()
check(#created == before and screen[1] == 'NetLink unavailable: cinematic scene', 'refused in a cinematic scene')
bb.SceneTier = 1
bd.IsActive = true; press()
check(#created == before, 'refused in braindance'); bd.IsActive = false
bb.IsUIZoomDevice = true; bb.UIZoomDeviceID = { hash = 5 }; press()
check(#created == before, 'refused while V uses another device')
bb.IsUIZoomDevice = false; bb.UIZoomDeviceID = { hash = 0 }
cine = true; screen = {}; press()
check(#created == before and screen[1] == 'NetLink unavailable: autodrive cinematic camera', 'refused during the autodrive cinematic camera')
cine = false; press(); tick(0.6)
check(st.state == 'open', 'opens without it')
cine = true; tick(0.05)
check(st.state == 'closing', 'cinematic camera while open: closes')
cine = false; tick(1.6)
check(st.state == 'idle', 'closed')

spawnDelay = 100000
press(); tick(6.5)
check(st.state == 'idle' and next(entities) == nil, 'spawn timeout cleans up')
spawnDelay = 3

zoomWorks = false
local q0 = #queued
press(); tick(4.0)
local ons = 0
for i = q0 + 1, #queued do if queued[i].on then ons = ons + 1 end end
check(ons == 2, 'zoom asked twice')
check(st.state == 'idle' and next(entities) == nil, 'zoom failure cleans up')

press(); tick(0.03)
local stateAtCancel = st.state
press()
check(stateAtCancel == 'spawning' and st.state == 'idle' and next(entities) == nil, 'cancel while spawning deletes at once')
press()
for _ = 1, 40 do tick(DT); if st.state == 'opening' then break end end
check(st.state == 'opening', 'reached opening')
press()
check(st.state == 'closing' and queued[#queued].on == false, 'cancel while opening queues zoom off')
tick(1.6)
check(st.state == 'idle' and next(entities) == nil, 'cancelled open cleaned up')
zoomWorks = true

------------------------------------------------------------------ 13. errors inside update recover
press(); tick(0.6)
local savedBB = Game.GetBlackboardSystem
Game.GetBlackboardSystem = function() error('boom') end
tick(0.05)
Game.GetBlackboardSystem = savedBB
check(st.state == 'purge' and next(entities) ~= nil, 'update error: camera released, entity kept a moment')
tick(0.8)
check(st.state == 'idle' and next(entities) == nil and not deletedWhileZoomed, 'update error cleans up after the release')

------------------------------------------------------------------ 14. screen dimmer (1.3.0)
local dimSys = { on = false, dark = 0, sets = 0 }
function dimSys:IsOn() return self.on end
function dimSys:Darkness() return self.dark end
function dimSys:Set(on, d) self.on = on; self.dark = d; self.sets = self.sets + 1 end
local dimAvailable = true
Game.GetScriptableSystemsContainer = function() return { Get = function(_, n)
    if dimAvailable and n == 'DVGradeProbe.DVGP_State' then return dimSys end end } end
check(hotkeys.netlink_dim ~= nil, 'dimmer hotkey registered')
tick(1.2)
check(dimSys.sets == 0, 'dimmer off by default: nothing pushed')
hotkeys.netlink_dim.fn()
check(dimSys.on == true and near(dimSys.dark, 0.5), 'hotkey turns the dimmer on at 50 %')
dimSys.on, dimSys.dark = false, 0
tick(1.2)
check(dimSys.on == true and near(dimSys.dark, 0.5), 'state re-pushed after the system reset')
hotkeys.netlink_dim.fn()
check(dimSys.on == false, 'hotkey off')
dimAvailable = false
check(pcall(hotkeys.netlink_dim.fn), 'missing redscript system: no crash')

realPrint(string.format('\n%d/%d checks passed', checks - fails, checks))
os.exit(fails == 0 and 0 or 1)
