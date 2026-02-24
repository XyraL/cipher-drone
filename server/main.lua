local Framework = Config.Framework.mode == 'auto' and GS.AutoFramework() or Config.Framework.mode
local Inventory = Config.Inventory.mode == 'auto' and GS.AutoInventory() or Config.Inventory.mode

local QBCore = nil
local QBX = nil

if Framework == 'qb' then
  QBCore = exports['qb-core']:GetCoreObject()
elseif Framework == 'qbox' then
  if GetResourceState('qb-core') == 'started' then
    QBCore = exports['qb-core']:GetCoreObject()
  end
end

local Active = {
  placed = {}, 
  placedByOwner = {}, 

  drone = {},      
  cooldown = {},   
  trackerCd = {},  
  trackers = {},   
  trackerByOwner = {}, 
}

local function now() return os.time() end

local function getJob(src)
  if QBCore then
    local ply = QBCore.Functions.GetPlayer(src)
    if ply and ply.PlayerData and ply.PlayerData.job then
      return ply.PlayerData.job.name
    end
  end
  local st = Player(src).state
  if st and st.job and st.job.name then return st.job.name end
  if st and st.job then return st.job end
  return nil
end

local function isAllowed(src)
  if Config.General.allowAll then return true end
  local job = getJob(src)
  if not job then return false end
  return Config.General.allowedJobs[job] == true
end

local function hasItem(src, itemName)
  if Inventory == 'ox_inventory' and GetResourceState('ox_inventory') == 'started' then
    local count = exports.ox_inventory:Search(src, 'count', itemName)
    return (count or 0) > 0
  end

  if QBCore then
    local ply = QBCore.Functions.GetPlayer(src)
    if not ply then return false end
    local it = ply.Functions.GetItemByName(itemName)
    return it ~= nil and (it.amount or it.count or 1) > 0
  end

  return true 

end

local function removeItem(src, itemName, amount)
  amount = tonumber(amount or 1) or 1
  if Inventory == 'ox_inventory' and GetResourceState('ox_inventory') == 'started' then
    return exports.ox_inventory:RemoveItem(src, itemName, amount)
  end
  if QBCore then
    local ply = QBCore.Functions.GetPlayer(src)
    if not ply then return false end
    return ply.Functions.RemoveItem(itemName, amount)
  end
  return true
end

local function addItem(src, itemName, amount)
  amount = tonumber(amount or 1) or 1
  if Inventory == 'ox_inventory' and GetResourceState('ox_inventory') == 'started' then
    return exports.ox_inventory:AddItem(src, itemName, amount)
  end
  if QBCore then
    local ply = QBCore.Functions.GetPlayer(src)
    if not ply then return false end
    return ply.Functions.AddItem(itemName, amount)
  end
  return true
end

local function setCooldown(tbl, src, seconds)
  tbl[src] = now() + seconds
end

local function onCooldown(tbl, src)
  local t = tbl[src]
  return t ~= nil and t > now()
end

local function cooldownLeft(tbl, src)
  local t = tbl[src] or 0
  return math.max(0, t - now())
end

CreateThread(function()
  if QBCore then
    QBCore.Functions.CreateUseableItem(Config.Inventory.droneItem, function(source)
      TriggerEvent('gs-drone:server:useDroneItem', source)
    end)
  end
end)

RegisterNetEvent('gs-drone:server:useDroneItem', function(forcedSrc)
  local src = forcedSrc or source

  if not isAllowed(src) then
    GS.Notify(src, 'You are not allowed to use this drone.', 'error')
    return
  end

  if not hasItem(src, Config.Inventory.droneItem) then
    GS.Notify(src, ('Missing item: %s'):format(Config.Inventory.droneItem), 'error')
    return
  end

  if onCooldown(Active.cooldown, src) then
    GS.Notify(src, ('Drone cooling down (%ss).'):format(cooldownLeft(Active.cooldown, src)), 'error')
    return
  end

  if Active.drone[src] then
    GS.Notify(src, 'Drone already active.', 'error')
    return
  end

  Active.pendingPlace = Active.pendingPlace or {}
  Active.pendingPlace[src] = { startedAt = now() }

  TriggerClientEvent('gs-drone:client:placeMode', src, {})
end)

RegisterNetEvent('gs-drone:server:registerDrone', function(netId)
  local src = source
  if not Active.drone[src] then return end
  Active.drone[src].netId = netId
end)

RegisterNetEvent('gs-drone:server:end', function(reason)
  local src = source
  if Active.drone[src] then
    local st = Active.drone[src]
    if st.placed and st.netId and Active.placed and Active.placed[st.netId] then
      Active.placed[st.netId].inUse = false
    end
    Active.drone[src] = nil
    setCooldown(Active.cooldown, src, Config.General.droneCooldownSeconds)
  end
  TriggerClientEvent('gs-drone:client:forceEnd', src, reason or 'ended')
end)

