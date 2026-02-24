Config = {}

-- Framework & inventory settings
Config.Framework = {
  mode = 'auto', -- 'auto' | 'qb' | 'qbox'
}

Config.Inventory = {
  mode = 'auto', -- 'auto' | 'ox_inventory' | 'qb-inventory'
  droneItem = 'pd_drone',
}

Config.General = {
  allowAll = false,
  allowedJobs = { -- if allowAll = false
    police = true,
    sheriff = true,
  },

  maxActiveDronesPerPlayer = 1,
  droneCooldownSeconds = 10,

  recallMode = 'despawn', -- 'despawn' | 'return' (return = fly back visually, still despawns at end)
}

Config.Drone = {
  model = `ch_prop_casino_drone_02a`, -- change if desired
  spawnOffset = vec3(1.5, 1.0, 0.2),

  maxSpeed = 16.0, 
  accel = 16.0, 
  brake = 12.0, 

  verticalSpeed = 9.0, -- Up/Down speed (increase for faster altitude changes)
  climbSpeed = 9.0, -- alias (used for Space/Ctrl climb rate)

  maxAltitude = 120.0,
  maxRange = 350.0,
  rangeGraceSeconds = 6, -- how long you can exceed range before forced end

  batterySeconds = 180,
  batteryDrainPerSecond = 1.0, -- base drain per second
  batteryDrainMovingMult = 1.35, -- extra drain multiplier while moving
  batteryDrainSpotlightMult = 1.15,
  batteryDrainThermalMult = 1.15,

  canBeShotDown = true,
  damageMultiplier = 3.0, -- only used if canBeShotDown=true
  invincibleIfDisabled = true, -- if canBeShotDown=false

  -- Shot-down polish
  destroyedFallSeconds = 2.5,      -- how long we let it “fall” before ending drone mode
  destroyedSmokeFx = true,
  destroyedSmokeAsset = 'core',
  destroyedSmokeName = 'ent_amb_smoke', -- safe generic smoke
  destroyedSparksFx = true,
  destroyedSparksAsset = 'core',
  destroyedSparksName = 'ent_sht_electrical_box',
}

Config.Camera = {
  fovMin = 25.0,
  fovMax = 80.0,
  fovStep = 3.0,

  enableThermal = true,
  enableNightVision = false, -- optional extra
  thermalSeeThrough = true, -- enables heat highlighting
  thermalSeeThroughFadeStart = 18.0, -- meters
  thermalSeeThroughFadeEnd   = 65.0, -- meters
  thermalSeeThroughHighlightIntensity = 0.28, -- 0.0 - 1.0
  thermalSeeThroughNoiseMin = 0.0,
  thermalSeeThroughNoiseMax = 0.0,
  thermalIntensity = 1.0, -- (future tuning hook)

  -- Visual polish
  thermalTimecycle = 'heliGunCam', -- 'heliGunCam' feels like police cam. Set nil/false to disable.
  thermalTimecycleStrength = 0.8,  -- 0.0 - 1.0
  nightVisionTimecycle = nil,      -- e.g. 'MP_corona_tint'
}


Config.Mouse = {
  enableLook = true,
  enableSteer = true,
  lookSensitivity = 2.2,      -- camera look speed
  pitchLimit = 55.0,          -- degrees
  steerFollow = 0.10,         -- how much drone yaw follows camera yaw (0-1 per frame with dt)
  steerMaxRate = 95.0,        -- deg/sec clamp
  steerOnlyWhileMoving = false, -- prevents constant yaw hunting/spin
  cameraOffset = vec3(0.0, 0.0, 0.25), -- relative position from drone
}
Config.Spotlight = {
  enabled = true,
  brightness = 12.0,
  radius = 25.0,
  distance = 45.0,
  falloff = 15.0,
  cone = 25.0, 
}


-- Boot / startup sequence when connecting to a drone
Config.Boot = {
  enabled = true,
  seconds = 2.2, -- time to "boot" before control is enabled
  allowCancel = false,
}

-- Operator animation while controlling the drone
Config.OperatorAnim = {
  enabled = true,
  dict = 'amb@world_human_stand_mobile@male@text@base',
  name = 'base',
}

Config.Tracker = {
  maxDistance = 1200.0, -- meters from dart origin before tracking is lost

  tracerStyle = 'electric', -- 'electric'|'line'

  pdJobs = { 'police', 'sheriff', 'state', 'trooper' },
  blipRefresh = 250,

  enabled = true,

  restrictToJobs = false, -- if true, only jobs listed below can shoot tracker
  allowedJobs = { police = true, sheriff = true },

  maxActivePerPlayer = 2,
  cooldownSeconds = 5,

  durationSeconds = 45,
  pingIntervalSeconds = 3,
  maxPingRange = 1500.0, -- only pings if target is within this distance to the shooter

  show3DMarkerForViewers = false,
  viewers = {
    jobs = { police = true, sheriff = true },
    ace = nil, 
  },

  blip = {
    sprite = 161,
    color = 1,
    scale = 0.85,
    shortRange = false,
  },

  counterplay = {
    enabled = true,

    -- Optional self-removal item/command (ped trackers)
    removerItem = 'tracker_remover',
    removeCommand = 'removeTracker',

    -- Vehicle tracker removal zones (PD-only by config below)
    vehicleRemoval = {
      enabled = true,

      -- If true, only jobs listed in `jobs` can remove vehicle trackers
      requireJob = true,
      jobs = { police = true, sheriff = true },

      zones = {
        -- Add your bay coords here:
        -- { coords = vec3(123.4, 456.7, 78.9), radius = 5.0 },
      }
    },

    environmentDecay = {
      enabled = true,
      rainReducesDuration = true,
      waterReducesDuration = true,

      -- How much time to “burn off” per second while in rain/water
      rainDecayPerSecond = 0.5,  -- 0.5 means a 45s tracker lasts ~30s in heavy rain
      waterDecayPerSecond = 1.5, -- water eats it fast

      -- Check interval (seconds) on the TARGET client
      checkIntervalSeconds = 2,
    },
  },

}

Config.Keybinds = {
  forward = 'W',
  back = 'S',
  left = 'A',
  right = 'D',
  ascend = 'SPACE',
  descend = 'LCONTROL',
  yawLeft = 'Q',
  yawRight = 'E',

  spotlight = 'F',
  thermal = 'T',
  ping = 'G',
  tracker = 'H',
  recall = 'R',
  exit = 'BACK',
}

Config.UI = {
  enabled = true,
  theme = {
    primary = '#38BDF8',
    accent = '#FBBF24',
    logoUrl = 'logo.png', 
  },
  showHints = true,
}

Config.Notifications = {
  mode = 'auto', -- 'auto' | 'ox_lib' | 'qb' | 'print'
}