# CS Manager Architecture

## Current Milestone

The game now runs as a deterministic CS sandbox with an exact Dust2-oriented top-down rebuild, callout-driven authored path graphing, bomb-first duty packages, and throttled icon-first UX:

- `GameManager` owns round flow, team buy plans, loadout application, HUD wiring, and bomb/audio intel routing.
- `Economy` produces structured `BotLoadout` objects instead of raw item arrays.
- `BombController` owns the full bomb lifecycle plus carrier/fallback-carrier/site-target state and exposes replanning events to teams and UI.
- `BotTeam` owns buy profiles, Dust2 round plans, duty-package assignment, bomb-task replanning, utility package selection, combat directives, slot reservations, heard-intel aggregation, and gunfight hints per role/profile.
- `BotBrain` owns local movement, combat micro, duty-package execution, bomb-task gates for plant/defuse/recover, grenade inventory, authored lineup throws, audio emission, and weapon-aware gunfight selection.
- `Weapon` now owns stateful accuracy, burst pressure, range profile, and movement/stabilization penalties.
- `TacticalMap` is now the main source of truth for runtime map geometry, Dust2 callouts, authored path graphing, semantic routes, lineups, cover slots, hold arcs, fallback routes, and sound zones.

## Tactical Model

### Team Layer

- T side plans: `default_a_long`, `a_long_commit`, `a_cat_split`, `b_contact`, `b_exec`, `mid_to_b_split`, late rotates, recover-bomb, post-plant, and save
- CT side plans: `a_hold+b_hold`, rotate on intel, contest dropped bomb, site-aware retake, and late save
- Roles assigned per round: `entry`, `second`, `trade`, `lurker`, `carrier`, `post_plant_anchor`, `anti_defuse_thrower`, `a_anchor`, `b_anchor`, `mid_rotator`, `long_contest`, `retake_cover`, `defuser`
- Buy profiles are selected per bot from team context rather than by independent per-bot autopurchase.
- Each alive bot receives a full duty package with `site_target`, `lane_target`, `role`, `bomb_task`, `utility_package_id`, and a combat directive with `hold_zone`, `peek_mode`, `trade_partner_id`, `fallback_route_id`, and reserved slot metadata.
- Team-level heard intel decays over time and can trigger limited CT rotations, retake posture, or trade-swing calls without pulling the whole team at once.

### Bot Layer

Each bot receives:

- `role_name`
- `current_intent`
- `target_zone_name`
- `duty_package`
- `bomb_task`
- ordered route points and dynamic graph-path fallback from the semantic Dust2 map
- structured loadout data: weapon, armor, kit, grenades, buy profile
- authored utility steps: trigger, lineup id, grenade type, follow intent
- combat directive data: hold position, look arc, swing mode, fallback route, clear points, trade partner, lane context
- gunfight hints: preferred fire mode, engagement profile hint, stabilize window, counter-strafe window, commit window

The bot then decides how to:

- follow the route
- hold authored angles instead of generic scan loops
- engage visible enemies
- choose `tap`, `burst`, `spray_commit`, or `awp_hold` by weapon, distance, hp, trade context, and peek mode
- react to heard footsteps/gunshots/grenade pops with short-lived memory
- shoulder peek, jiggle, trade swing, clear corners, or fallback depending on directive and intel
- stabilize before important shots and lose accuracy while moving or over-committing a burst
- retreat through authored fallback routes when HP falls below its stat-driven threshold
- plant, recover, escort, cover, anti-defuse, or defuse the bomb
- move into a lineup, throw a real physical grenade, wait for the pop, and continue the plan

## Gunplay Model

- `Weapon` tracks `base_spread`, `moving_spread_penalty`, `burst_spread_gain`, `recovery_rate`, `ideal_range`, `falloff_start`, and `burst_size_hint`.
- Final shot accuracy depends on bot movement, shot cadence, burst pressure, distance, peek mode, and whether the bot stabilized before firing.
- Weapon archetypes now matter in duels:
  - `pistol`: stop-and-peek profile, weak at range
  - `smg`: strong close-range commit, high movement and long-range penalty
  - `rifle`: main mid/long burst profile
  - `awp`: very accurate when stabilized, heavily punished while moving
- `aim_level` still matters, but now improves baseline spread control and recovery instead of acting as a single static spread cone modifier.

## Bomb System

`BombController` is the source of truth for bomb state and objective ownership:

- `none`
- `carried`
- `dropped`
- `planting`
- `planted`
- `defusing`
- `defused`
- `exploded`

`Bombsite` no longer owns timers or state. It only validates whether a bot is inside the plant/defuse zone.

Additional helpers now expose:

- `carrier_id`
- `fallback_carrier_id`
- `site_target`
- `active_planter`
- `active_defuser`
- `plant_progress`
- `defuse_progress`

## Map Model

The map now provides a tighter Dust2 callout model through `TacticalMap`, for example:

- `t_spawn_center`
- `suicide`
- `top_mid`
- `long_doors`
- `outside_long`
- `blue`
- `a_long`
- `mid_doors`
- `short_top`
- `b_door`
- `upper_tunnels`
- `b_window`
- `ct_spawn`
- `goose`
- `b_platform`

Route packages are defined by semantic Dust2 route IDs such as `default_a_long_entry`, `a_cat_split_short`, `b_exec_support`, `mid_to_b_split_mid`, `ct_long_contest`, `ct_retake_b_platform`, and `t_post_b_window` rather than numbered patrol loops.
The same map also exposes named grenade lineups and utility packages such as:

- `t_default_a`
- `t_a_long_commit`
- `t_a_cat_split`
- `t_b_exec`
- `t_mid_to_b`
- `ct_hold_a`
- `ct_hold_b`
- `ct_retake_a`
- `ct_retake_b`
- `t_post_plant_a`
- `t_post_plant_b`

`TacticalMap` also owns:

- plant slots per site
- retake lanes per site
- bomb cover packages per site/phase
- the authored path graph used for runtime movement

The match no longer depends on runtime navmesh baking during ordinary launch.

## Combat And Intel

- `BotTeam` merges visual contacts and routed audio events into one decaying intel model keyed by lane and confidence.
- `GameManager` broadcasts `footsteps`, `gunshot`, `grenade_pop`, `plant`, `defuse`, `bomb_drop`, and `bomb_pickup` events to both teams.
- Trade behavior is explicit: when an entry or anchor dies, the assigned partner receives a `trade_swing` directive pointed at the killer position.
- Slot reservation keeps allied bots from stacking onto the same authored cover slot in hold, execute, post-plant, and retake setups.

## Sandbox Observability

- Default bot labels are now compact icon markers with role/intent/bomb context; full multi-line labels are reserved for observer mode.
- Default HUD now stays lightweight and icon-first: score, alive count, timer, phase, bomb state, site focus, CT/T plan focus, and utility pressure stay visible, while combat/intel/gunfight summaries and full rosters live behind observer mode.
- Side roster panels remain available for manual tuning, but are hidden by default and only refreshed in observer mode.
- HUD/observer refresh is throttled so normal runtime does not repaint verbose diagnostics on every signal.
- Lineup markers and combat slot/arc markers can be toggled in runtime to inspect authored plans without leaving the match.

## RL Status

- Runtime default is deterministic FSM/utility play.
- `rl_training_mode` is opt-in only.
- Training still uses `RLServer` and `BotObserver`, but ordinary game launch no longer depends on a live Python socket.
