-- Cyberslop Kiroshi NetLink 1.7.1 (2026-11-23)
-- 1.7.1: 1.7.0 failed its in-game test (view from the footwell / from behind the seat). Its log: the binding with
--        keepWorldTransform false keeps the device's old world coordinates as an offset from the bound
--        component (device 3239 m off its camera), and the fallback then took its pose from the FPP camera
--        component, which is not V's view in a car. Now:
--        * the device is bound to V's body root (player component "slots") with keepWorldTransform true, the
--          flag vanilla uses: it stays where it is and rides with V (and so with the car) inside the engine;
--        * its camera is lined up against V's real view: V's rendered camera is measured relative to V / the
--          car before the zoom, the device camera the same way after it, and the difference is taken out
--          through the device camera's and screen's local transforms (a few frames after the zoom, checked
--          once more after that). No single pose source is trusted on its own any more;
--        * before the zoom the device is pre-aligned from its component transform, so the first frames are
--          close already; the gap between that and the rendered view is learned (config simBias);
--        * entering / leaving a vehicle or a camera toggle closes the feed (the view would be stale);
--        * if the binding does not hold, the device goes back to the per-frame teleport of 1.6.1, with the
--          same line-up taking out its average lag.
-- 1.7.0: first native binding (to V's camera component, keepWorldTransform false): wrong, see above.
-- 1.6.1: review fixes: unticking "Darken screen" in the window works again (syncDim was called before it
--        existed, since 1.3.0); a hit on V while open no longer deletes the device mid camera blend-out
--        (LINGER 0.6 s); "Reload all mods" while open releases the camera first and the new instance
--        deletes the old device 0.6 s later; spawning times out even when the entity exists; refuses
--        during camera takeover (security cameras, turrets); minimum screen distance 0.115 m (on foot unchanged
--        from 1.3.0 at ultrawide).
-- 1.6.0: works in vehicles. The device camera clips everything closer than about 0.105 m (near plane); the
--        vehicle FPP camera is wider (FOV 70-76 vs 59 on foot), so 1.3.0 put the screen at 0.09-0.10 m and it
--        vanished the moment the device camera took over (seen only before the switch and after closing).
--        The screen now never comes closer than 0.12 m; when the panel width needs it closer, the device
--        camera FOV is narrowed instead, so the panel keeps its share of the view. Built on 1.3.0
--        (1.4.0 / 1.5.0 were a reverted track).
-- 1.3.0: screen dimmer: toggle + darkness slider, a uniform dark grade over the whole picture through
--        DigitalVixenCore's grading service (r6\scripts\CyberslopKiroshiNetLink\netlink_dim.reds, the
--        DVGradeProbe layer slot; True Sunglasses uses slot 0, both stack). Optional hotkey.
-- 1.1.0: opacity slider (see-through screen material + ink root opacity), size slider up to the full view
--        (distance from vertical FOV x aspect), Unstick no longer deletes a device whose camera is active
--        (1.0.0 crash), anchor compared by entity id (1.0.0 logged "Anchor now player" every frame).
-- V opens a computer (NET, mail, files, Atelier) straight in the Kiroshi optics: one key, no radial wheel,
-- no tablet, no hands. The screen floats in front of V's eyes and stays there while V walks, drives or swims.
--
-- How it works (2.5 scripts):
--   * archive\pc\mod\CyberslopKiroshiNetLink.archive has base\cyberslop\kiroshi_netlink\netlink_screen.ent:
--     the vanilla Computer device from Computer Anywhere's tablet_computer.ent, reduced to the screen quad
--     (chunkMask 4, component "computer", no parent) and its zoom camera ("cameraZoomComponent", no parent,
--     at the entity origin looking +Y at the screen); the UI component "terminalui" hangs on the mesh.
--   * Open: spawn it with Codeware's DynamicEntitySystem at the active camera, set the device camera FOV to
--     V's FOV and the screen distance from the panel size, then queue the device's own
--     ActionQuestForceCameraZoom(true) (Device.OnQuestForceCameraZoom -> EvaluateCameraZoomState ->
--     ToggleCameraZoom: camera switch + UIGameContext.DeviceZoom + PSM IsUIZoomDevice; vanilla also lowers
--     the weapon while IsUIZoomDevice is set).
--   * Follow: see 1.7.1 above. "View" below always means a camera pose relative to the anchor (V on foot, the
--     vehicle V sits in), read from the camera system (the camera that renders) and the anchor in one go.
--   * Close: vanilla UI_Exit (InteractiveDevice.OnAction) or the hotkey again (ActionQuestForceCameraZoom(false)).
--     The entity is deleted only once PSM IsUIZoomDevice is false again (the camera has blended back),
--     never while the device camera is active.
-- Allowed everywhere (on foot, in vehicles, combat, water). Refused only where the game camera isn't V's:
-- cinematic scenes (scene tier 4-5), braindance, the autodrive cinematic camera, while V is dead, or while V
-- already uses another device.

local MOD = 'CyberslopKiroshiNetLink'
local VERSION = '1.7.1'
local TEMPLATE = 'base\\cyberslop\\kiroshi_netlink\\netlink_screen.ent'
local TAG = 'CyberslopKiroshiNetLink'

-- Screen quad in mesh space (tablet_c_neo_military.mesh chunk 2) and the mesh rotation used in the .ent.
local HALF_W = 0.1169
local CENTRE = { x = 0.0049, y = 0.0077, z = -0.09745 } -- mesh local position minus the distance on y
local MESH_ROT = { i = 0.0, j = -0.70710678, k = 0.70710678, r = 0.0 } -- build_ent.py Q_SCREEN (read live if possible)
-- DIST_MIN: test logs: every open at 0.11 m or more showed the screen, at 0.09-0.10 m it vanished
-- (on foot at width 1.00 and in every car). Closer than this the camera FOV is narrowed instead.
-- 1.6.1: 0.115 (near plane ~0.105): at 3440x1440 the default on-foot open lands at 0.1176 m, so 0.12 narrowed
-- the camera on foot too (FOV 58 from 59); on foot is now exactly as in 1.3.0
local DIST_MIN, DIST_MAX = 0.115, 0.60
local CAM_FOV_MIN = 20
local SIZE_MIN, SIZE_MAX = 0.30, 1.00
local OPACITY_MIN = 0.15
local OPACITY_REFRESH = 1.0 -- s between opacity re-applies while open

