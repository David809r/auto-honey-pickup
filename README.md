# Auto Honey Pickup

Roblox client script for the Bee event. It detects live Honey pickups, uses a grapple-first carpet glide to collect them, and includes a compact control panel with a manual teleport tester.

## Loadstring

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/David809r/auto-honey-pickup/main/autohoneypickup.lua"))()
```
Your client must support `loadstring` and `game:HttpGet`.

## Features

- Detects the Bee event's live `Honey` models by their hidden claim prompt.
- Fires the Grapple Hook, equips a supported carpet, and glides at a default speed of 150.
- Automatically stops within the game's 12-stud claim range.
- Includes automation controls, live status, speed editing, and a click-to-select teleport test.
- Finds the lowest-population non-full public server and hops after all available Honey has been handled.
- Carries a short visited-server list through teleport data and re-queues the loadstring when the executor supports it.
- Cleans up an older running copy when executed again.

## Test teleport

1. Click **SELECT WORLD POINT**.
2. Click a visible surface in the world.
3. Click **RUN GRAPPLE TP**.

The test temporarily takes movement control, runs the grapple/carpet sequence, and then returns control to automation.

## Configuration

Set options before loading the script:

```lua
_G.AutoHoneyPickupConfig = {
    Enabled = true,
    CarpetSpeed = 150,
    UseGrapple = true,
    ServerHopEnabled = true,
    ServerHopStartDelay = 3,
    ServerHopIdleSeconds = 2,
    Debug = false,
}

loadstring(game:HttpGet("https://raw.githubusercontent.com/David809r/auto-honey-pickup/main/autohoneypickup.lua"))()
```

The fast hopper waits 3 seconds on a fresh loaded server when no Honey appears. After Honey is detected, it waits for 2 seconds with no available pickup before choosing another server. Failed hops retry after 3 seconds. Teleports must be tested in the Roblox application; Roblox Studio playtesting does not support `TeleportService`.
