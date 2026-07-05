local function GetDroneBasis(ent)
  -- Returns forward and right vectors without relying on GetEntityRightVector/GetEntityMatrix.
  local pos = GetEntityCoords(ent)
  local fwdPos = GetOffsetFromEntityInWorldCoords(ent, 0.0, 1.0, 0.0)
  local rgtPos = GetOffsetFromEntityInWorldCoords(ent, 1.0, 0.0, 0.0)
  local forward = fwdPos - pos
  local right = rgtPos - pos
  return forward, right
end


local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function wrapDeg(a)
  a = (a + 180.0) % 360.0 - 180.0
  return a
end

local function vecFromHeadingDeg(h)
  local rad = math.rad(h)
  return vec3(-math.sin(rad), math.cos(rad), 0.0)
end

local function rightFromHeadingDeg(h)
  local rad = math.rad(h)
  return vec3(math.cos(rad), math.sin(rad), 0.0)
end



local function expSmooth(current, target, k, dt)
  -- k: responsiveness (higher snaps faster). Exponential smoothing for FPS-independent feel.
  local t = 1.0 - math.exp(-k * dt)
  return current + (target - current) * t
end



local state = {
  placedMode = false,
  placedGhost = 0,
  usingPlaced = false,
  placedNetId = 0,
  lastTrackerId = nil,
  routeOn = false,
  lastTrackerPos = nil,
  lastTrackerAt = 0,
  trackerViz = { untilTs = 0, from = nil, to = nil, hit = false },
  trackerCrosshair = true,
  active = false,
  drone = 0,
  droneNet = 0,
  cam = -1,
  startPos = nil,
  battery = 0,
  batteryMax = 0,
  rangeOverAt = 0,

  spotlight = false,
  thermal = false,
  fov = 60.0,

  speed = 0.0,
  vel = vec3(0,0,0),

  -- flight tuning
  targetVel = vec3(0.0, 0.0, 0.0),
  moveSmooth = 4.0,   -- higher = snappier
  yawRate = 75.0,      -- degrees per second
  lookYaw = 0.0,
  lookPitch = 0.0,
  camYaw = 0.0,
  camPitch = 0.0,
  camLerp = 5.5,       -- camera smoothing
  yawLerp = 4.0,       -- drone yaw smoothing
}


local operatorLock = { active = false, animDict = (Config.OperatorAnim and Config.OperatorAnim.dict) or 'amb@world_human_stand_mobile@male@text@base', animName = (Config.OperatorAnim and Config.OperatorAnim.name) or 'base' }

local function setOperatorLock(enable)
  local ped = PlayerPedId()
  if enable and not operatorLock.active then
    operatorLock.active = true
    FreezeEntityPosition(ped, true)

    RequestAnimDict(operatorLock.animDict)
    while not HasAnimDictLoaded(operatorLock.animDict) do Wait(0) end
    TaskPlayAnim(ped, operatorLock.animDict, operatorLock.animName, 2.0, 2.0, -1, 49, 0, false, false, false)

    CreateThread(function()
      while operatorLock.active do
        -- re-apply operator anim if it gets interrupted
        if Config.OperatorAnim and Config.OperatorAnim.enabled ~= false then
          if not IsEntityPlayingAnim(ped, operatorLock.animDict, operatorLock.animName, 3) then
            TaskPlayAnim(ped, operatorLock.animDict, operatorLock.animName, 2.0, 2.0, -1, 49, 0, false, false, false)
          end
        end

        -- hard block movement + combat while in drone
        DisableControlAction(0, 30, true) -- move L/R
        DisableControlAction(0, 31, true) -- move F/B
        DisableControlAction(0, 32, true)
        DisableControlAction(0, 33, true)
        DisableControlAction(0, 34, true)
        DisableControlAction(0, 35, true)
        DisableControlAction(0, 22, true) -- jump
        DisableControlAction(0, 24, true) -- attack
        DisableControlAction(0, 25, true) -- aim
        DisableControlAction(0, 37, true) -- weapon wheel
        DisableControlAction(0, 44, true) -- cover
        DisableControlAction(0, 140, true)
        DisableControlAction(0, 141, true)
        DisableControlAction(0, 142, true)
        DisableControlAction(0, 143, true)
        Wait(0)
      end
    end)
  elseif not enable and operatorLock.active then
    operatorLock.active = false
    ClearPedTasks(ped)
    FreezeEntityPosition(ped, false)
  end
end

-- Boot overlay is rendered by the NUI ('boot' message) instead of native
-- DrawRect/DrawText — gives us the cinematic scan/glitch styling without
-- hand-rolling text positioning in Lua.
local function runBootSequence()
  if not Config.Boot or not Config.Boot.enabled then return true end

  local seconds = tonumber(Config.Boot.seconds or 2.0) or 2.0
  if seconds <= 0.0 then return true end

  local drone = state and state.drone
  if drone and DoesEntityExist(drone) then
    FreezeEntityPosition(drone, true)
  end

  -- rotor idle sound
  PlaySoundFrontend(-1, 'NAV_UP_DOWN', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)

  if Config.UI.enabled then
    SendNUIMessage({ type = 'boot', show = true, seconds = seconds, theme = Config.UI.theme })
  end

  local started = GetGameTimer()
  local duration = math.floor(seconds * 1000)

  while (GetGameTimer() - started) < duration do
    DisableAllControlActions(0)
    Wait(0)
  end

  if Config.UI.enabled then
    SendNUIMessage({ type = 'boot', show = false })
  end

  -- slight lift effect
  if drone and DoesEntityExist(drone) then
    FreezeEntityPosition(drone, false)
    local coords = GetEntityCoords(drone)
    SetEntityCoords(drone, coords.x, coords.y, coords.z + 0.6)
  end

  PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
  return true
end



-- Minimap follows drone while active
local droneMapBlip = nil
local minimapLocked = false

-- Declared here (not at first use below) so the radar computation inside
-- the flight thread — defined earlier in the file than the trackerPing
-- handler — can see it as an upvalue.
local trackerBlips = {} -- [trackerId] = blip