RegisterNetEvent('gs-drone:server:statusTick', function(data)
  local src = source
  local st = Active.drone[src]
  if not st then return end

  st.battery = math.max(0, tonumber(data.battery or st.battery) or st.battery)
  st.rangeOverAt = tonumber(data.rangeOverAt or 0) or 0

  if st.battery <= 0 then
    TriggerEvent('gs-drone:server:end', 'battery')
    return
  end

  if st.rangeOverAt > 0 and (now() - st.rangeOverAt) >= Config.Drone.rangeGraceSeconds then
    TriggerEvent('gs-drone:server:end', 'range')
    return
  end
end)

RegisterNetEvent('gs-drone:server:trackerHit', function(payload)
  local src = source
  if not Config.Tracker.enabled then return end
  if not Active.drone[src] then return end

  if Config.Tracker.restrictToJobs then
    local job = getJob(src)
    if not job or not Config.Tracker.allowedJobs[job] then
      GS.Notify(src, 'Tracker disabled for your role.', 'error')
      return
    end
  end

  if onCooldown(Active.trackerCd, src) then
    GS.Notify(src, ('Tracker cooling down (%ss).'):format(cooldownLeft(Active.trackerCd, src)), 'error')
    return
  end

  local owned = Active.trackerByOwner[src] or 0
  if owned >= Config.Tracker.maxActivePerPlayer then
    GS.Notify(src, 'Tracker limit reached.', 'error')
    return
  end

  local targetType = payload and payload.targetType
  local targetNet = payload and tonumber(payload.targetNet or 0) or 0
  if (targetType ~= 'ped' and targetType ~= 'veh') or targetNet <= 0 then
    return
  end

  setCooldown(Active.trackerCd, src, Config.Tracker.cooldownSeconds)

  local trackerId = ('%s:%s:%s'):format(src, now(), math.random(1000, 9999))
  Active.trackers[trackerId] = {
    owner = src,
    targetType = targetType,
    targetNet = targetNet,
    origin = (payload and payload.origin) or nil,
    expiresAt = now() + Config.Tracker.durationSeconds,
  }
  Active.trackerByOwner[src] = owned + 1

if targetType == 'ped' and payload and tonumber(payload.targetServerId or 0) > 0 then
  TriggerClientEvent('gs-drone:client:trackerAttachedSelf', tonumber(payload.targetServerId), {
    trackerId = trackerId,
    expiresAt = Active.trackers[trackerId].expiresAt
  })
end



  TriggerClientEvent('gs-drone:client:trackerStatus', src, { cooldown = Config.Tracker.cooldownSeconds })
GS.Notify(src, 'Tracker dart attached.', 'success')
end)


local function removeTrackersByTarget(targetType, targetNet)
  local removed = 0
  for id, tr in pairs(Active.trackers) do
    if tr.targetType == targetType and tr.targetNet == targetNet then
      Active.trackers[id] = nil
      removed = removed + 1
      local owner = tr.owner
      if owner then
        Active.trackerByOwner[owner] = math.max(0, (Active.trackerByOwner[owner] or 1) - 1)
      end
      TriggerClientEvent('gs-drone:client:trackerExpired', -1, { trackerId = id })
    end
  end
  return removed
end

local function removeTrackerId(id)
  local tr = Active.trackers[id]
  if not tr then return false end
  Active.trackers[id] = nil
  local owner = tr.owner
  if owner then
    Active.trackerByOwner[owner] = math.max(0, (Active.trackerByOwner[owner] or 1) - 1)
  end
  TriggerClientEvent('gs-drone:client:trackerExpired', -1, { trackerId = id })
  return true
end

local function canViewTracker(viewerSrc)
  local job = getJob(viewerSrc)
  if job and Config.Tracker.viewers.jobs[job] then return true end
  local ace = Config.Tracker.viewers.ace
  if ace and IsPlayerAceAllowed(viewerSrc, ace) then return true end
  return false
end

