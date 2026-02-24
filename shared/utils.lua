GS = GS or {}
GS.Drone = GS.Drone or {}

local function resourceStarted(name)
  return GetResourceState(name) == 'started'
end

GS.HasOxLib = function()
  if GetResourceState('ox_lib') ~= 'started' then return false end
  return type(lib) == 'table'
end
GS.AutoFramework = function()
  if resourceStarted('qbx_core') then return 'qbox' end
  if resourceStarted('qb-core') then return 'qb' end
  return 'standalone'
end

GS.AutoInventory = function()
  if resourceStarted('ox_inventory') then return 'ox_inventory' end
  if resourceStarted('qb-inventory') then return 'qb-inventory' end
  return 'unknown'
end

GS.Notify = function(src, msg, nType)
  nType = nType or 'inform'

  local mode = Config.Notifications.mode
  if mode == 'auto' then
    if GS.HasOxLib() then mode = 'ox_lib'
    elseif GetResourceState('qb-core') == 'started' or GetResourceState('qbx_core') == 'started' then
      mode = 'qb'
    else
      mode = 'print'
    end
  end

  if mode == 'ox_lib' then
    if src == nil then
      lib.notify({ description = msg, type = nType })
    else
      TriggerClientEvent('ox_lib:notify', src, { description = msg, type = nType })
    end
    return
  end

  if mode == 'qb' then
    if src == nil then
      print(('[GS-Drone] %s'):format(msg))
    else
      TriggerClientEvent('QBCore:Notify', src, msg, nType)
      TriggerClientEvent('qbx_core:notify', src, msg, nType) 
    end
    return
  end

  print(('[GS-Drone] %s'):format(msg))
end