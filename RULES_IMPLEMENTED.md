
# Sentinel Project Rules (Implemented Behavior)

This document describes the current implemented rules in this build, based on the active scripts.

## 1. Controls

- `Space`: Toggle crosshair/build mode visibility.
- `T`: Place Tree (if valid target and enough energy).
- `B`: Place Boulder (if valid target and enough energy).
- `R`: Place Robot (if valid target and enough energy).
- `Q`: Transfer into another robot.
- `A`: Remove object (using removal rules below).
- `D`: Toggle debug HUD text.
- `Esc`: Toggle mouse capture.
- `Left Mouse`: Re-capture mouse while in visible mode.

## 2. Object Energy Values

- Tree = 1
- Boulder = 2
- Robot = 3
- Sentry = 4
- Sentinel = 4
- Meanie = 1

## 3. Player Energy Economy

- Player starts with `100` energy (`starting_energy`).
- Top HUD displays current energy: `Energy: N`.
- Placement costs:
  - Tree costs 1
  - Boulder costs 2
  - Robot costs 3
- Placement is blocked if energy would go below `0`.
- Removing objects refunds energy by that object's value.

## 4. Loss Condition

- Game over occurs when player energy reaches `-1` (or lower).
- `0` energy is still alive.
- While game over, warning UI shows `GAME OVER` and player input does nothing.

## 5. Placement Rules

- Objects can be placed on valid flat terrain squares (surface normal dot up >= 0.98).
- Objects can be placed on top of a boulder (stack level 1) if that boulder has no stacked object yet.
- One base object per square.
- Placement creates build objects under `BuildObjects` in the current scene.

## 6. Removal Rules

- Objects can be removed if it has no stacked object on top of it.
- Boulders can be removed by aiming at the bolder itself.
- Objects other than boulders can be removed by aiming at the square surface (terrain/ground body) they stand on.
- Stacked objects can be removed by aiming at the boulder that the object is stacked on top of.
- Active player robot cannot be removed.
- Removal refunds energy based on removed object kind.

## 7. Initial Player Host Robot

- On start, if no robot exists on the player’s current square, a robot is created there and becomes the active robot.
- Transferring (`Q`) moves the player to another robot and sets it as active.

## 8. Watcher Types

- Sentinel and Sentries use watcher AI (scan, detect, absorb behavior).
- Meanies are watcher-like hostile units created from Trees.

## 9. Watcher Scanning and Visibility

Each watcher:
- Uses range and forward-cone checks.
- Uses line-of-sight ray checks.
- Reports two states about player:
  - `sees_player`
  - `sees_square` (whether the player's current square is visible)
- Contact data is stale after 0.7 seconds without updates.

## 10. Warning Indicator (Top HUD)

- If player is seen, warning appears.
- If player and square are seen:
  - alert bar fills toward lock (5-second lock window).
- If player is seen but square is not:
  - warning shows partial/specked-style alert state.

## 11. Player Drain by Watchers

When player is seen and player square is also seen:
- A 5-second lock timer runs.
- After lock, player loses 1 energy every 5 seconds.
- Each drained unit spawns one random Tree on a valid free horizontal square.
- Drain can continue through 0 and ends game at -1.

## 12. World Absorption by Watchers

Sentinel/Sentries absorb world objects in discrete steps under visibility rules.

### 12.1 Timing

- Absorption is limited to one degradation step every 5 seconds per watcher.
- The first absorption is delayed by 5 seconds.

### 12.2 Valid Absorption Targets

Primary target classes:
- Robot (excluding the active player robot)
- Boulder
- Tree (if it is stacked on top of a boulder)

Stack behavior:
- Target selection walks upward from a base boulder to the topmost stacked object.
- Degradation proceeds top to bottom, one step at a time.

### 12.3 Visibility Rule for Stacked Targets

A stacked target can be absorbed if watcher has line-of-sight to:
- if the stacked object is a boulder, then the stacked object itself
- any supporting Boulder in that stack chain.

### 12.4 Degradation Steps

- Robot (3) -> Boulder (2)
- Boulder (2) -> Tree (1)
- Tree (1) -> removed

### 12.5 Placement-Safety Constraint

- Degradation output is normalized so objects are never left stacked on invalid supports.
- Stacked output remains stacked only when support is a valid Boulder; otherwise output is forced to ground level.

### 12.6 Energy Redistribution

- For each watcher absorption step, one random Tree is spawned on a valid free horizontal square.

## 13. Partial-Lock Meanie Rule

If a watcher sees the player but cannot see the player's square:
- It prioritizes creating a Meanie instead of normal absorb action.
- It searches for nearby Trees around the player that it can see the square that the tree is standing on, and converts one to a Meanie.
- A per-watcher cooldown limits repeated meanie creation.

## 14. Meanies

- Created by converting a Tree.
- Value: 1 energy.
- Use watcher behaviors with faster cadence than normal sentries (per sentinel script parameters).
- Can be removed by the same square-based removal method as other base objects.
- Removing them refunds 1 energy.

## 15. Random Tree Spawning

- Random trees spawn on any free square in a 31x31 grid (0..30 indices) when triggered by drain/absorb.
