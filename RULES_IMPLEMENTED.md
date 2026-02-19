# Sentinel Project Rules (Implemented Behavior)

This document describes the **current implemented rules** in the project as of this build.

## 1. Controls

- `Space`: Toggle crosshair/build mode visibility.
- `T`: Place Tree (if valid target and enough energy).
- `B`: Place Boulder (if valid target and enough energy).
- `R`: Place Robot (if valid target and enough energy).
- `Q`: Transfer into another robot.
- `A`: Remove object (using removal rules below).
- `Esc`: Toggle mouse capture.

## 2. Object Energy Values

- Tree = 1
- Boulder = 2
- Robot = 3
- Sentry = 4
- Sentinel = 4
- Meanie = 1

## 3. Player Energy Economy

- Player starts with `4` energy (`starting_energy`).
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
- While game over, warning UI shows `GAME OVER` and gameplay actions are effectively stopped.

## 5. Placement Rules

- Objects can be placed on valid flat terrain squares.
- Objects can be placed on top of a boulder (stack level 1) if that boulder has no stacked object yet.
- One base object per square.

## 6. Removal Rules

- Base-level objects are removed by aiming at the square surface (terrain/ground body) they stand on.
- If object is stacked on a boulder, aim at the boulder to remove stacked object first.
- If no stacked object exists, boulder itself is removed.
- Active player robot cannot be removed.
- Removal refunds energy based on removed object kind.

## 7. Initial Generated Objects

- Initial generated Trees/Robots/Sentries/Sentinel are spawned as removable build objects, using same metadata/group system as placed objects.
- This makes them follow the same removal and energy-refund flow.

## 8. Watcher Types

- Sentinel and Sentries use watcher AI (scan, detect, absorb behavior).
- Meanies are watcher-like hostile units created from Trees.

## 9. Watcher Scanning and Visibility

Each watcher:
- Rotates/scans over time.
- Has range and forward-cone checks.
- Uses line-of-sight ray checks.
- Reports two states about player:
  - `sees_player`
  - `sees_square` (whether the player's current square is visible) 

## 10. Warning Indicator (Top HUD)

- If player is seen, warning appears.
- If player **and square** are seen:
  - alert bar fills toward lock (5-second lock window).
- If player is seen but square is not:
  - warning shows partial/specked-style alert state.

## 11. Player Drain by Watchers

When player is seen and player square is also seen:
- A 5-second lock timer runs.
- After lock, player loses 1 energy every 5 seconds.
- Each drained unit spawns one random Tree somewhere valid on landscape.
- Drain can continue through 0 and ends game at -1.

## 12. World Absorption by Watchers (Classic-style Step Degrade)

Sentinel/Sentries can absorb visible objects with energy > 1.
Target set includes:
- Robot (excluding the active player robot)
- Boulder

Degrade is one energy-step at a time:
- Robot (3) -> Boulder (2)
- Boulder (2) -> Tree (1)

For each absorbed unit, watcher also spawns one random Tree on valid free square (energy redistribution behavior).

## 13. Partial-Lock Meanie Rule

If a watcher sees the player but cannot see the player's square:
- It prioritizes creating a Meanie instead of normal absorb action.
- It searches nearby Trees around the player and converts one to a Meanie.
- A per-watcher cooldown limits repeated meanie creation.

## 14. Meanies

- Created by converting a Tree.
- Value: 1 energy.
- Rotate/scan like watcher units, with faster cadence than normal sentries.
- Can be removed by the same square-based removal method as other base objects.
- Removing them refunds 1 energy.

## 15. Energy Conservation Intent

Implemented behavior redistributes energy by spawning Trees when energy is drained/absorbed.
Object degrade chain and random Tree spawning are active, but exact canonical Sentinel balancing details are approximated for current gameplay implementation.
