# Auto Honey Pickup

Roblox client script for the Bee event. It detects live Honey pickups, uses a grapple-first carpet glide to collect them, and includes a compact control panel with a manual teleport tester.

## Loadstring

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/David809r/auto-honey-pickup/main/autohoneypickup.lua"))()
```
Your client must support `loadstring` and `game:HttpGet`.

## Features

- Detects the Bee event's live `Honey` models by their hidden claim prompt.
- Detects whether the Bee event is active from the controller's hive state, with live event models and the bottom-right Bee icon as fallbacks. The UI header shows `ACTIVE`, `INACTIVE`, or `CHECKING`.
- Fires the Grapple Hook, equips a supported carpet, and glides at a default speed of 150.
- Prevents teleport ragdolls, cancels rotational fling, clamps abnormal launch speed, and forces the humanoid back up after arrival.
- Precomputes a multi-wall grid route, checks every player-width segment, and follows it around structures instead of pushing through them. Unsafe routes are rejected.
- Automatically stops within the game's 12-stud claim range.
- Includes automation controls, live status, speed editing, and a click-to-select teleport test.
- While the Bee event is confirmed active, finds the lowest-population non-full public server and hops after all available Honey has been handled. It never hops while the event is inactive or still being confirmed.
- Carries a short visited-server list through teleport data and re-queues the loadstring when the executor supports it.
- Cleans up an older running copy when executed again.

## Test teleport

1. Click **SELECT WORLD POINT**.
2. Click a visible surface in the world.
3. Click **RUN GRAPPLE TP**.

The test temporarily takes movement control, runs the grapple/carpet sequence, and then returns control to automation. It uses the same wall detection and precomputed waypoint routing as automatic Honey pickup, so selecting a point behind a structure tests the real obstacle-avoidance behavior.

## Configuration

Set options before loading the script:

```lua
_G.AutoHoneyPickupConfig = {
    Enabled = true,
    ArrivalDistance = 4.5,
    TestArrivalDistance = 5,
    CarpetSpeed = 150,
    UseGrapple = true,
    AntiRagdoll = true,
    AntiRagdollRecoverySeconds = 0.6,
    AntiFlingSpeedLimit = 220,
    UsePathfinding = true,
    PathAgentRadius = 4,
    PathWaypointReach = 1.5,
    PathGridSize = 8,
    PathGridMargin = 80,
    PathMaxGridNodes = 6000,
    PathStallSeconds = 1.75,
    ServerHopEnabled = true,
    ServerHopStartDelay = 5,
    ServerHopIdleSeconds = 2,
    BeeEventCheckInterval = 0.5,
    Debug = false,
}

loadstring(game:HttpGet("https://raw.githubusercontent.com/David809r/auto-honey-pickup/main/autohoneypickup.lua"))()
```

Honey movement stops at the configured arrival distance, capped at 6 studs and at half of the pickup prompt's range. With the default settings, the character stops about 4.5 studs from the Honey instead of near the 12-stud claim boundary.

The fast hopper waits 5 seconds on a fresh loaded server so the Bee controller can restore its state. Its countdown only runs while the UI reports `BEE EVENT: ACTIVE`; an inactive or unconfirmed event keeps the hopper waiting in the current server. After Honey is detected, it waits for 2 seconds with no available pickup before choosing another server. Failed hops retry after 3 seconds. If Roblox blocks the public server-list response, the script falls back to normal public matchmaking instead of getting stuck. Teleports must be tested in the Roblox application; Roblox Studio playtesting does not support `TeleportService`.