local SPAWN_TIMEOUT = 6.0 -- s until the entity and its device PS exist
local SETTLE_TIME = 0.15 -- s after the PS exists before the zoom is queued (UI and camera resolve)
local ZOOM_TIMEOUT = 1.5 -- s per zoom request
local ZOOM_RETRIES = 2
local CLOSE_TIMEOUT = 3.0 -- s waiting for the device to give the camera back
local LINGER = 0.6 -- s kept after IsUIZoomDevice is false before the delete (1.6.1: a hit on V starts a 0.5 s blend-out)
local PURGE_DELAY = 0.6 -- s between a forced camera release and the delete

-- 1.7.1 follow
local BIND_COMP = 'slots' -- V's body root: entSlotComponent on "root" (player_ma_fpp.ent / player_wa_fpp.ent)
local SPEED_CAP = 120 -- m/s, ignores fast-travel jumps
local PRE_N = 6 -- frames of V's own view kept before the zoom (their mean is the target)
local PRE_MAX = 6.0 -- m: a larger pre-alignment is not applied
local CAL_SKIP = 2 -- frames ignored after the zoom / after a correction before the view is measured
local CAL_N = 4 -- frames measured per line-up
local CAL_ROUNDS = 3 -- line-ups per open before it is left alone
local CAL_MIN_POS, CAL_MIN_ANG = 0.02, 0.5 -- m / deg: smaller differences are not corrected ...
local CAL_MIN_PER_SPEED = 0.002 -- ... plus this many seconds of travel (the measure itself wobbles with the frame time)
local CAL_MAX = 10.0 -- m: a larger correction means the device is lost
local SLIP_SPEED, SLIP_MAX = 3.0, 0.5 -- above this speed (m/s), a bound device that falls behind by more than this
                                      -- share of the anchor's travel within the measured frames does not ride with V
local WD_EVERY = 0.5 -- s between view checks once lined up
local WD_SLACK, WD_PER_SPEED = 0.30, 0.01 -- m + s of travel the view may sit off before it counts
local WD_COUNT = 3 -- such checks in a row
local BIAS_MAX = 0.25 -- s: limit of the learned gap between the component transform and the rendered view

local SND_OPEN = 'ui_focus_mode_zooming_in_enter'
local SND_CLOSE = 'ui_focus_mode_zooming_in_exit'

local defaults = { size = 0.62, opacity = 0.90, offsetX = 0.0, offsetZ = 0.0, sounds = true, log = true,
                   dim = false, dimAmount = 0.50, simBias = 0.0, simBiasN = 0 }
local DIM_MAX = 0.95
local DIM_SYNC = 1.0 -- s between checks that the redscript state matches cfg (it resets on every load)
local dimT = 0
local dimWarned = false
local cfg = {}

local mod = { version = VERSION }
local overlay = false
local bootPurge = nil -- 1.6.1: s until the tagged leftovers of a reloaded instance are deleted

-- state: idle | spawning | opening | open | closing | purge
local s = { state = 'idle', t = 0, id = nil, ent = nil, anchor = nil, offPos = nil, offRot = nil,
            zoomSeen = false, tries = 0, settle = 0, last = nil, status = 'idle', fov = 0, camFov = 0, dist = 0,
            -- 1.7.1 follow: mode teleport | bound; tc = device camera pose inside the device (nil = origin);
            -- r0 = V's own view at the zoom; cal = running line-up
            mode = 'teleport', bindTried = false, bindVia = nil, tc = nil, r0 = nil, r0s = {}, cal = nil,
            rounds = 0, vel = nil, prevA = nil, wd = 0, wdT = 0 }

------------------------------------------------------------------------------------------------- helpers
local function log(text) if cfg.log then print('[KiroshiNetLink] ' .. text) end end
local function err(text) print('[KiroshiNetLink] ERROR ' .. text) end

local function onScreen(text)
    pcall(function()
        local defs = GetAllBlackboardDefs().UI_Notifications
        local msg = gameSimpleScreenMessage.new()
        msg.isShown, msg.isInstant, msg.duration, msg.message = true, true, 2, text
        Game.GetBlackboardSystem():Get(defs):SetVariant(defs.OnscreenMessage, ToVariant(msg), true)
    end)
end

local function sound(name)
    if not cfg.sounds then return end
    pcall(function() GameObject.PlaySoundEvent(Game.GetPlayer(), name) end)
end

local function cfgPath() return 'config.json' end

local function loadConfig()
    for k, v in pairs(defaults) do cfg[k] = v end
    local f = io.open(cfgPath(), 'r')
    if not f then return end
    local ok, data = pcall(function() return json.decode(f:read('*a')) end)
    f:close()
    if ok and type(data) == 'table' then
        for k, v in pairs(data) do if defaults[k] ~= nil and type(v) == type(defaults[k]) then cfg[k] = v end end
    end
end

local function saveConfig()
    local f = io.open(cfgPath(), 'w')
    if not f then return end
    f:write(json.encode(cfg))
    f:close()
end

-- Quaternions as plain tables {i, j, k, r}; vectors as {x, y, z}; poses as {p = vector, r = quaternion}.
local function q(t) return { i = t.i, j = t.j, k = t.k, r = t.r } end
local function v(t) return { x = t.x, y = t.y, z = t.z } end
local function qconj(a) return { i = -a.i, j = -a.j, k = -a.k, r = a.r } end
local function qmul(a, b)
    return {
        i = a.r * b.i + a.i * b.r + a.j * b.k - a.k * b.j,
        j = a.r * b.j - a.i * b.k + a.j * b.r + a.k * b.i,
        k = a.r * b.k + a.i * b.j - a.j * b.i + a.k * b.r,
        r = a.r * b.r - a.i * b.i - a.j * b.j - a.k * b.k,
    }
end
local function qnorm(a)
    local n = math.sqrt(a.i * a.i + a.j * a.j + a.k * a.k + a.r * a.r)
    if n < 1e-9 then return { i = 0, j = 0, k = 0, r = 1 } end
    return { i = a.i / n, j = a.j / n, k = a.k / n, r = a.r / n }
