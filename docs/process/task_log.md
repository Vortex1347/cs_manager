# Task Log

## 2026-04-23

- Replaced the symmetric `box_map` with a Dust2-inspired top-down layout and semantic tactical markers.
- Added `BombController` and moved bomb state/timers out of `Bombsite`.
- Reworked `BotTeam` into a real strategy/role/route planner.
- Reworked `BotBrain` to execute role intents and objective actions on top of route following.
- Wired HUD strategy buttons to the T-side round plan.
- Disabled `rl_training_mode` by default in the main game scene so ordinary runtime uses deterministic logic.
- Verified the project parses and runs headless without script errors after the refactor.
- Added structured `BotLoadout`-based buy logic and moved purchase choice to `BotTeam.assign_buy_plan()`.
- Added authored grenade lineups, utility packages, and physical throw execution for smoke/flash/frag.
- Expanded bot runtime debug labels and HUD observability for plans, utility calls, and lineup-marker visibility.
- Verified the project boots headless after the sandbox utility/buy refactor.
- Added a Phase 3 combat layer: `CombatDirective`, slot reservation, trade pairs, post-plant/retake combat assignments, and lane-based hold profiles.
- Reworked `BotBrain` micro around authored angle holding, shoulder/jiggle peeks, trade swings, fallback holds, and short-lived heard intel.
- Reworked `GameManager` into the combat-intel router for footsteps, gunshots, grenade pops, bomb events, and death-triggered trade calls.
- Expanded HUD/debug surface with combat summary, intel summary, combat-slot debug toggle, and richer per-bot combat labels.
- Verified clean headless parse plus a 22-second headless runtime smoke without new gameplay script errors.
- Expanded HUD again with compact per-team roster panels that expose live per-bot summaries for manual tuning without relying only on floating 3D labels.
- Added Phase 4 gunplay polish: `Weapon` is now stateful and tracks movement penalty, burst pressure, recovery, range profile, and weapon-specific firing behavior.
- Reworked `BotBrain` gunfights to choose `tap / burst / spray_commit / awp_hold`, stabilize before key shots, and adapt peek behavior to weapon and distance.
- Extended combat directives with gunfight hints like preferred fire mode, engagement profile hint, stabilize window, counter-strafe window, and commit window.
- Expanded HUD/roster observability with gunfight summaries, stabilization state, accuracy pressure, and weapon debug state.
- Verified clean headless parse plus a 24-second headless runtime smoke after the gunplay refactor.
- Rebuilt the map layer around a gameplay-faithful top-down Dust2 callout model generated from `TacticalMap` instead of the old static Dust2-inspired blockout.
- Removed ordinary runtime dependence on navmesh baking by moving bot movement onto the authored tactical path graph and turning `nav_baker.gd` into legacy no-op compatibility.
- Reworked T/CT round plans to be site-aware around real Dust2 lanes (`A Long`, `Short`, `Mid`, `B Tunnels`, `B Window`) and added alternating default A/B pressure instead of a single repeated default lane pattern.
- Tightened bomb-centric behavior with explicit fallback carrier logic, improved recover-bomb assignments, stronger post-plant/retake plans, and late-round CT save thresholds.
- Replaced the default HUD with a compact icon-first overlay and moved verbose bot panels plus rich debug summaries behind observer mode.
- Verified clean headless parse and a 22-second headless runtime smoke after the Dust2/bomb-first/performance rebuild.
- Rebuilt `TacticalMap` again into a closer Dust2 callout pass with `Long Doors`, `Outside Long`, `Blue`, `Suicide`, `Top Mid`, `B Door`, per-site plant slots, retake lanes, and bomb cover packages.
- Reworked `BotTeam` around explicit duty packages and bomb tasks so T/CT planners now issue `site_target`, `lane_target`, `bomb_task`, and site-aware post-plant/retake assignments instead of only route-plus-intent orders.
- Extended `BotBrain` with `assign_duty_package()`, `update_bomb_task()`, bomb-task gate rules for plant/defuse/recover, and compact/verbose status summaries for the lighter HUD and observer mode.
- Replaced the compact HUD emoji text with a minimal drawn icon system (`hud_icon.gd`) and throttled HUD/observer refreshes in `GameManager` to reduce update load.
- Verified clean headless parse and another 22-second headless runtime smoke after the exact Dust2 plus duty-package recovery pass.