-- Heading-up mini-radar: projects each active tracker blip into the
-- drone's forward/right frame (same vecFromHeadingDeg/rightFromHeadingDeg
-- used for flight) so the NUI side only has to place a dot, no trig.
local function sendRadarUpdate()
  if not Config.UI.enabled or not Config.UI.showRadar then return end
  if not state.drone or state.drone == 0 or not DoesEntityExist(state.drone) then return end

  local dpos = GetEntityCoords(state.drone)
  local heading = GetEntityHeading(state.drone)
  local fwd = vecFromHeadingDeg(heading)
  local rgt = rightFromHeadingDeg(heading)
  local range = tonumber(Config.UI.radarRange) or 300.0

  local blips = {}
  for _, blip in pairs(trackerBlips) do
    if blip and DoesBlipExist(blip) then
      local bpos = GetBlipCoords(blip)
      local dx = bpos.x - dpos.x
      local dy = bpos.y - dpos.y

      local rx = dx * rgt.x + dy * rgt.y
      local ry = dx * fwd.x + dy * fwd.y

      local dist = math.sqrt(rx * rx + ry * ry)
      if dist > range and dist > 0.001 then
        local s = range / dist
        rx = rx * s
        ry = ry * s
      end

      blips[#blips + 1] = { x = rx / range, y = ry / range }
    end
  end

  SendNUIMessage({ type = 'radar', blips = blips })
end

local function MinimapLockToDrone(enable)
  if enable then
    minimapLocked = true
  else
    minimapLocked = false
    UnlockMinimapPosition()
    UnlockMinimapAngle()
  end
end

RegisterNetEvent('cipher-drone:client:useItem', function()
  TriggerServerEvent('cipher-drone:server:useDroneItem')
end)

-- ox_inventory hook point for QBox, since qbx_core has no server-side
-- useable-item registration API. Point the jammer item's ox_inventory
-- `client.event` at this.
RegisterNetEvent('cipher-drone:client:useJammerItem', function()
  TriggerServerEvent('cipher-drone:server:useJammerItem')
end)

local function nui(show)
  if not Config.UI.enabled then return end
  SetNuiFocus(false, false)
  SendNUIMessage({
    type = 'toggle',
    state = show and true or false,
    theme = Config.UI.theme,
    showHints = Config.UI.showHints,
    canBeShotDown = Config.Drone.canBeShotDown and true or false,
    showCompass = Config.UI.showCompass and true or false,
    showRadar = Config.UI.showRadar and true or false,
  })
end

local function nuiUpdate()
  if not Config.UI.enabled then return end
  local ped = PlayerPedId()
  local ppos = GetEntityCoords(ped)
  local dpos = GetEntityCoords(state.drone)
  local dist = #(ppos - dpos)

  local health = nil
  if Config.Drone.canBeShotDown and state.droneMaxHealth then
    health = math.floor(math.max(0, math.min(100, (GetEntityHealth(state.drone) / state.droneMaxHealth) * 100)))
  end

  SendNUIMessage({
    type = 'update',
    battery = math.floor((state.battery / state.batteryMax) * 100),
    signal = math.floor(math.max(0.0, 100.0 - (dist / Config.Drone.maxRange) * 100.0)),
    health = health,
    heading = GetEntityHeading(state.drone),
    spotlight = state.spotlight,
    thermal = state.thermal,
    trackerCd = 0, -- updated by server message when used
  })
end



local function TrackerVisual(fromCoord, toCoord, hit)
  state.trackerViz = state.trackerViz or { untilTs = 0 }
  state.trackerViz.from = fromCoord
  state.trackerViz.to = toCoord
  state.trackerViz.hit = hit and true or false
  state.trackerViz.untilTs = GetGameTimer() + 250 -- quick flash, not a long line
end
local function PlayPtfx(dict, name, x, y, z, scale)
  if not dict or not name then return end
  if not HasNamedPtfxAssetLoaded(dict) then
    RequestNamedPtfxAsset(dict)
    local t = GetGameTimer() + 750
    while not HasNamedPtfxAssetLoaded(dict) and GetGameTimer() < t do
      Wait(0)
    end
  end
  if not HasNamedPtfxAssetLoaded(dict) then return end
  UseParticleFxAssetNextCall(dict)
  StartParticleFxNonLoopedAtCoord(name, x, y, z, 0.0, 0.0, 0.0, scale or 1.0, false, false, false)
end

-- Shoot-down destroy sequence: freeze further damage, let the object fall
-- naturally (collision + unfrozen position already does this), keep
-- re-triggering the one-shot smoke/spark ptfx for the fall duration, then
-- let the caller clean up and end the session.
local function runDestroySequence(obj)
  if not obj or obj == 0 or not DoesEntityExist(obj) then return end

  SetEntityInvincible(obj, true)

  SendNUIMessage({ type = 'destroyed' })
  PlaySoundFrontend(-1, 'Bed', 'WastedSounds', true)

  local seconds = tonumber(Config.Drone.destroyedFallSeconds) or 2.5
  local started = GetGameTimer()
  local duration = math.floor(seconds * 1000)
  local nextFx = 0

  while (GetGameTimer() - started) < duration do
    if DoesEntityExist(obj) then
      if GetGameTimer() >= nextFx then
        nextFx = GetGameTimer() + 400
        local p = GetEntityCoords(obj)
        if Config.Drone.destroyedSmokeFx then
          PlayPtfx(Config.Drone.destroyedSmokeAsset, Config.Drone.destroyedSmokeName, p.x, p.y, p.z, 1.2)
        end
        if Config.Drone.destroyedSparksFx then
          PlayPtfx(Config.Drone.destroyedSparksAsset, Config.Drone.destroyedSparksName, p.x, p.y, p.z, 0.8)
        end
      end
    end
    Wait(0)
  end
end

local function VisualReset()
  -- Hard reset any visual modifiers (timecycle / thermal / postfx) in case something got stuck
  SetSeethrough(false)
  SetNightvision(false)
  ClearTimecycleModifier()
  ClearExtraTimecycleModifier()
  SetTimecycleModifierStrength(0.0)
  SetExtraTimecycleModifier('')
  SetTimecycleModifier('')
  AnimpostfxStopAll()
end

local function cleanup(reason)
  if state.cam and state.cam ~= -1 then
    RenderScriptCams(false, true, 250, true, true)
    DestroyCam(state.cam, false)
    state.cam = -1
  end

  if state.thermal then
    SetSeethrough(false)
    state.thermal = false
  end

  -- clear visual modifiers
  VisualReset()

  MinimapLockToDrone(false)
  if droneMapBlip and DoesBlipExist(droneMapBlip) then RemoveBlip(droneMapBlip) droneMapBlip = nil end
  if Config.Camera.enableNightVision then
    SetNightvision(false)
  end

  if state.drone and state.drone ~= 0 and DoesEntityExist(state.drone) then
    if not state.usingPlaced then DeleteEntity(state.drone) end
  end

  state.active = false
  setOperatorLock(false)
  state.drone = 0
  state.droneNet = 0
  state.startPos = nil
  state.rangeOverAt = 0

  nui(false)
  ClearFocus()
  ClearPedTasks(PlayerPedId())

  -- restore control feel
  SetPlayerControl(PlayerId(), true, 0)

  if reason == 'destroyed' then
    Framework.Notify('Drone destroyed.', 'error')
  elseif reason then
    -- local notify best-effort
    Framework.Notify(('Drone ended: %s'):format(reason), 'inform')
  end

  state.droneMaxHealth = nil
  state.lastHealth = nil
  state.jammed = false
end

RegisterNetEvent('cipher-drone:client:start', function(data)
  if state.active then return end

  state.batteryMax = Config.Drone.batterySeconds
  state.battery = tonumber(data and data.battery) or state.batteryMax
  state.fov = math.max(Config.Camera.fovMin, math.min(Config.Camera.fovMax, 60.0))

  local ped = PlayerPedId()
  local pcoords = GetEntityCoords(ped)
  state.startPos = pcoords

  local spawn = pcoords + GetEntityForwardVector(ped) * Config.Drone.spawnOffset.x + vec3(0.0, 0.0, Config.Drone.spawnOffset.z)

  RequestModel(Config.Drone.model)
  while not HasModelLoaded(Config.Drone.model) do Wait(0) end

  local obj = 0
  if data and data.netId then
    obj = NetToObj(data.netId)
    state.usingPlaced = true
    state.placedNetId = data.netId
  end
  if obj == 0 then
    state.usingPlaced = false
    state.placedNetId = 0
    obj = CreateObject(Config.Drone.model, spawn.x, spawn.y, spawn.z + 0.5, true, true, true)
    SetEntityHeading(obj, GetEntityHeading(ped))
    SetEntityAsMissionEntity(obj, true, true)
  end

  if Config.Drone.canBeShotDown then
    -- Placed drones are set invincible at placement time (see placeMode
    -- below) before we know whether this session even allows shoot-down;
    -- clear it here so a placed-then-connected drone can still be shot down.
    SetEntityInvincible(obj, false)
    local base = tonumber(Config.Drone.baseHealth) or 200
    local mult = math.max(1.0, tonumber(Config.Drone.damageMultiplier) or 1.0)
    local effective = math.max(1, math.floor(base / mult))
    SetEntityMaxHealth(obj, base)
    SetEntityHealth(obj, effective)
    state.droneMaxHealth = effective -- the entity's actual starting HP, used as the 100% baseline for the UI
  else
    SetEntityInvincible(obj, Config.Drone.invincibleIfDisabled)
    state.droneMaxHealth = nil
  end
  state.lastHealth = Config.Drone.canBeShotDown and GetEntityHealth(obj) or nil
  state.jammed = false

  FreezeEntityPosition(obj, false)
  SetEntityCollision(obj, true, true)

  state.drone = obj
  if droneMapBlip and DoesBlipExist(droneMapBlip) then RemoveBlip(droneMapBlip) end
  droneMapBlip = AddBlipForEntity(obj)
  SetBlipSprite(droneMapBlip, 43) -- plane icon-ish
  SetBlipScale(droneMapBlip, 0.85)
  SetBlipColour(droneMapBlip, 3)
  BeginTextCommandSetBlipName('STRING')
  AddTextComponentString('Drone')
  EndTextCommandSetBlipName(droneMapBlip)
  state.droneNet = ObjToNet(obj)
  if not state.usingPlaced then
    NetworkRegisterEntityAsNetworked(obj)
    SetNetworkIdExistsOnAllMachines(state.droneNet, true)
    TriggerServerEvent('cipher-drone:server:registerDrone', state.droneNet)
  end

  -- control mode (main HUD panel reveals after boot, not before)
  SetPlayerControl(PlayerId(), false, 0) -- keep player still and out of control
  setOperatorLock(true)

  -- boot sequence (grounded) BEFORE camera
  if not runBootSequence() then
    setOperatorLock(false)
    SetPlayerControl(PlayerId(), true, 0)
    return
  end

  nui(true)

  -- camera
  local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
  state.cam = cam

  SetCamFov(cam, state.fov)

  -- init camera angles to drone heading
  local initH = GetEntityHeading(obj)
  state.camYaw = initH
  state.camYawSmooth = initH
  state.camPitchSmooth = 0.0
  state.camPitch = 0.0
  state.lookYaw = 0.0
  state.lookPitch = 0.0
  RenderScriptCams(true, true, 250, true, true)
  MinimapLockToDrone(true)
  state.active = true
  state.spotlight = false
  state.thermal = false
  state.rangeOverAt = 0

  CreateThread(function()
    while state.active do
      Wait(150)
      nuiUpdate()
      sendRadarUpdate()
      local dp = (state.drone and state.drone ~= 0 and DoesEntityExist(state.drone)) and GetEntityCoords(state.drone) or nil
      TriggerServerEvent('cipher-drone:server:statusTick', {
        battery = state.battery,
        rangeOverAt = state.rangeOverAt,
        pos = dp and { x = dp.x, y = dp.y, z = dp.z } or nil,
      })
    end
  end)

  CreateThread(function()
    local tick = GetGameTimer()
    while state.active do
      Wait(0)

      local dt = GetFrameTime()
      if dt <= 0.0 then dt = 0.016 end

      -- ===== Jamming: recompute jitter + apply periodic drift =====
      if state.jammed then
        local jCfg = Config.Jamming and Config.Jamming.intensity
        if jCfg then
          if not state.jamNextJitterAt or GetGameTimer() >= state.jamNextJitterAt then
            state.jamNextJitterAt = GetGameTimer() + 300
            local lo = jCfg.lookMultiplierMin or 0.6
            local hi = jCfg.lookMultiplierMax or 1.4
            state.jamLookMult = lo + math.random() * (hi - lo)
          end
          if not state.jamNextDriftAt or GetGameTimer() >= state.jamNextDriftAt then
            state.jamNextDriftAt = GetGameTimer() + (jCfg.driftIntervalMs or 1500)
            if state.drone and state.drone ~= 0 and DoesEntityExist(state.drone) then
              local force = jCfg.driftForce or 0.15
              ApplyForceToEntity(state.drone, 1,
                (math.random() - 0.5) * force, (math.random() - 0.5) * force, (math.random() - 0.5) * force * 0.5,
                0.0, 0.0, 0.0, 0, false, true, true, false, true)
            end
          end
        end
      else
        state.jamLookMult = 1.0
      end

      -- Lock player controls while flying the drone, but allow a small whitelist for smooth control
      DisableAllControlActions(0)
      DisableAllControlActions(1)
      DisableAllControlActions(2)

      -- allow mouse look + flight controls + exit
      EnableControlAction(0, 1, true)    -- look lr
      EnableControlAction(0, 2, true)    -- look ud
      EnableControlAction(0, 32, true)   -- W
      EnableControlAction(0, 33, true)   -- S
      EnableControlAction(0, 34, true)   -- A
      EnableControlAction(0, 35, true)   -- D
      EnableControlAction(0, 22, true)   -- Space
      EnableControlAction(0, 36, true)   -- Ctrl
      EnableControlAction(0, 177, true)  -- Backspace
      EnableControlAction(0, 241, true)  -- Scroll up (zoom)
      EnableControlAction(0, 242, true)  -- Scroll down (zoom)

      -- allow mouse look + a few binds
      EnableControlAction(0, 1, true)   -- look lr
      EnableControlAction(0, 2, true)   -- look ud
      EnableControlAction(0, 21, true)  -- sprint (optional)
      EnableControlAction(0, 177, true) -- backspace
      EnableControlAction(0, 22, true)  -- Space (jump)
      EnableControlAction(0, 36, true)  -- Ctrl (duck)
      EnableControlAction(2, 22, true)
      EnableControlAction(2, 36, true)
      EnableControlAction(0, 22, true)
      EnableControlAction(0, 36, true)

      -- ===== Mouse look =====
      local mx, my = 0.0, 0.0
      if Config.Mouse and Config.Mouse.enableLook then
        mx = GetDisabledControlNormal(0, 1)
        my = GetDisabledControlNormal(0, 2)

        local dz = 0.02
        if math.abs(mx) < dz then mx = 0.0 end
        if math.abs(my) < dz then my = 0.0 end

        local sens = (Config.Mouse.lookSensitivity or 2.2) * (state.jamLookMult or 1.0)
        local yawSpeed = sens * 220.0
        local pitchSpeed = sens * 160.0

        -- absolute camera yaw/pitch (independent from drone) so mouse always turns view
        state.camYaw = wrapDeg((state.camYaw or GetEntityHeading(state.drone)) - (mx * yawSpeed * dt))
        state.camPitch = (state.camPitch or 0.0) - (my * pitchSpeed * dt)
        state.camPitch = clamp(state.camPitch, -(Config.Mouse.pitchLimit or 55.0), (Config.Mouse.pitchLimit or 55.0))
      end

      local droneH = GetEntityHeading(state.drone)
      local desiredCamYaw = (state.camYaw or droneH)
      local desiredCamPitch = (state.camPitch or 0.0)

      -- Smooth camera angles
      local camT = math.min(1.0, (state.camLerp or 5.5) * dt)
      state.camYawSmooth = state.camYawSmooth + wrapDeg(desiredCamYaw - state.camYawSmooth) * camT
      state.camPitchSmooth = state.camPitchSmooth + (desiredCamPitch - state.camPitchSmooth) * camT

      -- ===== Drone faces mouse (yaw follow) =====
      if Config.Mouse and Config.Mouse.enableSteer then
        local diff = wrapDeg((state.camYawSmooth or state.camYaw or droneH) - droneH)
        local maxRate = (Config.Mouse.steerMaxRate or 95.0) -- deg/sec
        -- step clamp in degrees this frame
        local step = clamp(diff, -maxRate * dt, maxRate * dt)
        SetEntityAngularVelocity(state.drone, 0.0, 0.0, 0.0)
        SetEntityHeading(state.drone, droneH + step)
        droneH = GetEntityHeading(state.drone)
      end

      -- ===== Update camera =====
      local dposNow = GetEntityCoords(state.drone)
      local off = (Config.Mouse and Config.Mouse.cameraOffset) and Config.Mouse.cameraOffset or vec3(0.0, 0.0, 0.25)
      SetCamCoord(state.cam, dposNow.x + off.x, dposNow.y + off.y, dposNow.z + off.z)
      SetCamRot(state.cam, state.camPitchSmooth or 0.0, 0.0, state.camYawSmooth or GetEntityHeading(state.drone), 2)

      -- keep minimap centered on drone while active
      if minimapLocked then
        local mp = GetEntityCoords(state.drone)
        LockMinimapPosition(mp.x, mp.y)
        LockMinimapAngle(math.floor(GetEntityHeading(state.drone)))
      end

      -- ===== Inputs =====
      local forward = IsDisabledControlPressed(0, 32) -- W
      local back    = IsDisabledControlPressed(0, 33) -- S
      local left    = IsDisabledControlPressed(0, 34) -- A
      local right   = IsDisabledControlPressed(0, 35) -- D
      local up      = IsDisabledControlPressed(0, 22) -- Space
      local down    = IsDisabledControlPressed(0, 36) -- Ctrl

      -- ===== Zoom (mouse wheel) =====
      if Config.Camera then
        -- 241/242 are mouse wheel up/down on most binds
        if IsDisabledControlJustPressed(0, 241) then
          state.fov = math.max(Config.Camera.fovMin or 25.0, (state.fov or 60.0) - (Config.Camera.fovStep or 3.0))
          SetCamFov(state.cam, state.fov)
          nuiUpdate()
        elseif IsDisabledControlJustPressed(0, 242) then
          state.fov = math.min(Config.Camera.fovMax or 80.0, (state.fov or 60.0) + (Config.Camera.fovStep or 3.0))
          SetCamFov(state.cam, state.fov)
          nuiUpdate()
        end
      end

      if IsDisabledControlJustPressed(0, 177) then
        TriggerServerEvent('cipher-drone:server:end', 'manual')
        MinimapLockToDrone(false)
        if droneMapBlip and DoesBlipExist(droneMapBlip) then RemoveBlip(droneMapBlip) droneMapBlip=nil end
        return
      end

      -- Movement direction based on drone heading (drone follows mouse yaw)
      local fwd = vecFromHeadingDeg(droneH)
      local rgt = rightFromHeadingDeg(droneH)

      local dir = vec3(0.0, 0.0, 0.0)
      if forward then dir = dir + fwd end
      if back    then dir = dir - fwd end
      if right   then dir = dir + rgt end
      if left    then dir = dir - rgt end

      local moved = (forward or back or left or right)

      local vel = GetEntityVelocity(state.drone)
      local v = vec3(vel.x, vel.y, vel.z)

      local desired = vec3(0.0, 0.0, 0.0)
      if moved then
        local len = math.sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z)
        if len > 0.001 then
          dir = dir / len
          desired = dir * (Config.Drone.maxSpeed or 11.0)
        end
      end

      -- Vertical control (keyboard)
      local climb = 0.0
      if up then climb = climb + (Config.Drone.climbSpeed or Config.Drone.verticalSpeed or 9.0) end
      if down then climb = climb - (Config.Drone.climbSpeed or Config.Drone.verticalSpeed or 9.0) end
      desired = vec3(desired.x, desired.y, climb)

      -- Cinematic exponential smoothing toward desired velocity
      local k = math.max(1.5, math.min(10.0, ((Config.Drone.accel or 16.0) * 0.35)))
      v = vec3(
        expSmooth(v.x, desired.x, k, dt),
        expSmooth(v.y, desired.y, k, dt),
        expSmooth(v.z, desired.z, k, dt)
      )

      if not moved and not up and not down then
        local damp = math.max(0.0, 1.0 - ((Config.Drone.brake or 10.0) * dt))
        v = v * damp
      end

      local dpos = GetEntityCoords(state.drone)
      if dpos.z > (state.startPos.z + (Config.Drone.maxAltitude or 60.0)) and v.z > 0.0 then
        v = vec3(v.x, v.y, 0.0)
      end

      SetEntityVelocity(state.drone, v.x, v.y, v.z)


      
      -- ===== Spotlight rendering =====
      if state.spotlight and Config.Spotlight and Config.Spotlight.enabled then
        local spPos = GetEntityCoords(state.drone)
        local camRot2 = GetCamRot(state.cam, 2)
        local zz = math.rad(camRot2.z)
        local xx = math.rad(camRot2.x)
        local nn = math.abs(math.cos(xx))
        local fwd = vec3(-math.sin(zz) * nn, math.cos(zz) * nn, math.sin(xx))
        local dist = Config.Spotlight.distance or 45.0
        local bright = Config.Spotlight.brightness or 12.0
        local radius = Config.Spotlight.radius or 25.0
        local falloff = Config.Spotlight.falloff or 15.0
        -- soft white spotlight
        DrawSpotLight(spPos.x, spPos.y, spPos.z + 0.10, fwd.x, fwd.y, fwd.z, 255, 255, 245, dist, bright, falloff, radius, 1.0)
      end

      -- ===== Reticle lock-on detection (UI feedback only, drives the NUI reticle) =====
      if state.trackerCrosshair then
        if not state.lastLockCheckAt or GetGameTimer() - state.lastLockCheckAt >= 120 then
          state.lastLockCheckAt = GetGameTimer()
          local camCoord = GetCamCoord(state.cam)
          local camRot = GetCamRot(state.cam, 2)
          local lz = math.rad(camRot.z)
          local lx = math.rad(camRot.x)
          local lnum = math.abs(math.cos(lx))
          local ldir = vec3(-math.sin(lz) * lnum, math.cos(lz) * lnum, math.sin(lx))
          local ldst = camCoord + ldir * 260.0
          local lray = StartShapeTestRay(camCoord.x, camCoord.y, camCoord.z, ldst.x, ldst.y, ldst.z, 10, state.drone, 0)
          local _, lhit, _, _, lEntityHit = GetShapeTestResult(lray)

          local locked = false
          if lhit == 1 and lEntityHit and lEntityHit ~= 0 then
            if (IsEntityAPed(lEntityHit) and IsPedAPlayer(lEntityHit)) or IsEntityAVehicle(lEntityHit) then
              locked = true
            end
          end

          if locked ~= state.reticleLocked then
            state.reticleLocked = locked
            SendNUIMessage({ type = 'reticle', locked = locked })
          end
        end
      end

      if state.trackerViz and state.trackerViz.untilTs and GetGameTimer() < state.trackerViz.untilTs then
        local fc = state.trackerViz.from
        local tc = state.trackerViz.to
        if fc and tc then
          if Config.Tracker and Config.Tracker.tracerStyle == 'electric' then
            PlayPtfx('core', 'ent_dst_elec_fire_sp', fc.x, fc.y, fc.z, 0.45)
            PlayPtfx('core', 'ent_dst_elec_fire_sp', tc.x, tc.y, tc.z, 0.65)
          else
            DrawLine(fc.x, fc.y, fc.z, tc.x, tc.y, tc.z, 0, 153, 255, 220)
            DrawMarker(28, tc.x, tc.y, tc.z, 0.0,0.0,0.0, 0.0,0.0,0.0, 0.10,0.10,0.10, 0,153,255, 200, false, false, 2, nil, nil, false)
          end
        end
      end

      -- battery tick
      if GetGameTimer() - tick >= 1000 then
        tick = GetGameTimer()
        state.battery = math.max(0, state.battery - 1)

        if state.battery <= 0 then
          TriggerServerEvent('cipher-drone:server:end', 'battery')
          MinimapLockToDrone(false)
          if droneMapBlip and DoesBlipExist(droneMapBlip) then RemoveBlip(droneMapBlip) droneMapBlip=nil end
          return
        end
      end

      -- ===== Shoot-down health poll =====
      if Config.Drone.canBeShotDown and state.drone and state.drone ~= 0 then
        if not state.lastHealthCheckAt or GetGameTimer() - state.lastHealthCheckAt >= 300 then
          state.lastHealthCheckAt = GetGameTimer()
          local hp = GetEntityHealth(state.drone)

          if state.lastHealth and hp < state.lastHealth then
            SendNUIMessage({ type = 'hit' })
          end
          state.lastHealth = hp

          if hp <= 1 then
            local droneObj = state.drone
            runDestroySequence(droneObj)

            MinimapLockToDrone(false)
            if droneMapBlip and DoesBlipExist(droneMapBlip) then RemoveBlip(droneMapBlip) droneMapBlip=nil end
            if DoesEntityExist(droneObj) and not state.usingPlaced then DeleteEntity(droneObj) end

            TriggerServerEvent('cipher-drone:server:end', 'destroyed')
            return
          end
        end
      end
    end
  end)

end)