end
local function qrot(a, p)
    local cx = a.j * p.z - a.k * p.y
    local cy = a.k * p.x - a.i * p.z
    local cz = a.i * p.y - a.j * p.x
    local ccx = a.j * cz - a.k * cy
    local ccy = a.k * cx - a.i * cz
    local ccz = a.i * cy - a.j * cx
    return { x = p.x + 2 * (a.r * cx + ccx), y = p.y + 2 * (a.r * cy + ccy), z = p.z + 2 * (a.r * cz + ccz) }
end
local function vadd(a, b) return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z } end
local function vsub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
local function vscale(a, f) return { x = a.x * f, y = a.y * f, z = a.z * f } end
local function vdot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function vlen(a) return math.sqrt(vdot(a, a)) end
local function dist3(a, b) return vlen(vsub(a, b)) end
local function qangle(a, b) -- degrees between two orientations
    local d = math.abs(a.i * b.i + a.j * b.j + a.k * b.k + a.r * b.r)
    if d > 1 then d = 1 end
    return math.deg(2 * math.acos(d))
end
local IDENT = { p = { x = 0, y = 0, z = 0 }, r = { i = 0, j = 0, k = 0, r = 1 } }
local function pmul(a, b) return { p = vadd(a.p, qrot(a.r, b.p)), r = qnorm(qmul(a.r, b.r)) } end
local function pinv(a)
    local c = qconj(a.r)
    return { p = qrot(c, vscale(a.p, -1)), r = c }
end
local function prel(anchor, world) return pmul(pinv(anchor), world) end
local function pmean(list)
    local n = #list
    if n == 0 then return nil end
    local p, r = { x = 0, y = 0, z = 0 }, { i = 0, j = 0, k = 0, r = 0 }
    local ref = list[1].r
    for _, e in ipairs(list) do
        p = vadd(p, e.p)
        local sign = (e.r.i * ref.i + e.r.j * ref.j + e.r.k * ref.k + e.r.r * ref.r) < 0 and -1 or 1
        r = { i = r.i + sign * e.r.i, j = r.j + sign * e.r.j, k = r.k + sign * e.r.k, r = r.r + sign * e.r.r }
    end
    return { p = vscale(p, 1 / n), r = qnorm(r) }
end
mod._math = { qmul = qmul, qrot = qrot, qconj = qconj, qnorm = qnorm, pmul = pmul, pinv = pinv, prel = prel,
              pmean = pmean, qangle = qangle }

local function psm()
    local player = Game.GetPlayer()
    local defs = GetAllBlackboardDefs().PlayerStateMachine
    return Game.GetBlackboardSystem():GetLocalInstanced(player:GetEntityID(), defs), defs
end

local function idHash(id)
    if not id then return nil end
    local ok, h = pcall(function() return id.hash end)
    return ok and h and tostring(h) or tostring(id)
end

local function zoomState()
    local bb, defs = psm()
    local on = bb:GetBool(defs.IsUIZoomDevice)
    local dev = idHash(bb:GetEntityID(defs.UIZoomDeviceID))
    return on, dev
end

local function fovNow()
    local fov
    pcall(function() fov = Game.GetCameraSystem():GetActiveCameraFOV() end)
    if not fov or fov < 20 or fov > 140 then
        pcall(function() fov = Game.GetSettingsSystem():GetVar('/graphics/basic', 'FieldOfView'):GetValue() end)
    end
    if not fov or fov < 20 or fov > 140 then fov = 80 end
    return fov
end

local function aspectNow()
    local a
    pcall(function() a = Game.GetCameraSystem():GetAspectRatio() end)
    if not a or a < 1.0 or a > 4.0 then a = 16 / 9 end
    return a
end

