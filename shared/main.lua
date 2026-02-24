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

  Active.drone[src] = {
    startedAt = now(),
    battery = Config.Drone.batterySeconds,
    netId = 0,
    rangeOverAt = 0,
  }

  TriggerClientEvent('gs-drone:client:start', src, {
    battery = Active.drone[src].battery,
  })
end)

RegisterNetEvent('gs-drone:server:registerDrone', function(netId)
  local src = source
  if not Active.drone[src] then return end
  Active.drone[src].netId = netId
end)

RegisterNetEvent('gs-drone:server:end', function(reason)
  local src = source
  if Active.drone[src] then
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
    expiresAt = now() + Config.Tracker.durationSeconds,
  }
  Active.trackerByOwner[src] = owned + 1

  TriggerClientEvent('gs-drone:client:trackerStatus', src, { cooldown = Config.Tracker.cooldownSeconds })
  GS.Notify(src, 'Tracker dart attached.', 'success')
end)

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
        local owner = tr.owner
        if owner then
          Active.trackerByOwner[owner] = math.max(0, (Active.trackerByOwner[owner] or 1) - 1)
        end
      else
        -- send ping to eligible viewers
        for _, plyId in ipairs(GetPlayers()) do
          local v = tonumber(plyId)
          if v and canViewTracker(v) then
            TriggerClientEvent('gs-drone:client:trackerPing', v, {
              trackerId = id,
              targetType = tr.targetType,
              targetNet = tr.targetNet,
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