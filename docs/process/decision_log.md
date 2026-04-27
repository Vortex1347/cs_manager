# Decision Log

## 2026-04-23 — Deterministic Tactical Core First

- Chosen direction: rule-based team planning plus bot micro FSM.
- Reason: the project needs readable, stable tactical behavior before ML can add value.
- Consequence: RL remains optional and isolated from normal game startup.

## 2026-04-23 — Bomb State Moved To Dedicated Controller

- Chosen direction: `BombController` owns bomb lifecycle; `Bombsite` only validates area membership.
- Reason: plant/defuse/drop/pickup/post-plant logic needs one source of truth shared by teams, HUD, and rounds.
- Consequence: bomb-related reactions are now event-driven and easier to extend.

## 2026-04-23 — Map Uses Semantic Tactical Points

- Chosen direction: named tactical points and route IDs replace numbered patrol loops.
- Reason: strategy switching, post-plant setups, retakes, and rotations need map semantics, not anonymous waypoint rings.
- Consequence: future maps can expose the same semantic API without hardcoding bot behavior per scene.

## 2026-04-23 — Utility Uses Authored Full-Physics Lineups

- Chosen direction: physical grenades use map-authored lineup targets and utility packages instead of a solver.
- Reason: the sandbox needs readable, controllable utility behavior that can be tuned by hand without ML or complex lineup search.
- Consequence: utility behavior is map-specific but debuggable, and bots can execute smoke/flash/frag calls without leaving deterministic runtime.

## 2026-04-23 — Buy Logic Moved To Team-Level Loadout Planning

- Chosen direction: `Economy` returns structured `BotLoadout` objects, while `BotTeam` decides buy profiles and utility priorities.
- Reason: realistic CS-like rounds require coordinated kits, armor, weapon tiers, and grenade distribution by role, not isolated per-bot shopping.
- Consequence: future balance work can tune profiles and grenade allocation without rewriting bot micro logic.

## 2026-04-23 — Combat Uses Authored Directives Instead Of Generic Hold-Scan

- Chosen direction: `BotTeam` assigns per-bot combat directives with reserved cover slots, peek mode, trade partner, fallback route, and lane context.
- Reason: believable CS-like rounds need explicit holds, trade spacing, and post-plant/retake posture; generic route-follow plus idle scanning cannot produce stable crossfires or instant trade reactions.
- Consequence: combat behavior is now explainable and tunable from map metadata, while `BotBrain` stays deterministic and debuggable.

## 2026-04-23 — Audio Intel Is Routed At Match Level

- Chosen direction: `GameManager` routes footsteps, gunshots, grenade pops, and bomb lifecycle sounds to both teams as decaying lane-based intel.
- Reason: heard information needs one shared runtime path so CT rotations, T executes, and trade calls react to the same event stream instead of isolated local heuristics.
- Consequence: future tuning can change confidence/TTL per event class without touching every bot, and HUD/debug can surface the same intel picture teams actually use.

## 2026-04-23 — Manual Tuning Uses HUD Roster Panels, Not Only World Labels

- Chosen direction: keep the 3D bot labels, but also mirror key bot state into compact side HUD roster panels.
- Reason: tuning trade/intel behavior from a top-down sandbox is too slow if the observer must chase floating labels in world space for all 10 bots.
- Consequence: manual balancing can now compare both teams at once from the HUD, while the world labels remain useful for local spatial context.

## 2026-04-23 — Gunplay Polish Builds On Existing Combat Directives

- Chosen direction: keep the current route/combat-slot system and layer stateful weapon behavior plus gunfight hints on top of it.
- Reason: the tactical shell is already readable; the biggest remaining gap in “CS feel” is how duels resolve, not how routes are assigned.
- Consequence: the project now improves shooting, stabilization, burst discipline, and weapon identity without another large geometry or planning rewrite.

## 2026-04-23 — Manual Gunplay Tuning Uses Live Debug, Not Replay Or Autosim

- Chosen direction: expose fire mode, stabilization, accuracy pressure, and weapon state directly in HUD/debug instead of building replay or telemetry infrastructure now.
- Reason: the next iteration needs fast manual feel-tuning, and the sandbox already has enough observability surfaces to support that if the gunfight state is made visible.
- Consequence: tuning remains lightweight and in-match, but future replay/analytics work can build on the now-explicit gunfight state if needed.

## 2026-04-23 — Runtime Navigation Moves To Authored Dust2 Graph

- Chosen direction: stop relying on runtime navmesh baking for ordinary launch and move bot movement onto a callout graph owned by `TacticalMap`.
- Reason: runtime baking and heavy debug overlays were the main visible hitch sources, and the authored Dust2-style sandbox already has semantic lanes that can serve as a stronger movement spine than ad-hoc navmesh rebuilds.
- Consequence: the match boots without bake-related startup work, movement is now aligned with the tactical map model, and future map work must maintain graph connectivity together with routes.

## 2026-04-23 — Default UX Is Icon-First, Observer UX Is Verbose

- Chosen direction: keep the default HUD and world labels compact and icon-first, while moving detailed bot summaries, combat/intel/gunfight text, and full roster panels behind observer mode.
- Reason: the previous always-on text surfaces consumed too much space, hurt readability, and added unnecessary per-frame/update overhead during normal matches.
- Consequence: player-facing runtime is lighter and cleaner, while manual tuning still has access to detailed state when observer mode is toggled on.

## 2026-04-23 — Bomb-First Duties Override Generic Route Persistence

- Chosen direction: make bomb drop/recover, plant, post-plant, retake, and late CT save thresholds drive replanning more aggressively than the previous route package persistence.
- Reason: the round should revolve around the bomb objective; keeping stale routes after carrier death or late planted-site changes produced the “bots walk uselessly and ignore the bomb” failure mode.
- Consequence: T fallback carrier and recover logic, plus CT retake/save posture, now override older lane assignments when bomb state changes.

## 2026-04-23 — Exact Dust2 Pass Uses Callout-Driven Runtime Geometry

- Chosen direction: push `TacticalMap` from a general Dust2-like arena into a closer Dust2 callout layout with `Long Doors`, `Outside Long`, `Blue`, `Suicide`, `Top Mid`, `Mid Doors`, `B Door`, `B Window`, and explicit per-site plant/retake metadata.
- Reason: site-aware AI and bomb-first planning need a map model whose lanes and choke points actually match Dust2 round flow instead of only approximating it.
- Consequence: future planner, utility, and bomb work should use callout/site/lane APIs from `TacticalMap` and keep authored geometry, routes, plant slots, and retake lanes synchronized.

## 2026-04-23 — Planner Emits Duty Packages, Not Only Route Orders

- Chosen direction: `BotTeam` now packages `site_target`, `lane_target`, `role`, `bomb_task`, `utility_package_id`, and `combat_directive` into a duty package for each alive bot.
- Reason: route-only planning was too weak for carrier death, plant cover, anti-defuse, retake-cover, and save/recover decisions because the objective layer had to override movement and combat together.
- Consequence: `BotBrain` now executes duty packages and bomb tasks directly, while route-following remains an implementation detail beneath the objective layer.

## 2026-04-23 — Default HUD Uses Drawn Icons And Throttled Refresh

- Chosen direction: replace compact HUD emoji/text strings with a small drawn icon set and throttle HUD/observer refreshes inside `GameManager`.
- Reason: the prior observer-rich text surfaces still consumed too much space and update budget during live rounds, which worked against the explicit goal of reducing perceived lag in the default match view.
- Consequence: player-facing runtime now shows shorter icon-led status with less repaint churn, while observer mode still exposes the verbose diagnostic path on a slower cadence.
