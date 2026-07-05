-- ─────────────────────────────────────────────────────────────
-- Framework bridge
-- Auto-detects QBox (qbx_core) or QBCore (qb-core) and exposes ONE API
-- so the rest of the resource never branches on framework.
--
-- If a function behaves differently on your build, this file is the only
-- place you need to touch.
-- ─────────────────────────────────────────────────────────────
Framework = { name = nil, core = nil }

if GetResourceState('qbx_core') == 'started' then
    Framework.name = 'qbox'
elseif GetResourceState('qb-core') == 'started' then
    Framework.name = 'qbcore'
    Framework.core = exports['qb-core']:GetCoreObject()
else
    -- Defer the error so the resource still loads its UI; log loudly.
    print('^1[cipher-drone]^0 No supported framework found. Start qbx_core or qb-core before cipher-drone.')
end

local IS_SERVER = IsDuplicityVersion()

-- ── Player lookups ──────────────────────────────────────────
if IS_SERVER then
    -- Returns the framework player object for a source, or nil.
    function Framework.GetPlayer(src)
        if Framework.name == 'qbox' then
            return exports.qbx_core:GetPlayer(src)
        else
            return Framework.core.Functions.GetPlayer(src)
        end
    end

    -- Returns the player's job name, or nil.
    function Framework.GetJob(src)
        local player = Framework.GetPlayer(src)
        if player and player.PlayerData and player.PlayerData.job then
            return player.PlayerData.job.name
        end
        local st = Player(src).state
        if st and st.job and st.job.name then return st.job.name end
        if st and st.job then return st.job end
        return nil
    end

    -- Registers a useable inventory item across both frameworks.
    function Framework.CreateUseableItem(itemName, cb)
        if Framework.name == 'qbcore' and Framework.core then
            Framework.core.Functions.CreateUseableItem(itemName, cb)
        end
        -- qbox items are registered via ox_inventory's item definitions;
        -- usable-item callbacks there are wired up separately by the
        -- server owner if they want a `usetime`/client event on the item.
    end

    -- Server-side notify (wraps ox_lib if present, falls back to
    -- framework-native notify events so this still works without ox_lib).
    function Framework.Notify(src, msg, type)
        if GetResourceState('ox_lib') == 'started' then
            TriggerClientEvent('ox_lib:notify', src, { description = msg, type = type or 'inform' })
            return
        end
        if Framework.name == 'qbox' then
            TriggerClientEvent('qbx_core:notify', src, msg, type or 'inform')
        elseif Framework.core then
            TriggerClientEvent('QBCore:Notify', src, msg, type or 'inform')
        else
            print(('[cipher-drone] %s'):format(msg))
        end
    end
else
    -- ── Client ──────────────────────────────────────────────
    function Framework.GetPlayerData()
        if Framework.name == 'qbox' then
            return exports.qbx_core:GetPlayerData()
        elseif Framework.core then
            return Framework.core.Functions.GetPlayerData()
        end
        return nil
    end

    function Framework.GetJob()
        local data = Framework.GetPlayerData()
        return data and data.job and data.job.name or nil
    end

    function Framework.HasOxLib()
        if GetResourceState('ox_lib') ~= 'started' then return false end
        return type(lib) == 'table'
    end

    function Framework.Notify(msg, type)
        if Framework.HasOxLib() then
            lib.notify({ description = msg, type = type or 'inform' })
            return
        end
        if Framework.name == 'qbox' then
            TriggerEvent('qbx_core:notify', msg, type or 'inform')
        elseif Framework.core then
            TriggerEvent('QBCore:Notify', msg, type or 'inform')
        else
            print(('[cipher-drone] %s'):format(msg))
        end
    end
end

if Config and Config.Debug then
    print(('^2[cipher-drone]^0 bridge loaded (%s) on %s'):format(
        Framework.name or 'none', IS_SERVER and 'server' or 'client'))
end