-- Ping loop
CreateThread(function()
  while true do
    Wait(math.max(250, (Config.Tracker.pingIntervalSeconds * 1000)))

    if not Config.Tracker.enabled then
      goto continue
    end

    local tNow = now()

    for id, tr in pairs(Active.trackers) do
      if tr.expiresAt <= tNow then
        -- expire
        Active.trackers[id] = nil
        TriggerClientEvent('gs-drone:client:trackerExpired', -1, { trackerId = id })
        local owner = tr.owner
        if owner then
          Active.trackerByOwner[owner] = math.max(0, (Active.trackerByOwner[owner] or 1) - 1)
        end
      else
        local owner = tr.owner
        if owner and tonumber(owner) and GetPlayerName(tostring(owner)) then
          TriggerClientEvent('gs-drone:client:trackerPing', owner, {
            trackerId = id,
            targetType = tr.targetType,
            targetNet = tr.targetNet,
            targetServerId = tr.targetServerId,
            origin = tr.origin,
            expiresAt = tr.expiresAt,
            blip = Config.Tracker.blip,
            show3D = Config.Tracker.show3DMarkerForViewers,
          })
        end

        for _, plyId in ipairs(GetPlayers()) do
          local v = tonumber(plyId)
          if v and canViewTracker(v) then
            TriggerClientEvent('gs-drone:client:trackerPing', v, {
              trackerId = id,
              targetType = tr.targetType,
              targetNet = tr.targetNet,
              targetServerId = tr.targetServerId,
              origin = tr.origin,
              expiresAt = tr.expiresAt,
              blip = Config.Tracker.blip,
              show3D = Config.Tracker.show3DMarkerForViewers,
            })
          end
        end
      end
    end

    ::continue::
  end
end)


if Config.Tracker.counterplay and Config.Tracker.counterplay.enabled then
  RegisterCommand(Config.Tracker.counterplay.removeCommand or 'removeTracker', function(source)
    local src = source
    if not src or src == 0 then return end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local net = NetworkGetNetworkIdFromEntity(ped)
    local removed = removeTrackersByTarget('ped', net)
    if removed > 0 then
      GS.Notify(src, ('Removed %s tracker(s).'):format(removed), 'success')
    else
      GS.Notify(src, 'No tracker found on you.', 'error')
    end
  end, false)

  CreateThread(function()
    if QBCore and Config.Tracker.counterplay.removerItem then
      QBCore.Functions.CreateUseableItem(Config.Tracker.counterplay.removerItem, function(source)
        local src = source
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then return end
        local net = NetworkGetNetworkIdFromEntity(ped)
        local removed = removeTrackersByTarget('ped', net)
        if removed > 0 then
          GS.Notify(src, ('Removed %s tracker(s).'):format(removed), 'success')
        else
          GS.Notify(src, 'No tracker found on you.', 'error')
        end
      end)
    end
  end)

  RegisterNetEvent('gs-drone:server:decayTracker', function(trackerId, secondsToReduce)
    local src = source
    if type(trackerId) ~= 'string' then return end
    secondsToReduce = tonumber(secondsToReduce or 0) or 0
    if secondsToReduce <= 0 then return end
    secondsToReduce = math.min(10.0, secondsToReduce) -- clamp per call

    local tr = Active.trackers[trackerId]
    if not tr or tr.targetType ~= 'ped' then return end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local net = NetworkGetNetworkIdFromEntity(ped)

    if tr.targetNet ~= net then return end

    tr.expiresAt = math.max(now(), tr.expiresAt - secondsToReduce)
    if tr.expiresAt <= now() then
      removeTrackerId(trackerId)
    end
  end)
end

AddEventHandler('playerDropped', function()
  local src = source
  Active.drone[src] = nil
  Active.cooldown[src] = nil
  Active.trackerCd[src] = nil
  Active.trackerByOwner[src] = nil

  -- remove trackers owned by player
  for id, tr in pairs(Active.trackers) do
    if tr.owner == src then
      Active.trackers[id] = nil
    end
  end
end)


RegisterNetEvent('gs-drone:server:removeVehicleTrackers', function(vehicleNet)
  local src = source
  if not (Config.Tracker and Config.Tracker.counterplay and Config.Tracker.counterplay.enabled) then return end
  local vr = Config.Tracker.counterplay.vehicleRemoval
  if not (vr and vr.enabled) then return end

  vehicleNet = tonumber(vehicleNet or 0) or 0
  if vehicleNet <= 0 then return end

  local ped = GetPlayerPed(src)
  if not ped or ped == 0 then return end

  local veh = GetVehiclePedIsIn(ped, false)
  if not veh or veh == 0 then
    GS.Notify(src, 'You must be inside the tracked vehicle.', 'error')
    return
  end

  -- Must be driver
  if GetPedInVehicleSeat(veh, -1) ~= ped then
    GS.Notify(src, 'You must be the driver to remove a tracker.', 'error')
    return
  end

  local netCheck = NetworkGetNetworkIdFromEntity(veh)
  if netCheck ~= vehicleNet then
    return
  end

  if vr.requireJob then
    local job = getJob(src)
    if not job or not vr.jobs or not vr.jobs[job] then
      GS.Notify(src, 'You are not allowed to remove trackers here.', 'error')
      return
    end
  end

  -- Must be within a configured zone
  local zones = vr.zones or {}
  if #zones == 0 then
    GS.Notify(src, 'No tracker removal zones configured.', 'error')
    return
  end

  local pcoords = GetEntityCoords(ped)
  local inZone = false
  for _, z in ipairs(zones) do
    if z and z.coords and z.radius then
      local d = #(pcoords - z.coords)
      if d <= (z.radius + 0.001) then
        inZone = true
        break
      end
    end
  end

  if not inZone then
    GS.Notify(src, 'You must be at a removal bay.', 'error')
    return
  end

  local removed = removeTrackersByTarget('veh', vehicleNet)
  if removed > 0 then
    GS.Notify(src, ('Removed %s vehicle tracker(s).'):format(removed), 'success')
  else
    GS.Notify(src, 'No tracker found on this vehicle.', 'error')
  end
end)



