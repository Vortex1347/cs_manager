# Current Milestone
- Exact Dust2 recovery slice is layered on top of the earlier combat/gunplay sandbox.
- `TacticalMap` now generates a closer Dust2 callout layout with `Long Doors`, `Outside Long`, `Blue`, `Suicide`, `Top Mid`, `B Door`, site plant slots, retake lanes, and bomb cover packages.
- `BotBrain` now executes duty packages and bomb tasks on top of the authored tactical graph instead of relying on generic route-plus-intent planning.
- `BotTeam` now plans around explicit Dust2 site duties, duty packages, bomb-task replanning, recover/drop logic, cover-planter, post-plant crossfires, site-aware retakes, and late CT save thresholds.
- Default HUD is now a lightweight drawn icon system with throttled observer refresh; verbose summaries and full rosters remain observer-only.