RegisterNetEvent('cipher-drone:client:forceEnd', function(reason)
  cleanup(reason)
end)

-- ox_lib keybinds (if available) for clean toggles/shoot/ping. Registered
-- once at resource start, NOT inside the per-session 'start' handler above
-- (previously nested there, which re-registered all 5 keybinds every time
-- a drone session began, stacking duplicate handlers over a play session).
if Framework.HasOxLib() and type(lib) == 'table' then
  lib.addKeybind({
    name = 'cipher_drone_spotlight',
    description = 'Drone: Toggle Spotlight',
    defaultKey = Config.Keybinds.spotlight,
    onPressed = function()
      if not state.active then return end
      state.spotlight = not state.spotlight
      nuiUpdate()
    end
  })

  lib.addKeybind({
    name = 'cipher_drone_thermal',
    description = 'Drone: Toggle Thermal',
    defaultKey = Config.Keybinds.thermal,
    onPressed = function()
      if not state.active then return end
      if not Config.Camera.enableThermal then return end
      state.thermal = not state.thermal
      SetSeethrough(state.thermal and (Config.Camera.thermalSeeThrough == true))

        -- tune see-through so it doesn't feel like full x-ray through whole buildings
        pcall(function() SeethroughSetFadeStartDistance(Config.Camera.thermalSeeThroughFadeStart or 18.0) end)
        pcall(function() SeethroughSetFadeEndDistance(Config.Camera.thermalSeeThroughFadeEnd or 65.0) end)
        pcall(function() SeethroughSetHiLightIntensity(Config.Camera.thermalSeeThroughHighlightIntensity or 0.28) end)
        pcall(function() SeethroughSetNoiseAmountMin(Config.Camera.thermalSeeThroughNoiseMin or 0.0) end)
        pcall(function() SeethroughSetNoiseAmountMax(Config.Camera.thermalSeeThroughNoiseMax or 0.0) end)

      if state.thermal and Config.Camera.thermalTimecycle then
        SetTimecycleModifier(Config.Camera.thermalTimecycle)
        SetTimecycleModifierStrength(Config.Camera.thermalTimecycleStrength or 0.8)
      else
        ClearTimecycleModifier()
      end
      nuiUpdate()
    end
  })

  lib.addKeybind({
    name = 'cipher_drone_ping',
    description = 'Drone: Ping Marker',
    defaultKey = Config.Keybinds.ping,
    onPressed = function()
      if not state.active then return end
      local pos = GetEntityCoords(state.drone)
      SetNewWaypoint(pos.x, pos.y)
      Framework.Notify('Pinged drone location.', 'success')
    end
  })

  lib.addKeybind({
    name = 'cipher_drone_recall',
    description = 'Drone: Recall / Exit',
    defaultKey = Config.Keybinds.recall,
    onPressed = function()
      if not state.active then return end
      TriggerServerEvent('cipher-drone:server:end', 'recall')
    end
  })

  lib.addKeybind({
    name = 'cipher_drone_tracker',
    description = 'Drone: Fire Tracker Dart',
    defaultKey = Config.Keybinds.tracker,
    onPressed = function()
      if not state.active then return end
      if not Config.Tracker.enabled then return end

      -- raycast from camera forward
      local camCoord = GetCamCoord(state.cam)
      local camRot = GetCamRot(state.cam, 2)
      local dir = (function(rot)
        local z = math.rad(rot.z)
        local x = math.rad(rot.x)
        local num = math.abs(math.cos(x))
        return vec3(-math.sin(z) * num, math.cos(z) * num, math.sin(x))
      end)(camRot)

      local dst = camCoord + dir * 200.0
      local ray = StartShapeTestRay(camCoord.x, camCoord.y, camCoord.z, dst.x, dst.y, dst.z, 10, state.drone, 0)
      local _, hit, endCoords, _, entityHit = GetShapeTestResult(ray)

      SendNUIMessage({ type = 'dartFired' })

      if hit == 1 and entityHit and entityHit ~= 0 then
        if IsEntityAPed(entityHit) and IsPedAPlayer(entityHit) then
          TriggerServerEvent('cipher-drone:server:trackerHit', {
            targetType = 'ped',
            targetNet = NetworkGetNetworkIdFromEntity(entityHit),
            targetServerId = GetPlayerServerId(NetworkGetPlayerIndexFromPed(entityHit)),
          })
          return
        end

        if IsEntityAVehicle(entityHit) then
          TriggerServerEvent('cipher-drone:server:trackerHit', {
            targetType = 'veh',
            targetNet = NetworkGetNetworkIdFromEntity(entityHit),
          })
          return
        end
      end

      Framework.Notify('No valid target for tracker.', 'error')
    end
  })
