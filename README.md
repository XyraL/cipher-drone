# GS-DroneSystem

A fully deployable police drone system for QBox / QB-Core servers.

## Features

-   Physical placed drone (no instant spawn flying)
-   Target-to-connect interaction
-   Cinematic startup boot sequence
-   Smooth mouse-controlled flight
-   Configurable speed and acceleration
-   Adjustable vertical speed
-   Spotlight & thermal modes
-   Tracker dart system with route ping
-   Minimap follows drone
-   Battery system
-   Job restrictions (PD only configurable)
-   ox_inventory / qb-inventory support

## Requirements

-   QBox or QB-Core
-   ox_inventory or qb-inventory
-   ox_lib (optional but recommended)

## Configuration

All settings are inside `config.lua`.

### Speed Tuning

    Config.Drone.maxSpeed
    Config.Drone.accel
    Config.Drone.brake
    Config.Drone.verticalSpeed

### Job Restriction

    Config.General.allowAll = false
    Config.General.allowedJobs = {
        police = true,
        sheriff = true
    }

### Thermal Settings

    Config.Camera.thermalSeeThrough
    Config.Camera.thermalSeeThroughFadeStart
    Config.Camera.thermalSeeThroughFadeEnd
    Config.Camera.thermalSeeThroughHighlightIntensity

## Installation

1.  Drag `GS-DroneSystem` into your resources folder
2.  Add `ensure GS-DroneSystem` to server.cfg
3.  Add the drone item to your inventory system (item name: pd_drone)
4.  Restart server

## Notes

-   Only allowed jobs can use the drone when `allowAll` is false.
-   Vertical speed is now configurable.
-   Thermal highlighting has fade distance to reduce full-building x-ray
    effect.