-- Camera FOV is vertical (1.0.0 log: FOV 58.8 at V's 16:9 setting), so the view width at distance d is
-- 2 d tan(fov/2) * aspect. size = share of the view width the 23.4 cm screen covers.
-- Returns the screen distance and the device camera FOV: V's FOV, or a narrower one where V's FOV would put
-- the screen inside the near plane (cars, wide FOV, big panel).
local function screenGeometry(fov)
    local aspect = aspectNow()
    local d = HALF_W / (cfg.size * math.tan(math.rad(fov) / 2) * aspect)
    if d >= DIST_MIN then return math.min(DIST_MAX, d), fov end
    local camFov = 2 * math.deg(math.atan(HALF_W / (cfg.size * DIST_MIN * aspect)))
    return DIST_MIN, math.max(CAM_FOV_MIN, math.min(fov, camFov))
end
mod._geometry = screenGeometry

-- World pose of the camera that renders now (V's eyes, the vehicle camera, or the device camera once zoomed).
local function cameraPose()
    local cs = Game.GetCameraSystem()
    local t = Transform.new()
    local ok, a, b = pcall(cs.GetActiveCameraWorldTransform, cs, t)
    local src = t
    if ok then
        if type(b) == 'userdata' then src = b elseif type(a) == 'userdata' then src = a end
    end
    local okp, p, r = pcall(function() return src.position, src.orientation end)
    if okp and p and r and (p.x ~= 0 or p.y ~= 0 or p.z ~= 0) then return v(p), qnorm(q(r)), 'active camera' end
    local m = Game.GetPlayer():GetFPPCameraComponent():GetLocalToWorld()
    return v(Matrix.GetTranslation(m)), qnorm(q(Matrix.ToQuat(m))), 'FPP camera'
end

local function compPose(comp)
    local m = comp:GetLocalToWorld()
    return v(Matrix.GetTranslation(m)), qnorm(q(Matrix.ToQuat(m)))
end

-- CET hands out a new wrapper per call, so anchors are compared by kind + entity id, never by object.
local function anchorObject()
    local player = Game.GetPlayer()
    local veh = GetMountedVehicle(player)
    if veh and IsDefined(veh) then return veh, 'vehicle', 'vehicle:' .. tostring(idHash(veh:GetEntityID())) end
    return player, 'player', 'player'
end

local function objPose(obj) return v(obj:GetWorldPosition()), qnorm(q(obj:GetWorldOrientation())) end

-- Third person view of a vehicle (the camera toggle); false on foot.
local function tppOn()
    local on = false
    pcall(function()
        local defs = GetAllBlackboardDefs().UI_ActiveVehicleData
        on = Game.GetBlackboardSystem():Get(defs):GetBool(defs.IsTPPCameraOn) == true
    end)
    return on
end

-- Teleport follow: the device root is held at offPos / offRot relative to the anchor.
local function bindAnchor(camPos, camRot)
    local obj, kind, key = anchorObject()
    local p, r = objPose(obj)
    local inv = qconj(r)
    s.anchor, s.anchorKind, s.anchorKey = obj, kind, key
    s.offPos = qrot(inv, { x = camPos.x - p.x, y = camPos.y - p.y, z = camPos.z - p.z })
    s.offRot = qmul(inv, camRot)
end

local function targetPose()
    local p, r = objPose(s.anchor)
    local o = qrot(r, s.offPos)
    return { x = p.x + o.x, y = p.y + o.y, z = p.z + o.z }, qnorm(qmul(r, s.offRot))
end

local function toVec4(p) return Vector4.new(p.x, p.y, p.z, 1.0) end
local function toQuat(r) return Quaternion.new(r.i, r.j, r.k, r.r) end

local function follow()
    if not s.ent or not s.anchor then return end
    s.anchor = anchorObject()
    local p, r = targetPose()
    local last = s.last
    if last and math.abs(p.x - last.x) < 0.0005 and math.abs(p.y - last.y) < 0.0005 and math.abs(p.z - last.z) < 0.0005
        and math.abs(r.i - last.i) + math.abs(r.j - last.j) + math.abs(r.k - last.k) + math.abs(r.r - last.r) < 0.0002 then
        return
    end
    Game.GetTeleportationFacility():Teleport(s.ent, toVec4(p), toQuat(r):ToEulerAngles())
    s.last = { x = p.x, y = p.y, z = p.z, i = r.i, j = r.j, k = r.k, r = r.r }
end

local function followText()
    if s.mode == 'bound' then return 'bound to V (' .. tostring(s.bindVia) .. ')' end
    return 'teleport, anchor ' .. tostring(s.anchorKind or '?')
end

-- The device camera sits at s.tc inside the device (nil = the entity origin, as built); the screen keeps its
-- place in front of that camera.
local function applyGeometry()
    local ent = s.ent
    if not ent then return end
    local cam = ent:FindComponentByName('cameraZoomComponent')
    local mesh = ent:FindComponentByName('computer')
    s.fov = s.fov > 0 and s.fov or fovNow()
    s.dist, s.camFov = screenGeometry(s.fov)
    if cam then cam:SetFOV(s.camFov) else err('no cameraZoomComponent on the device') end
    pcall(function() s.ent:FindComponentByName('terminalui'):GetGameController():GetRootWidget():SetOpacity(cfg.opacity) end)
    if not mesh then err('no computer mesh on the device'); return end
    local rel = { x = CENTRE.x + cfg.offsetX, y = CENTRE.y + s.dist, z = CENTRE.z + cfg.offsetZ }
    local tc = s.tc
    if not tc and not s.tcUsed then -- never moved: exactly the 1.6.1 call
        mesh:SetLocalPosition(Vector4.new(rel.x, rel.y, rel.z, 1.0))
        return
    end
    tc = tc or IDENT
    s.tcUsed = true
    if not s.meshRot then
        s.meshRot = MESH_ROT
        pcall(function()
            local live = qnorm(q(mesh:GetLocalOrientation()))
            if qangle(live, MESH_ROT) < 2 then s.meshRot = live end
        end)
    end
    if cam then
        cam:SetLocalPosition(toVec4(tc.p))
        cam:SetLocalOrientation(toQuat(tc.r))
    end
    mesh:SetLocalPosition(toVec4(vadd(tc.p, qrot(tc.r, rel))))
    mesh:SetLocalOrientation(toQuat(qnorm(qmul(tc.r, s.meshRot))))
end

-- Opacity = ink root opacity of the device UI; the screen material (parallaxscreen_transparent_ui) uses its alpha.
local function applyOpacity()
    if not s.ent then return false end
    local ok = pcall(function()
        local root = s.ent:FindComponentByName('terminalui'):GetGameController():GetRootWidget()
        root:SetOpacity(cfg.opacity)
    end)
    return ok
end

local function deleteEntity()
    if s.id then pcall(function() Game.GetDynamicEntitySystem():DeleteEntity(s.id) end) end
    s.id, s.ent, s.anchor, s.last = nil, nil, nil, nil
end

local function setState(name, status)
    s.state, s.t = name, 0
    if status then s.status = status end
    log('-> ' .. name .. (status and (': ' .. status) or ''))
end

local function clearFollow()
    s.mode, s.bindTried, s.bindVia = 'teleport', false, nil
    s.tc, s.tcUsed, s.meshRot, s.r0, s.r0s, s.cal, s.rounds = nil, false, nil, nil, {}, nil, 0
    s.vel, s.prevA, s.wd, s.wdT, s.viewTpp, s.noTc = nil, nil, 0, 0, nil, false
end

local function reset(status)
    if s.ent and s.zoomSeen then log('Follow was ' .. followText()) end
    deleteEntity()
    clearFollow()
    s.zoomSeen, s.tries, s.settle, s.fov, s.camFov, s.dist = false, 0, 0, 0, 0, 0
    s.opacityT, s.opacityWarned = 0, false
    setState('idle', status or 'idle')
end

local function queueZoom(on)
    local ps = s.ent:GetDevicePS()
    local action = ps:ActionQuestForceCameraZoom(on, true)
    Game.GetPersistencySystem():QueuePSDeviceEvent(action)
end

-- Device still there but it won't let go: run its own exit (pops DeviceZoom, deactivates its camera, PSM flags).
-- Never delete the entity in the same frame; 1.0.0's Unstick deleted it while its camera was active = crash.
local function releaseCamera()
    local ent = s.ent
    if not ent then return end
    pcall(function() ent:RegisterPlayerInputListener(false) end)
    pcall(function() ent:GetDevicePS():SetAdvancedInteractionModeOn(false) end)
    pcall(function() ent:SetZoomBlackboardValues(false) end)
    pcall(function() ent:ToggleCameraZoom(false, true) end)
    pcall(function() Game.GetPlayer():GetFPPCameraComponent():Activate(0) end)
    log('Device camera released by its own exit')
end

-- Device gone but PSM still says V is zoomed into it: clear the flags; pop DeviceZoom only in that case.
local function recoverOrphan()
    local on = false
    pcall(function() on = zoomState() end)
    if not on then log('Nothing stuck'); return false end
    pcall(function()
        local bb, defs = psm()
        bb:SetBool(defs.IsUIZoomDevice, false)
        bb:SetBool(defs.IsInteractingWithDevice, false)
        bb:SetEntityID(defs.UIZoomDeviceID, EntityID.new())
    end)
    pcall(function() Game.GetPlayer():GetFPPCameraComponent():Activate(0) end)
    pcall(function() Game.GetUISystem():PopGameContext(Enum.new('UIGameContext', 3)) end) -- 3 = DeviceZoom
    log('Recovered orphaned zoom state')
    return true
end

-- Release first, delete PURGE_DELAY s later (state 'purge').
local function purge(status)
    releaseCamera()
    setState('purge', status or 'recovering')
end

function mod.unstick()
    if s.ent and (s.state == 'open' or s.state == 'opening') then return mod.close() end
    if s.ent and s.state == 'closing' then purge('unstuck'); return 'purging' end
    if s.state == 'spawning' then reset('cancelled'); return 'cancelled' end
    if s.state == 'idle' then return recoverOrphan() and 'recovered' or 'nothing stuck' end
    return s.state
end

---------------------------------------------------------------------------------- native follow (1.7.1)
-- The two engine calls: through netlink_bind.reds, or straight from CET when that file is not compiled in.
-- keepWorldTransform true = the device stays where it is and from then on moves with the component.
-- (false keeps its old world coordinates as an offset from the component: 1.7.0, device 3239 m away.)
local function nativeBind(child, target, comp)
    local ok, done = pcall(function() return CyberslopNetLinkBind(child, target, comp, true) end)
    if ok and done then return 'redscript' end
    ok = pcall(function()
        EntityGameInterface.BindToComponent(child:GetEntity(), target:GetEntity(), comp, 'None', true)
    end)
    return ok and 'CET' or nil
end

local function nativeUnbind(child)
    local ok, done = pcall(function() return CyberslopNetLinkUnbind(child) end)
    if ok and done then return true end
    return (pcall(function() EntityGameInterface.UnbindTransform(child:GetEntity()) end))
end

-- The anchor now: its pose, and its velocity in its own frame (s.vel). Second result true = V got in / out.
local function senseAnchor(dt)
    local obj, _, key = anchorObject()
    if s.anchorKey and key ~= s.anchorKey then return nil, true end
    local p, r = objPose(obj)
    local a = { p = p, r = r }
    if s.prevA and dt and dt > 0 then
        local step = vsub(p, s.prevA.p)
        if vlen(step) / dt < SPEED_CAP then
            local vel = qrot(qconj(r), vscale(step, 1 / dt))
            s.vel = s.vel and vadd(vscale(s.vel, 0.5), vscale(vel, 0.5)) or vel
        end
    end
    s.prevA = a
    return a, false
end

local function speedNow() return s.vel and vlen(s.vel) or 0 end

-- The view = pose of the camera that renders now, relative to the anchor. nil if the camera system gives none.
local function viewNow(a)
    local p, r, source = cameraPose()
    if source ~= 'active camera' then return nil end
    return prel(a, { p = p, r = r })
end

-- The device camera relative to the anchor, from its component transform (not what is rendered).
local function deviceSim(a)
    local cam = s.ent and s.ent:FindComponentByName('cameraZoomComponent')
    if not cam then return nil end
    local ok, p, r = pcall(compPose, cam)
    if not ok then return nil end
    return prel(a, { p = p, r = r })
end

local function newCal() return { skip = CAL_SKIP, list = {}, sims = {}, span = 0 } end

-- The binding does not hold: release it and hold the device at V's view by teleport, as 1.6.1 did.
local function toTeleport(why)
    pcall(nativeUnbind, s.ent)
    s.mode, s.tc, s.last = 'teleport', nil, nil
    if s.r0 then s.offPos, s.offRot = s.r0.p, s.r0.r end
    s.anchor = anchorObject()
    pcall(applyGeometry)
    log('Native follow off (' .. why .. '): ' .. followText())
    follow()
end

-- Before the zoom: put the device camera where V's view is, as far as the component transform shows it.
local function preAlign(a)
    if not s.r0 then return end
    local rs = deviceSim(a)
    if not rs then return end
    local vel = s.vel or IDENT.p
    local expect = { p = vadd(rs.p, vscale(vel, cfg.simBias)), r = rs.r } -- where it will render
    local tc = pmul(pinv(expect), s.r0)
    local gap = vlen(tc.p)
    if gap > PRE_MAX then
        log(string.format('Pre-alignment skipped: device %.1f m from the view', gap))
        return
    end
    s.tc = tc
    log(string.format('Pre-aligned: device was %.2f m / %.1f deg from the view', gap, qangle(tc.r, IDENT.r)))
end

-- After the zoom: measure the device camera's view the way V's own was measured and take the difference out.
local function lineUp(a, dt)
    local c = s.cal
    if c.skip > 0 then c.skip = c.skip - 1; return end
    local view = viewNow(a)
    if not view or not s.r0 then s.cal = nil; log('No line-up: no camera transform'); return end
    if #c.list > 0 then c.span = c.span + dt end
    c.list[#c.list + 1] = view
    local sim = deviceSim(a)
    if sim then c.sims[#c.sims + 1] = sim end
    if #c.list < CAL_N then return end

    local r1 = pmean(c.list)
    local spread = 0
    for _, e in ipairs(c.list) do spread = math.max(spread, dist3(e.p, r1.p)) end
    local speed = speedNow()
    local off, ang = dist3(r1.p, s.r0.p), qangle(r1.r, s.r0.r)
    local fine = off <= CAL_MIN_POS + CAL_MIN_PER_SPEED * speed and ang <= CAL_MIN_ANG
    s.rounds = s.rounds + 1

    if s.mode == 'bound' and speed > SLIP_SPEED and c.span > 0 then
        local slip = dist3(c.list[#c.list].p, c.list[1].p) / (speed * c.span)
        if slip > SLIP_MAX then
            toTeleport(string.format('device does not ride with V: %.0f %% slip at %.0f m/s', slip * 100, speed))
            s.rounds = 0
            s.cal = newCal()
            return
        end
    end
    if off > CAL_MAX then
        if s.mode == 'bound' then
            toTeleport(string.format('view %.1f m off', off))
            s.cal = newCal()
        else -- teleports do not reach the device either: give the camera back
            s.cal = nil
            err(string.format('view %.1f m off V\'s own: closing', off))
            onScreen('NetLink: no signal')
            mod.close()
        end
        return
    end

    -- the gap between the component transform and the rendered view, per m/s: used by the next pre-alignment
    if speed > 5 and #c.sims == #c.list and c.first ~= false then
        local gap = vdot(vsub(r1.p, pmean(c.sims).p), s.vel) / (speed * speed)
        gap = math.max(-BIAS_MAX, math.min(BIAS_MAX, gap))
        local old = cfg.simBias
        cfg.simBias = cfg.simBiasN > 0 and (old * 0.7 + gap * 0.3) or gap
        cfg.simBiasN = math.min(cfg.simBiasN + 1, 1000)
        if math.abs(cfg.simBias - old) > 0.002 then pcall(saveConfig) end
    end

    if c.before then -- this was the check after a correction
        local moved = dist3(r1.p, c.before.p) + 0.02 * qangle(r1.r, c.before.r)
        if c.wanted > 0.15 and moved < 0.25 * c.wanted and off > 0.5 * c.wanted then
            -- the camera did not go where it was put: its local transform is ignored. Undo; from here the
            -- device root is moved instead, which only the teleport follow can do.
            s.tc = c.tcBefore
            pcall(applyGeometry)
            err('device camera ignores its local transform, correcting through the teleport offset')
            s.noTc = true
            if s.mode == 'bound' then toTeleport('camera local transform ignored') end
            s.rounds = 0
            s.cal = newCal()
            return
        end
    end

    if not fine and s.rounds <= CAL_ROUNDS and s.noTc then
        if s.mode ~= 'bound' and s.offPos then
            local root = pmul(pmul(s.r0, pinv(r1)), { p = s.offPos, r = s.offRot }) -- in the anchor frame
            s.offPos, s.offRot, s.last = root.p, root.r, nil
            log(string.format('View lined up through the teleport offset: it was %.3f m / %.1f deg off V\'s own (%.1f m/s)',
                off, ang, speed))
            s.cal = newCal()
        else
            s.cal = nil
        end
    elseif not fine and s.rounds <= CAL_ROUNDS then
        local before = s.tc
        s.tc = pmul(s.tc or IDENT, pmul(pinv(r1), s.r0))
        applyGeometry()
        log(string.format('View lined up: it was %.3f m / %.1f deg off V\'s own (%s, %.1f m/s, spread %.3f m)',
            off, ang, followText(), speed, spread))
        s.cal = newCal()
        s.cal.before, s.cal.tcBefore, s.cal.wanted, s.cal.first = r1, before, off + 0.02 * ang, false
    else
        log(string.format('View holds: %.3f m / %.1f deg off V\'s own (%s, %.1f m/s, spread %.3f m)',
            off, ang, followText(), speed, spread))
        s.cal = nil
    end
end

------------------------------------------------------------------------------------------------- gates
-- 1.7.0: the autodrive cinematic camera (hold the camera key in autodrive) is not V's view
local function cinematicCamera()
    local ok, on = pcall(function()
        local defs = GetAllBlackboardDefs().UI_AutodriveData
        return Game.GetBlackboardSystem():Get(defs):GetBool(defs.CinematicCameraActive)
    end)
    return ok and on == true
end

local function refusal()
    local player = Game.GetPlayer()
    if not player or not IsDefined(player) then return 'no player' end
    local bb, defs = psm()
    local tier = bb:GetInt(defs.SceneTier)
    if tier >= 4 then return 'cinematic scene' end
    if bb:GetBool(defs.IsControllingDevice) then return 'controlling a device' end
    local okBd, bd = pcall(function()
        local bdDefs = GetAllBlackboardDefs().Braindance
        return Game.GetBlackboardSystem():Get(bdDefs):GetBool(bdDefs.IsActive)
    end)
    if okBd and bd then return 'braindance' end
    if player:IsDead() then return 'dead' end
    if cinematicCamera() then return 'autodrive cinematic camera' end
    local on = zoomState()
    if on then return 'already using a device' end
    return nil
end

------------------------------------------------------------------------------------------------- open/close
function mod.open()
    if s.state ~= 'idle' then return 'busy' end
    local why = refusal()
    if why then
        log('Refused: ' .. why)
        onScreen('NetLink unavailable: ' .. why)
        return 'refused: ' .. why
    end
    local camPos, camRot, source = cameraPose()
    clearFollow()
    bindAnchor(camPos, camRot)
    s.viewTpp = tppOn()
    s.fov = fovNow()
    local spec = DynamicEntitySpec.new()
    spec.templatePath = TEMPLATE
    spec.position = toVec4(camPos)
    spec.orientation = toQuat(camRot)
    spec.persistState = false
    spec.persistSpawn = false
    spec.alwaysSpawned = true
    spec.spawnInView = true
    spec.active = true
    spec.tags = { TAG }
    s.id = Game.GetDynamicEntitySystem():CreateEntity(spec)
    s.zoomSeen, s.tries, s.settle = false, 0, 0
    setState('spawning', 'linking')
    log(string.format('Open from %s, anchor %s, FOV %.1f', source, s.anchorKind, s.fov))
    return 'opening'
end

function mod.close()
    if s.state == 'spawning' then -- no zoom requested yet
        reset('cancelled')
        return 'cancelled'
    end
    if s.state == 'opening' then -- a zoom request may still land: queue the off after it, then wait
        pcall(queueZoom, false)
        setState('closing', 'cancelled')
        return 'cancelled'
    end
    if s.state ~= 'open' then return 'not open' end
    local ok, e = pcall(queueZoom, false)
    if not ok then err('close: ' .. tostring(e)) end
    sound(SND_CLOSE)
    setState('closing', 'closing')
    return 'closing'
end

function mod.toggle()
    if s.state == 'idle' then return mod.open() end
    return mod.close()
end

------------------------------------------------------------------------------------------------- update
local function step(dt)
    s.t = s.t + dt
    local st = s.state
    if st == 'idle' then return end

    local player = Game.GetPlayer()
    if not player or not IsDefined(player) then reset('no player'); return end

    if st == 'purge' then -- camera released last frame(s); delete only now
        if s.t >= PURGE_DELAY then
            local on, dev = zoomState()
            local stuck = on and dev == idHash(s.id)
            reset('idle')
            if stuck then recoverOrphan() end
        end
        return
    end

    if st == 'spawning' then
        local a, changed = senseAnchor(dt)
        if changed then
            log('V got in / out of a vehicle: cancelled')
            reset('cancelled')
            return
        end
        local view = viewNow(a) -- V's own view while the device camera is still off
        if view then
            s.r0s[#s.r0s + 1] = view
            if #s.r0s > PRE_N then table.remove(s.r0s, 1) end
        end
        local des = Game.GetDynamicEntitySystem()
        if des:IsSpawned(s.id) then
            s.ent = s.ent or des:GetEntity(s.id)
            if s.ent and not s.bindTried then -- bound before any teleport: none can land on a bound device
                s.bindTried = true
                local okB, via = pcall(nativeBind, s.ent, player, BIND_COMP)
                if okB and via then s.mode, s.bindVia = 'bound', via end
                log('Follow: ' .. followText())
            end
            if s.mode ~= 'bound' then follow() end
            local okPs, ps = pcall(function() return s.ent:GetDevicePS() end)
            if okPs and ps then
                s.settle = s.settle + dt
                if s.settle >= SETTLE_TIME then
                    s.r0 = pmean(s.r0s)
                    if s.r0 then
                        log(string.format('V\'s view: (%.2f, %.2f, %.2f) m from the %s, %.1f m/s',
                            s.r0.p.x, s.r0.p.y, s.r0.p.z, s.anchorKind, speedNow()))
                        pcall(function() -- diagnosis only: is the FPP camera component the rendered camera?
                            local fp, fr = compPose(player:GetFPPCameraComponent())
                            local cp, cr = cameraPose()
                            log(string.format('Diag: FPP camera component %.3f m / %.1f deg from the rendered camera',
                                dist3(fp, cp), qangle(fr, cr)))
                        end)
                        if s.mode == 'bound' then pcall(preAlign, a) end
                    end
                    applyGeometry()
                    queueZoom(true)
                    s.tries = 1
                    setState('opening', 'focusing')
                end
            end
        end
        if s.state == 'spawning' and s.t > SPAWN_TIMEOUT then
            err('device did not spawn in ' .. SPAWN_TIMEOUT .. ' s (archive installed? Codeware?)')
            onScreen('NetLink: no signal')
            reset('spawn failed')
        end
        return
    end

    if s.mode ~= 'bound' then follow() end
    local on, dev = zoomState()
    local mine = on and dev == idHash(s.id)

    if st == 'opening' then
        senseAnchor(dt)
        if mine then
            s.zoomSeen = true
            s.opacityT = OPACITY_REFRESH
            sound(SND_OPEN)
            if s.r0 then s.cal = newCal() end
            local fovText = string.format('FOV %.0f', s.camFov)
            if s.camFov < s.fov - 0.05 then fovText = string.format('FOV %.0f narrowed from %.0f', s.camFov, s.fov) end
            setState('open', string.format('open (%s, screen %.2f m, %s)', fovText, s.dist, followText()))
        elseif s.t > ZOOM_TIMEOUT then
            if s.tries < ZOOM_RETRIES then
                s.tries = s.tries + 1
                s.t = 0
                log('Zoom not active yet, asking again')
                queueZoom(true)
            else
                err('device camera never became active')
                onScreen('NetLink: no signal')
                reset('zoom failed')
            end
        end
        return
    end

    if st == 'open' then
        if not mine then -- vanilla UI_Exit (or something else took the camera)
            sound(SND_CLOSE)
            setState('closing', 'closing')
            return
        end
        s.opacityT = (s.opacityT or 0) + dt
        if s.opacityT >= OPACITY_REFRESH then -- the UI may (re)build its root; keep the opacity on it
            s.opacityT = 0
            if not applyOpacity() and not s.opacityWarned then
                s.opacityWarned = true
                err('could not reach the device UI root for opacity')
            end
        end
        local bb, defs = psm()
        if bb:GetInt(defs.SceneTier) >= 4 or player:IsDead() then
            log('Cinematic scene / death: closing')
            mod.close()
            return
        elseif cinematicCamera() then
            log('Autodrive cinematic camera: closing')
            mod.close()
            return
        end

        if s.cal then -- line-up running: every frame
            local a, changed = senseAnchor(dt)
            if changed then
                log('V got in / out of a vehicle: closing')
                mod.close()
                return
            end
            lineUp(a, dt)
            return
        end
        s.wdT = s.wdT + dt
        if s.wdT < WD_EVERY then return end
        local a, changed = senseAnchor(s.wdT)
        s.wdT = 0
        if changed then
            log('V got in / out of a vehicle: closing')
            mod.close()
            return
        end
        if s.viewTpp ~= nil and tppOn() ~= s.viewTpp then
            log('Camera toggled: closing')
            mod.close()
            return
        end
        if s.r0 then -- the view still sits where V's own was
            local view = viewNow(a)
            if view and dist3(view.p, s.r0.p) > WD_SLACK + WD_PER_SPEED * speedNow() then s.wd = s.wd + 1 else s.wd = 0 end
            if s.wd >= WD_COUNT then
                s.wd = 0
                local d = dist3(view.p, s.r0.p)
                if s.mode == 'bound' then toTeleport(string.format('view drifted %.2f m', d)) else log(string.format('View drifted %.2f m', d)) end
                s.rounds = 0
                s.prevA = nil
                s.cal = newCal()
            end
        end
        return
    end

    if st == 'closing' then
        if not mine then
            if s.t >= LINGER then reset('idle') end
        elseif s.t > CLOSE_TIMEOUT then
            err('device kept the camera, recovering')
            purge('recovering')
        end
    end
end

------------------------------------------------------------------------------------------------- UI
local syncDim -- 1.6.1: declared before drawWindow, which calls it (was an undefined global there)
local function drawWindow()
    if not ImGui.Begin('Kiroshi NetLink') then ImGui.End(); return end
    ImGui.Text('Status: ' .. s.status)
    if s.state ~= 'idle' and s.bindTried then ImGui.Text('Follow: ' .. followText()) end
    if s.state == 'idle' then
        if ImGui.Button('Open NetLink') then mod.open() end
    else
        if ImGui.Button('Close NetLink') then mod.close() end
    end
    ImGui.SameLine()
    ImGui.TextDisabled('hotkey: CET Bindings > "Open / close Kiroshi NetLink"')

    local changed = false
    local val, used = ImGui.SliderFloat('Panel width (share of view)', cfg.size, SIZE_MIN, SIZE_MAX, '%.2f')
    if used then cfg.size = val; changed = true end
    val, used = ImGui.SliderFloat('Opacity', cfg.opacity, OPACITY_MIN, 1.0, '%.2f')
    if used then cfg.opacity = val; changed = true end
    val, used = ImGui.SliderFloat('Centre left / right (m)', cfg.offsetX, -0.10, 0.10, '%.3f')
    if used then cfg.offsetX = val; changed = true end
    val, used = ImGui.SliderFloat('Centre down / up (m)', cfg.offsetZ, -0.10, 0.10, '%.3f')
    if used then cfg.offsetZ = val; changed = true end
    cfg.sounds, used = ImGui.Checkbox('Optics sounds', cfg.sounds)
    if used then changed = true end
    cfg.log, used = ImGui.Checkbox('Event log (CET console)', cfg.log)
    if used then changed = true end
    if changed then
        saveConfig()
        if s.state == 'open' then pcall(applyGeometry); applyOpacity() end
    end

    ImGui.Separator()
    local dimChanged = false
    cfg.dim, used = ImGui.Checkbox('Darken screen', cfg.dim)
    if used then dimChanged = true end
    ImGui.SameLine()
    ImGui.TextDisabled('(whole picture, also when the feed is closed)')
    local pct
    pct, used = ImGui.SliderFloat('Darkness (%)', cfg.dimAmount * 100, 0, DIM_MAX * 100, '%.0f')
    if used then cfg.dimAmount = pct / 100; dimChanged = true end
    if dimChanged then saveConfig(); pcall(syncDim, true) end
    ImGui.Separator()

    if ImGui.Button('Unstick camera / UI') then
        local ok, e = pcall(mod.unstick)
        if not ok then err('unstick: ' .. tostring(e)) end
    end
    ImGui.End()
end

---------------------------------------------------------------------------------------------- dimmer
local function dimSystem()
    local ok, sys = pcall(function() return Game.GetScriptableSystemsContainer():Get('DVGradeProbe.DVGP_State') end)
    if ok and sys then return sys end
    return nil
end

-- Push cfg.dim / cfg.dimAmount to the redscript layer. force = push even if it already matches.
function syncDim(force)
    local sys = dimSystem()
    if not sys then
        if force and not dimWarned then
            dimWarned = true
            err('dimmer: DVGradeProbe.DVGP_State not found (netlink_dim.reds or DigitalVixenCore missing)')
        end
        return false
    end
    local amount = math.max(0, math.min(DIM_MAX, cfg.dimAmount))
    if force or sys:IsOn() ~= cfg.dim or math.abs(sys:Darkness() - amount) > 0.001 then
        sys:Set(cfg.dim, amount)
    end
    return true
end

function mod.toggleDim()
    cfg.dim = not cfg.dim
    saveConfig()
    syncDim(true)
    log('dimmer ' .. (cfg.dim and 'on' or 'off') .. ' (' .. math.floor(cfg.dimAmount * 100 + 0.5) .. ' %)')
end

------------------------------------------------------------------------------------------------- events
registerHotkey('netlink', 'Open / close Kiroshi NetLink', function()
    local ok, e = pcall(mod.toggle)
    if not ok then err('hotkey: ' .. tostring(e)); pcall(reset, 'error') end
end)

registerHotkey('netlink_dim', 'Darken screen on / off', function()
    local ok, e = pcall(mod.toggleDim)
    if not ok then err('dim hotkey: ' .. tostring(e)) end
end)

registerForEvent('onInit', function()
    loadConfig()
    -- 1.6.1: not at once: after "Reload all mods" the old instance's device may still be blending its camera out
    bootPurge = PURGE_DELAY
    -- A new session (load / new game): the old entity and UI contexts are gone with it.
    ObserveAfter('PlayerPuppet', 'OnGameAttached', function()
        s.id, s.ent, s.anchor, s.last = nil, nil, nil, nil
        s.state, s.t, s.status, s.zoomSeen = 'idle', 0, 'idle', false
        clearFollow()
    end)
    print('[KiroshiNetLink] Ready v' .. VERSION)
end)

registerForEvent('onUpdate', function(dt)
    dimT = dimT + dt
    if dimT >= DIM_SYNC then
        dimT = 0
        if cfg.dim then pcall(syncDim, false) end -- off needs no sync: a fresh system is neutral
    end
    if bootPurge then
        bootPurge = bootPurge - dt
        if bootPurge <= 0 then
            bootPurge = nil
            pcall(function() Game.GetDynamicEntitySystem():DeleteTagged(TAG) end)
        end
    end
    if s.state == 'idle' then return end
    local ok, e = pcall(step, dt)
    if not ok then
        err('update: ' .. tostring(e))
        if s.zoomSeen and s.ent and s.state ~= 'purge' then
            pcall(purge, 'error (see console)') -- release the camera first, delete next frames
        else
            pcall(reset, 'error (see console)')
            s.state, s.t, s.status, s.zoomSeen = 'idle', 0, 'error (see console)', false
        end
    end
end)

registerForEvent('onOverlayOpen', function() overlay = true end)
registerForEvent('onOverlayClose', function() overlay = false end)
registerForEvent('onDraw', function() if overlay then drawWindow() end end)

registerForEvent('onShutdown', function()
    if s.state ~= 'idle' then
        -- 1.6.1: never delete a device whose camera is active (crash class of 1.0.0); release it and let the
        -- next instance's bootPurge delete it PURGE_DELAY s later
        if s.ent and s.zoomSeen then
            pcall(releaseCamera)
        else
            deleteEntity()
        end
    end
end)

mod._state = s
mod._step = step
mod._cfg = cfg
return mod