end

RegisterNetEvent('cipher-drone:client:trackerStatus', function(data)
  if not Config.UI.enabled then return end
  SendNUIMessage({ type = 'trackerCd', seconds = data and data.cooldown or 0 })
end)

-- Viewer pings for jobs/perms: create/update blips client-side
RegisterNetEvent('cipher-drone:client:trackerPing', function(data)
  if not data or not data.trackerId or not data.targetNet then return end

  local ent = NetToEnt(data.targetNet)
  if not ent or ent == 0 or not DoesEntityExist(ent) then return end

  local pos = GetEntityCoords(ent)
  state.lastTrackerId = data.trackerId

  -- remember last known tracker position (follows the target)
  state.lastTrackerPos = pos
  state.lastTrackerAt = GetGameTimer()

  -- Lose tracking if target leaves range from original dart attach point
  local maxDist = (Config.Tracker and Config.Tracker.maxDistance) or nil
  if maxDist and data.origin then
    local o = vec3(data.origin.x or 0.0, data.origin.y or 0.0, data.origin.z or 0.0)
    if #(pos - o) > maxDist then
      local old = trackerBlips[data.trackerId]
      if old and DoesBlipExist(old) then RemoveBlip(old) end
      trackerBlips[data.trackerId] = nil
      return
    end
  end
  local blip = trackerBlips[data.trackerId]

  if not blip or not DoesBlipExist(blip) then
    blip = AddBlipForCoord(pos.x, pos.y, pos.z)
    SetBlipSprite(blip, data.blip.sprite)
    SetBlipColour(blip, data.blip.color)
    SetBlipScale(blip, data.blip.scale)
    SetBlipAsShortRange(blip, data.blip.shortRange)

    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('Tracker Ping')
    EndTextCommandSetBlipName(blip)

    trackerBlips[data.trackerId] = blip
  else
    SetBlipCoords(blip, pos.x, pos.y, pos.z)
  end
end)

