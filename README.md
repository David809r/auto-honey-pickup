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
    Debug = false,
}

loadstring(game:HttpGet("https://raw.githubusercontent.com/David809r/auto-honey-pickup/main/autohoneypickup.lua"))()
```
