# Cipher — Drone (v2.0)

A deployable police drone resource for **QBox (qbx_core)** and **QBCore (qb-core)**.
Place a physical drone, target it to connect, and fly it with smooth
mouse-controlled flight — spotlight, thermal, and a tracker dart system with
live pings for the rest of PD. Criminal-side counterplay is built in: darts
can be removed or decayed by rain/water, drones can be shot down, and a
deployable jammer degrades a nearby operator's control instead of just
killing the feed outright.

## Features

- Physical placed drone (no instant spawn flying) with target-to-connect / pack interactions
- Tactical NUI HUD: angular panels, scanline texture, corner-bracket screen framing, segmented meter bars
- Cinematic NUI boot/uplink sequence with a progress bar and scrolling system-check log
- Reactive lock-on reticle (brackets close in and turn red when aimed at a valid tracker target) and a heading-up mini-radar showing active tracker pings relative to the drone
- Heading compass strip
- Smooth mouse-controlled flight, independent camera look from drone yaw
- Configurable speed, acceleration, altitude, and range with a grace period
- Spotlight & thermal modes (tuned see-through fade so it's not a full-building x-ray)
- Tracker dart system: route ping, PD-wide live tracking, rain/water decay, vehicle-bay removal zones
- **Shoot-down**: drones take real damage and have a scripted destroy sequence (fall, smoke, sparks)
- **Jamming**: a criminal-side deployable that degrades a nearby operator's control (jitter/drift), not a hard kill
- Minimap follows drone, battery system, job restrictions
- ox_inventory / qb-inventory support

## Requirements

- QBox (`qbx_core`) or QBCore (`qb-core`) — auto-detected by `bridge/framework.lua`
- ox_inventory or qb-inventory
- ox_lib (optional but recommended — keybinds and the `[E]` interaction prompts fall back to native FiveM equivalents without it)

## Install

1. Drop the `cipher-drone` folder into your `resources`.
2. Add `ensure cipher-drone` to your `server.cfg`.
3. Add the drone item to your inventory system — item name is `pd_drone` (kept as-is from the original release for compatibility with existing inventory configs, not renamed to a `cipher_`-prefixed name).
4. If you're using the jamming system, also add the `cipher_jammer` consumable item to your inventory config.
5. Tune `config.lua` — see the callout below before you go live.
6. Restart the resource.

## Configuration

All settings are in `config.lua`.

### Job restriction

    Config.General.allowAll = false
    Config.General.allowedJobs = {
        police = true,
        sheriff = true,
    }

### Shoot-down

    Config.Drone.canBeShotDown = true
    Config.Drone.baseHealth = 200
    Config.Drone.damageMultiplier = 3.0  -- effective HP = baseHealth / damageMultiplier
    Config.Drone.destroyedFallSeconds = 2.5
    Config.Drone.destroyedSmokeFx / destroyedSparksFx

Set `canBeShotDown = false` to make the drone immune to gunfire instead
(`invincibleIfDisabled` controls that case).

### Jamming

    Config.Jamming.enabled = true
    Config.Jamming.item = 'cipher_jammer'
    Config.Jamming.maxDistance = 60.0        -- meters from the jammer to the drone
    Config.Jamming.durationSeconds = 20
    Config.Jamming.cooldownSeconds = 90
    Config.Jamming.intensity = { ... }        -- jitter/drift tuning

The jammer is a fire-and-forget consumable used at the player's current
position — no aiming required. It has no blip visible to the drone
operator; the only feedback the operator gets is the degraded-control
effect and the HUD's JAMMED indicator, by design (stealth is part of the
counterplay).

### Tracker darts

    Config.Tracker.maxDistance = 1200.0   -- meters from the dart's ORIGIN before tracking is lost
    Config.Tracker.durationSeconds = 45
    Config.Tracker.counterplay.removerItem / removeCommand
    Config.Tracker.counterplay.vehicleRemoval.zones

### Thermal

    Config.Camera.thermalSeeThrough
    Config.Camera.thermalSeeThroughFadeStart
    Config.Camera.thermalSeeThroughFadeEnd
    Config.Camera.thermalSeeThroughHighlightIntensity

### HUD

    Config.UI.showCompass = true
    Config.UI.showRadar = true
    Config.UI.radarRange = 300.0   -- meters; tracker blips beyond this clamp to the radar's edge

Turn either off individually if you want a cleaner camera view. The HUD's
tactical monospace font (Share Tech Mono) loads from Google Fonts — it
degrades gracefully to a local monospace font if the client has no internet
access, so it's safe to leave as-is even for offline/LAN setups.

## Before going live

- **QBox + ox_inventory**: qbx_core has no server-side "useable item" registration API (unlike qb-core), so the drone and jammer items won't do anything out of the box. In your ox_inventory item definitions, set `client.event` to `cipher-drone:client:useItem` for the drone item and `cipher-drone:client:useJammerItem` for the jammer item. On qb-core this is automatic via `Framework.CreateUseableItem` — no item config changes needed.
- `Config.Drone.model` is a placeholder prop (`ch_prop_casino_drone_02a`) — verify it spawns correctly on your build, or swap in your own.
- `Config.Tracker.counterplay.vehicleRemoval.zones` ships empty — add your own bay coords or vehicle-tracker removal won't have anywhere to happen.
- Item name `pd_drone` is unchanged from the original release; the new jammer item (`cipher_jammer`) needs adding to your inventory config since it's net-new.
- If you're not running `ox_lib`, keybinds fall back to native `RegisterKeyMapping`/`RegisterCommand` — players can rebind these from the FiveM pause menu keybind settings.

## Notes

- Only allowed jobs can use the drone when `allowAll` is false.
- The tracker's `maxDistance` is measured from the dart's origin, not from
  whoever is currently looking at their map — an officer far from the
  target still sees the blip as long as the target hasn't wandered out of
  range of the dart itself.
- Shoot-down damage is client-reported (the same trust model already used
  for battery/range), consistent with the rest of the resource.