-- Cleanup blips occasionally (optional)
CreateThread(function()
  while true do
    Wait(10000)
    for id, blip in pairs(trackerBlips) do
      if blip and DoesBlipExist(blip) then
        -- keep; server will stop sending when expired
      else
        trackerBlips[id] = nil
      end
    end
  end
end)


-- RegisterKeyMapping based binds (works without ox_lib). Gated behind
-- HasOxLib() so these don't double-fire alongside the lib.addKeybind
-- handlers above when ox_lib IS running (previously unconditional, which
-- meant every key press fired both handlers at once).
if not Framework.HasOxLib() then

RegisterCommand('cipher_drone_spotlight', function()
  if not state.active then return end
  state.spotlight = not state.spotlight
  nuiUpdate()
end, false)
RegisterKeyMapping('cipher_drone_spotlight', 'Drone: Toggle Spotlight', 'keyboard', Config.Keybinds.spotlight)

RegisterCommand('cipher_drone_thermal', function()
  if not state.active then return end
  if not Config.Camera.enableThermal then return end
  state.thermal = not state.thermal
  SetSeethrough(state.thermal and (Config.Camera.thermalSeeThrough == true))

          -- tune see-through so it doesn't feel like full x-ray through whole buildings
          pcall(function() SeethroughSetFadeStartDistance(Config.Camera.thermalSeeThroughFadeStart or 18.0) end)
          pcall(function() SeethroughSetFadeEndDistance(Config.Camera.thermalSeeThroughFadeEnd or 65.0) end)
          pcall(function() SeethroughSetHiLightIntensity(Config.Camera.thermalSeeThroughHighlightIntensity or 0.28) end)
          pcall(function() SeethroughSetNoiseAmountMin(Config.Camera.thermalSeeThroughNoiseMin or 0.0) end)
          pcall(function() SeethroughSetNoiseAmountMax(Config.Camera.thermalSeeThroughNoiseMax or 0.0) end)

  if state.thermal and Config.Camera.thermalTimecycle then
    SetTimecycleModifier(Config.Camera.thermalTimecycle)
    SetTimecycleModifierStrength(Config.Camera.thermalTimecycleStrength or 0.8)
  else
    ClearTimecycleModifier()
  end
  nuiUpdate()
end, false)
RegisterKeyMapping('cipher_drone_thermal', 'Drone: Toggle Thermal', 'keyboard', Config.Keybinds.thermal)