RegisterNetEvent('gs-drone:server:recallRequest', function()
  local src = source
  if not Active.drone[src] then return end
  TriggerEvent('gs-drone:server:end', 'recall')
end)

RegisterNetEvent('gs-drone:server:placeConfirm', function(payload)
  local src = source
  if not payload or type(payload) ~= 'table' then return end
  if not Active.pendingPlace or not Active.pendingPlace[src] then return end

  Active.pendingPlace[src] = nil

  if not isAllowed(src) then
    GS.Notify(src, 'You are not allowed to use this drone.', 'error')
    return
  end
  if not hasItem(src, Config.Inventory.droneItem) then
    GS.Notify(src, ('Missing item: %s'):format(Config.Inventory.droneItem), 'error')
    return
  end
  if Active.placedByOwner[src] then
    local staleNet = Active.placedByOwner[src]
    local staleOk = false
    if NetworkGetEntityFromNetworkId then
      local ent = NetworkGetEntityFromNetworkId(staleNet)
      if ent and ent ~= 0 then staleOk = true end
    end
    if not staleOk then
      Active.placedByOwner[src] = nil
      if Active.placed then Active.placed[staleNet] = nil end
    else
      GS.Notify(src, 'You already have a drone placed.', 'error')
      return
    end
  end

  local netId = tonumber(payload.netId or 0) or 0
  if netId <= 0 then
    GS.Notify(src, 'Failed to place drone (netId missing).', 'error')
    return
  end

  Active.placed[netId] = { owner = src, createdAt = now(), inUse = false }
  Active.placedByOwner[src] = netId

  removeItem(src, Config.Inventory.droneItem, 1)

  TriggerClientEvent('gs-drone:client:placed', src, { netId = netId })
  GS.Notify(src, 'Drone placed. Target it to connect.', 'success')
end)

RegisterNetEvent('gs-drone:server:packDrone', function(netId)
  local src = source
  netId = tonumber(netId or 0) or 0
  if netId <= 0 then return end

  if Active.placedByOwner and Active.placedByOwner[src] and (not Active.placed or not Active.placed[netId]) then
    netId = Active.placedByOwner[src]
  end

  if Active.placedByOwner and Active.placedByOwner[src] and (not Active.placed or not Active.placed[netId]) then
    netId = Active.placedByOwner[src]
  end

  local rec = Active.placed and Active.placed[netId]
  if not rec then return end
  if rec.owner ~= src then
    GS.Notify(src, 'You do not own this drone.', 'error')
    return
  end
  if rec.inUse then
    GS.Notify(src, 'Drone is currently in use.', 'error')
    return
  end  TriggerClientEvent('gs-drone:client:deletePlaced', src, netId)

  Active.placed[netId] = nil
  Active.placedByOwner[src] = nil

  addItem(src, Config.Inventory.droneItem, 1)
  GS.Notify(src, 'Drone packed.', 'success')
end)

RegisterNetEvent('gs-drone:server:connectPlaced', function(netId)
  local src = source
  netId = tonumber(netId or 0) or 0
  if netId <= 0 then return end

  if not isAllowed(src) then
    GS.Notify(src, 'You are not allowed to use this drone.', 'error')
    return
  end

  local rec = Active.placed and Active.placed[netId]
  if not rec then
    GS.Notify(src, 'Drone not found.', 'error')
    return
  end
  if rec.owner ~= src then
    GS.Notify(src, 'You do not own this drone.', 'error')
    return
  end
  if rec.inUse then
    GS.Notify(src, 'Drone already in use.', 'error')
    return
  end
  if Active.drone[src] then
    GS.Notify(src, 'Drone already active.', 'error')
    return
  end

  rec.inUse = true
  Active.drone[src] = {
    startedAt = now(),
    battery = Config.Drone.batterySeconds,
    netId = netId,
    rangeOverAt = 0,
    placed = true,
  }

  TriggerClientEvent('gs-drone:client:start', src, { battery = Active.drone[src].battery, netId = netId })
end)