RegisterCommand('cipher_drone_ping', function()
  if not state.active then return end

  local id = state.lastTrackerId
  if not id then
    Framework.Notify('No tracker dart to ping yet.', 'error')
    return
  end

  local blip = trackerBlips and trackerBlips[id] or nil
  if not blip or not DoesBlipExist(blip) then
    Framework.Notify('Tracker ping not active yet (wait a moment).', 'error')
    return
  end

  state.routeOn = not state.routeOn
  SetBlipRoute(blip, state.routeOn)
  SetBlipRouteColour(blip, 3)

  if state.routeOn then
    Framework.Notify('Routing to tracker target.', 'success')
  else
    Framework.Notify('Tracker route cleared.', 'success')
  end
end, false)
RegisterKeyMapping('cipher_drone_ping', 'Drone: Ping Marker', 'keyboard', Config.Keybinds.ping)

RegisterCommand('cipher_drone_recall', function()
  if not state.active then return end
  TriggerServerEvent('cipher-drone:server:end', 'recall')
end, false)
RegisterKeyMapping('cipher_drone_recall', 'Drone: Recall / Exit', 'keyboard', Config.Keybinds.recall)

RegisterCommand('cipher_drone_tracker', function()
  if not state.active then return end
  if not Config.Tracker.enabled then return end

  local camCoord = GetCamCoord(state.cam)
  local camRot = GetCamRot(state.cam, 2)
  local z = math.rad(camRot.z)
  local x = math.rad(camRot.x)
  local num = math.abs(math.cos(x))
  local dir = vec3(-math.sin(z) * num, math.cos(z) * num, math.sin(x))

  local dst = camCoord + dir * 260.0
  local ray = StartShapeTestRay(camCoord.x, camCoord.y, camCoord.z, dst.x, dst.y, dst.z, 10, state.drone, 0)
  local _, hit, endCoords, _, entityHit = GetShapeTestResult(ray)

  SendNUIMessage({ type = 'dartFired' })

  TrackerVisual(camCoord, endCoords or dst, hit == 1)
  if endCoords then
    state.lastTrackerPos = endCoords
    state.lastTrackerAt = GetGameTimer()
  end

  -- Taser round visual (no damage)
  if endCoords then
    local wep = GetHashKey('WEAPON_STUNGUN')
    ShootSingleBulletBetweenCoords(camCoord.x, camCoord.y, camCoord.z, endCoords.x, endCoords.y, endCoords.z, 0, true, wep, PlayerPedId(), true, false, 120.0)
  end
  AnimpostfxPlay('FocusIn', 0, false)
  PlaySoundFrontend(-1, "Firing_Pin_Good", "DLC_HEIST_BIOLAB_PREP_HACKING_SOUNDS", true)

  if hit ~= 1 or not entityHit or entityHit == 0 then
    Framework.Notify('No valid target for tracker.', 'error')
    return
  end

  local payload = { origin = { x = (endCoords and endCoords.x) or camCoord.x, y = (endCoords and endCoords.y) or camCoord.y, z = (endCoords and endCoords.z) or camCoord.z } }

  if IsEntityAPed(entityHit) then
    local targetNet = NetworkGetNetworkIdFromEntity(entityHit)
    local myNet = NetworkGetNetworkIdFromEntity(PlayerPedId())
    if targetNet == myNet then
      Framework.Notify('Cannot tag yourself with tracker.', 'error')
      return
    end

    payload.targetType = 'ped'
    payload.targetNet = targetNet

    if IsPedAPlayer(entityHit) then
      local ply = NetworkGetPlayerIndexFromPed(entityHit)
      local sid = ply and GetPlayerServerId(ply) or 0
      local meSid = GetPlayerServerId(PlayerId())
      if sid == 0 or sid == meSid then
        Framework.Notify('Cannot tag yourself with tracker.', 'error')
        return
      end
      payload.targetServerId = sid
    end

    TriggerServerEvent('cipher-drone:server:trackerHit', payload)
    return
  end

  if IsEntityAVehicle(entityHit) then
    payload.targetType = 'veh'
    payload.targetNet = NetworkGetNetworkIdFromEntity(entityHit)
    TriggerServerEvent('cipher-drone:server:trackerHit', payload)
    return
  end

  Framework.Notify('No valid target for tracker.', 'error')
end, false)
RegisterKeyMapping('cipher_drone_tracker', 'Drone: Fire Tracker Dart', 'keyboard', Config.Keybinds.tracker)

end -- if not Framework.HasOxLib()



RegisterNetEvent('cipher-drone:client:trackerExpired', function(data)
  if not data or not data.trackerId then return end
  local blip = trackerBlips[data.trackerId]
  if blip and DoesBlipExist(blip) then
    RemoveBlip(blip)
  end
  trackerBlips[data.trackerId] = nil
end)

-- If YOU are the tracked target (ped), we can apply environment decay (rain/water) client-side and report to server
local selfTrackers = {} -- [trackerId] = expiresAt
RegisterNetEvent('cipher-drone:client:trackerAttachedSelf', function(data)
  if not data or not data.trackerId then return end
  selfTrackers[data.trackerId] = tonumber(data.expiresAt or 0) or 0
end)

-- Server is authoritative on jammed state (distance-tick against active
-- jammers); we only render the degraded-control effect here.
RegisterNetEvent('cipher-drone:client:jammed', function(isJammed)
  state.jammed = isJammed and true or false
  if not state.jammed then
    state.jamLookMult = 1.0
  end
  if Config.UI.enabled then
    SendNUIMessage({ type = 'jammed', state = state.jammed })
  end
end)

CreateThread(function()
  while true do
    local interval = (Config.Tracker.counterplay and Config.Tracker.counterplay.environmentDecay and Config.Tracker.counterplay.environmentDecay.checkIntervalSeconds) or 2
    Wait(math.max(1000, interval * 1000))

    if not (Config.Tracker.counterplay and Config.Tracker.counterplay.enabled) then
      goto continue
    end
    local env = Config.Tracker.counterplay.environmentDecay
    if not (env and env.enabled) then
      goto continue
    end

    local ped = PlayerPedId()
    if not ped or ped == 0 then goto continue end

    local inWater = env.waterReducesDuration and (IsEntityInWater(ped) or IsPedSwimming(ped) or IsPedSwimmingUnderWater(ped))
    local rain = env.rainReducesDuration and (GetRainLevel() or 0.0) > 0.35

    if not inWater and not rain then
      goto continue
    end

    local decay = 0.0
    if rain then decay = decay + (env.rainDecayPerSecond or 0.5) * interval end
    if inWater then decay = decay + (env.waterDecayPerSecond or 1.5) * interval end
    if decay <= 0 then goto continue end

    for trackerId, _ in pairs(selfTrackers) do
      TriggerServerEvent('cipher-drone:server:decayTracker', trackerId, decay)
    end

    ::continue::
  end
end)


-- Mechanic-bay removal for VEHICLE trackers (counterplay)
do
  local showing = false
  local function showPrompt(text)
    if Framework.HasOxLib() and lib and lib.showTextUI then
      if not showing then
        lib.showTextUI(text, { position = 'left-center' })
        showing = true
      end
    else
      -- fallback: help text
      AddTextEntry('GS_DRONE_HELP', text)
      BeginTextCommandDisplayHelp('GS_DRONE_HELP')
      EndTextCommandDisplayHelp(0, false, true, 1)
    end
  end

  local function hidePrompt()
    if Framework.HasOxLib() and lib and lib.hideTextUI then
      if showing then
        lib.hideTextUI()
        showing = false
      end
    else
      -- no persistent fallback to hide
      showing = false
    end
  end

  CreateThread(function()
    while true do
      Wait(250)

      local cp = Config.Tracker and Config.Tracker.counterplay
      local vr = cp and cp.vehicleRemoval
      if not (cp and cp.enabled and vr and vr.enabled and vr.zones and #vr.zones > 0) then
        if showing then hidePrompt() end
        goto continue
      end

      local ped = PlayerPedId()
      if not ped or ped == 0 then goto continue end

      local veh = GetVehiclePedIsIn(ped, false)
      if veh == 0 then
        if showing then hidePrompt() end
        goto continue
      end

      -- must be driver
      if GetPedInVehicleSeat(veh, -1) ~= ped then
        if showing then hidePrompt() end
        goto continue
      end

      local pcoords = GetEntityCoords(ped)
      local inZone = false
      for _, z in ipairs(vr.zones) do
        if z and z.coords and z.radius then
          if #(pcoords - z.coords) <= (z.radius + 0.001) then
            inZone = true
            break
          end
        end
      end

      if not inZone then
        if showing then hidePrompt() end
        goto continue
      end

      showPrompt('[E] Remove vehicle tracker')

      -- E
      if IsControlJustPressed(0, 38) then
        local netId = NetworkGetNetworkIdFromEntity(veh)
        TriggerServerEvent('cipher-drone:server:removeVehicleTrackers', netId)
        Wait(1000)
      end

      ::continue::
    end
  end)
end



AddEventHandler('onClientResourceStart', function(res)
  if res ~= GetCurrentResourceName() then return end
  VisualReset()
  if Config.UI and Config.UI.enabled then
    SendNUIMessage({ type = 'toggle', state = false })
  end
end)

AddEventHandler('onClientResourceStop', function(res)
  if res ~= GetCurrentResourceName() then return end
  VisualReset()
  if Config.UI and Config.UI.enabled then
    SendNUIMessage({ type = 'toggle', state = false })
  end
end)


-- Always clear any stuck visual modifiers on load/restart
CreateThread(function()
  Wait(0)
  VisualReset()
  Wait(250)
  VisualReset()
  Wait(1000)
  VisualReset()
end)

AddEventHandler('playerSpawned', function()
  VisualReset()
end)



RegisterNetEvent('cipher-drone:client:placeMode', function()
  if state.active or state.placedMode then return end
  state.placedMode = true

  RequestModel(Config.Drone.model)
  while not HasModelLoaded(Config.Drone.model) do Wait(0) end

  local ghost = CreateObjectNoOffset(Config.Drone.model, 0.0, 0.0, 0.0, false, false, false)
  SetEntityAlpha(ghost, 180, false)
  SetEntityCollision(ghost, false, false)
  FreezeEntityPosition(ghost, true)
  state.placedGhost = ghost

  Framework.Notify('Place drone: [E] confirm, [Backspace] cancel', 'success')

  CreateThread(function()
    while state.placedMode do
      DisableControlAction(0, 38, true)
      DisableControlAction(0, 177, true)

      local ped = PlayerPedId()
      local pcoords = GetEntityCoords(ped)
      local fwd = GetEntityForwardVector(ped)
      local start = pcoords + fwd * 1.2 + vec3(0.0,0.0,0.2)
      local dest  = start + vec3(0.0,0.0,-4.0)

      local ray = StartShapeTestRay(start.x, start.y, start.z, dest.x, dest.y, dest.z, 1, ped, 0)
      local _, hit, endCoords = GetShapeTestResult(ray)

      local place = hit == 1 and endCoords or (pcoords + fwd * 1.2)
      local heading = GetEntityHeading(ped)

      SetEntityCoordsNoOffset(ghost, place.x, place.y, place.z, false, false, false)
      SetEntityHeading(ghost, heading)
      DrawMarker(0, place.x, place.y, place.z + 0.35, 0,0,0, 0,0,0, 0.35,0.35,0.35, 0,255,200, 120, false, false, 2, false, nil, nil, false)

      if IsDisabledControlJustPressed(0, 38) then
        state.placedMode = false
        DeleteEntity(ghost)
        state.placedGhost = 0
        -- spawn the placed drone client-side (networked) and send its netId to server
        local obj = CreateObject(Config.Drone.model, place.x, place.y, place.z + 0.02, true, true, true)
        SetEntityHeading(obj, heading)
        SetEntityCollision(obj, true, true)
        FreezeEntityPosition(obj, false)
        SetEntityInvincible(obj, Config.Drone.invincibleIfDisabled)

        NetworkRegisterEntityAsNetworked(obj)

        local netId = 0
        for _=1,80 do
          netId = NetworkGetNetworkIdFromEntity(obj)
          if netId ~= 0 then break end
          Wait(0)
        end

        if netId == 0 then
          DeleteEntity(obj)
          Framework.Notify('Failed to network drone (OneSync required).', 'error')
          return
        end

        SetNetworkIdExistsOnAllMachines(netId, true)
        SetNetworkIdCanMigrate(netId, true)
        TriggerServerEvent('cipher-drone:server:placeConfirm', { netId = netId, x = place.x, y = place.y, z = place.z, h = heading })
        return
      end

      if IsDisabledControlJustPressed(0, 177) then
        state.placedMode = false
        DeleteEntity(ghost)
        state.placedGhost = 0
        Framework.Notify('Placement canceled.', 'error')
        return
      end

      Wait(0)
    end
  end)
end)

RegisterNetEvent('cipher-drone:client:placed', function(data)
  -- placeholder (ox_target handles interaction)
end)

CreateThread(function()
  if GetResourceState('ox_target') ~= 'started' then return end
  exports.ox_target:addModel({ Config.Drone.model }, {
    {
      name = 'cipher_drone_connect',
      icon = 'fa-solid fa-satellite-dish',
      label = 'Connect / Fly Drone',
      distance = 2.0,
      canInteract = function(entity)
        return not state.active and entity and entity ~= 0
      end,
      onSelect = function(data)
        local ent = data.entity
        if not ent or ent == 0 then return end
        TriggerServerEvent('cipher-drone:server:connectPlaced', NetworkGetNetworkIdFromEntity(ent))
      end
    },
    {
      name = 'cipher_drone_pack',
      icon = 'fa-solid fa-box',
      label = 'Pack Drone',
      distance = 2.0,
      canInteract = function(entity)
        return not state.active and entity and entity ~= 0
      end,
      onSelect = function(data)
        local ent = data.entity
        if not ent or ent == 0 then return end
        TriggerServerEvent('cipher-drone:server:packDrone', NetworkGetNetworkIdFromEntity(ent))
      end
    }
  })
end)


RegisterNetEvent('cipher-drone:client:deletePlaced', function(netId)
  netId = tonumber(netId or 0) or 0
  if netId <= 0 then return end
  local ent = NetToObj(netId)
  if ent ~= 0 and DoesEntityExist(ent) then
    DeleteEntity(ent)
  end
end)


