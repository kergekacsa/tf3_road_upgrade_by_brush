# Development tools

The checks that run outside the game. This file sits next to the mod folder, so it is not part of the uploaded mod.

## Paths

| Item | Value |
|---|---|
| Game install | `C:\Program Files (x86)\Steam\steamapps\common\Transport Fever 3\` |
| Test mod folder parent | `C:\Program Files (x86)\Steam\userdata\56068363\3493540\local\staging_area\` (the git root and the documents sit there) |
| Mod folder | `staging_area\kacsa_road_upgrade_brush\` |
| Game log | `C:\Program Files (x86)\Steam\userdata\56068363\3493540\local\crash_dump\stdout.txt` (the game overwrites it at every start) |
| Type definitions | `api\tealdef\` and `base\tealdef\` in the install folder, plus `vscode-template\` |
| Vanilla script source | Not readable in the install folder. The unpacked copy of `gui.zip` is at `C:\Users\Kacsa\tools\tf3-gamesrc\`. |
| Type check setup | `staging_area\tlconfig.lua` (includes the game's `api/tealdef` and `base/tealdef` and the mod's `content`) and `staging_area\all_def.tl` (copy of the game's `vscode-template`, loads `road_upgrade_brush.rub_types`) |

## Mod format

Source: [wiki.transportfever3.com](https://wiki.transportfever3.com).

- A mod folder holds `mod.json`, an optional `strings.json`, and `content/` for resources.
- `modId` MAY contain only `a-z`, `0-9`, and `_`. The recommended form is `<author>_<modname>`.
- `mod.json` hooks are `preRunScript`, `runScript`, and `postRunScript`, written as `<modid>::<file>@<function>`.
- Scripts are Lua, usually the Teal dialect (`.tl`). `local` is mandatory. Imports use `ug_require "<modid>::/path/file.tl" as TypeName`.
- A `.res.lua` file registers a resource. The tool resource has `type = "construction_tool"` and a `getDefinitionFn` that points to a script function.
- The mod uses `strings.json` for text, with keys per language. A text without a key shows as written in the code.

## Teal compiler

- **Program:** Teal compiler `tl` 0.24.8, `C:\Users\Kacsa\tools\teal\tl-0.24.8-windows-x86_64\tl.exe`.
- **Type check:** run `tl check <file>.tl` from the staging folder. The command reads `tlconfig.lua` there.
  - The config points at the game's own type definitions (`Transport Fever 3\api\tealdef` and `base\tealdef`) and at the content folder of the mod.
  - The global types come from `all_def.tl`.
  - A clean file ends with `0 errors detected`.
- **Generated Lua:** run `tl gen -o /tmp/x.lua <file>.tl` to turn the Teal into plain Lua.

## Lua syntax check

- **Program:** Lua 5.5.0 (`luac55`, installed through scoop).
- **Use:** `luac55 -p <file>.lua` parses a file and prints syntax errors without running it. Run it on the Lua that `tl gen` produced.
- **Limit:** the script runtime of the game may use another Lua version. The check proves only that the syntax is sound.

## Tests

- **Run:** `.\tests\run.ps1` from the staging folder. It needs the Teal compiler above and `lua55` on the PATH. The variable `$env:TL` replaces the compiler path.
- **What it does:** `tl gen` compiles the modules listed in `$modules` of `run.ps1` into `tests/.build/` (ignored by git), after it empties that folder. Each `tests/*_test.lua` runs with `lua55` against a stub of the game's `api`.
- **Files:** `support.lua` (module loading and the check function) and the `*_test.lua` files. `crosswalk_pass_test.lua` tests `crosswalk_pass.tl` with a fake env and a fake `node_crosswalks`. `node_crosswalks_test.lua` tests `node_crosswalks.tl`. `pair_spike_test.lua` tests `pair_spike.tl` with proposals that hand out copies of their data. `commit_flow_test.lua` tests `bb_upgrade.tl` with the real `bb_select.tl`, `proposal_probe.tl`, `pair_spike.tl`, `node_crosswalks.tl`, and `crosswalk_pass.tl` against a stub of the game that records every command and every read of the game `api`. The reads of `bb_gather.tl` are not recorded, because the test replaces that module by a stub that describes the edges. The tests cannot load `brush_upgrade.script.tl`, so the calls of that script into the modules are not tested. `grid_builder_test.lua` tests `rub_grid_builder.tl` through its function `build`, and checks that the module creates no global variable.
- **New module:** add its name to `$modules` in `run.ps1` and cover it in a `*_test.lua` file. One test file MAY cover several modules.
- **Limit:** the tests prove the logic of the mod. They do not prove that the game accepts a call.

## What these checks do not prove

- They do not prove that the game accepts a call at run time. The Teal definitions can be incomplete or differ from the engine. Examples are `getAsTable` missing in the tool, and the `constructionsToRemove` crash.
- Only the game shows that, through `crash_dump\stdout.txt`.

## In-game debug console

- **Enable:** set `debugMode` to `true` in `settings.lua`, or toggle it in the advanced game options. The console opens with the key below Esc.
- **Output:** the console window can stay empty after a command. `print()` output goes to `crash_dump\stdout.txt`, so read the log after every console command.
- **Marker:** let every console script print one clear marker line, for example `nodes:`. Then you can find the result in the log with a search.
- **History:** the game saves the typed commands to `console-history.lua`.

## Grid builder console function

`road_upgrade_brush/rub_grid_builder.tl` is a tool of the author for the in-game debug console. The console loads it with `ug_require` and calls its function `build(options)`. Nothing else loads it, so it costs players nothing, and it does not depend on the options "Debug: upgrade log" or "Debug: performance log". The tool has no toolbar entry and no text in `strings.json`. The README, the mod description, and the changelog MUST NOT mention it.

- **Why the console loads it:** the console runs in another Lua state than the tool script. A global variable that the tool script sets does not reach the console, and the game logs a red error on the screen for every global variable that a mod creates (`init.lua`, `__newindex` of `_G`). The module MUST NOT create a global variable. `grid_builder_test.lua` checks this.
- **Call:** build one straight street strip in the game with the normal road tool, toward the direction of the grid. Centre the camera on the strip. Type this line in the console once per game session. The name `grid` is only a console variable of the author:
  `grid = ug_require("kacsa_road_upgrade_brush::/road_upgrade_brush/rub_grid_builder.tl").build`
  Then type `grid()` for the defaults, or pass a table, for example `grid{blocksAlong=4, largeEveryAlong=2, largeEveryLeft=0}`. A key that the table leaves out keeps its default. A console that does not keep `grid` needs the whole `ug_require(...).build(...)` expression in each call.
- **Reloading the module:** a load of a save re-reads the tool script from disk, but the console keeps the module that it loaded first in the game session (the log of a run showed the old code after a load). The first log line of a run ends with the build mark of the module, which shows the version that ran. After a change to `rub_grid_builder.tl`, either restart the game, or clear the console copy and define `grid` again in one line:
  `for k in pairs(package.loaded) do if string.find(k, "rub_grid_builder", 1, true) or string.find(k, "node_crosswalks", 1, true) then package.loaded[k] = nil end end; grid = ug_require("kacsa_road_upgrade_brush::/road_upgrade_brush/rub_grid_builder.tl").build`
  The second way is untested in the game.
- **Options:** the fields, their meaning, and their defaults are the docblocks of `RubGridOptions` in `brush_types.d.tl`. This file does not repeat them.
- **Start:** the function takes the street edge whose midpoint is nearest to the camera centre, within `cameraSearchRadiusM`, as the strip. Tracks do not count. The game does not offer a loop over all edges (`Cannot loop over this component type`), so the camera centre is the only anchor.
- **Corner and heading:** the grid starts at the second node of the strip, the end of the strip. The heading runs from the first node to the second node, so the strip is the approach road of the grid. The order of the two nodes of an edge is not documented. The option `flipStripDirection=true` swaps them, which starts the grid at the other end of the strip and runs it the other way.
- **Result:** `blocksAlong` blocks along the heading and `blocksLeft` blocks to the left of it, so `blocksAlong + 1` streets run to the left and `blocksLeft + 1` streets run along the heading. The streets take the owner of the strip, and the template and decorations of the strip unless they are large. The option `buildToRight` builds the blocks to the right of the heading, so the strip becomes the left edge of the grid. Every "left" in this section and in the options then means the right. The options `maxLengthAlongM` and `maxLengthLeftM` replace the block counts: the grid gets the most blocks that fit under the length, counted between the centre lines of the outer streets. A length under one block stops the function before the first command. The first log line names the blocks and the side that the function chose.
- **Large streets:** two options choose them, one for each kind of street. `largeEveryAlong` makes every Nth street that runs along the heading large. These streets are numbered from 0 to the left, so they sit `blockLengthLeftM` apart. `largeEveryLeft` makes every Nth street that runs to the left large. These streets are numbered from 0 along the heading, so they sit `blockLengthAlongM` apart. Line 0 of each kind starts at the strip end. The value 0 turns large streets off for that kind. A large segment takes the first template of `largeStreetBaseNames` that the game year allows (`rub_templates` resolves it), with the style, lanes and default decorations of that template. The other segments keep the template, lanes and decorations of the strip. The function stops before the first command when no large template exists for the year.
- **Build order:** the segments go in this order: the first street along the heading, then every street to the left, then the other streets along the heading. By default each command holds one segment (`edgesPerCommand`). A command starts only after the callback of the previous one. The function finds the nodes of earlier commands by position at every command and keeps no node id, because another mod can replace a node (Smart Lanes does at a lane-count change, and the game then logs `Apply: invalid entity`). With `edgesPerCommand` set to a number N, a command holds N segments. With 0, one command holds the whole grid. A node that segments of one command share is made once, with all its edges. A command that the game refuses is sent again with fresh nodes, up to 3 attempts in total, because Smart Lanes can replace a node at the moment a command uses it. The function leaves the strip as it is. After the last segment it handles the corners that keep two streets (see the next bullets).
- **Lane connections:** an empty node config has no lane connections, so a grid with explicit node configs has dead-end lanes everywhere (the red no-entry sign, no lane arcs, the crossing tool refuses). The option `laneConnections` decides how the nodes get connections. With `"own"`, the default when `explicitNodeConfigs` is on, the function writes them itself after the last segment, one command for each grid node: by these rules. At a corner of two streets each incoming lane goes to the outgoing lane at the same distance from the centre line, and extra lanes merge into the curb lane when the other street is narrower. When the other street is wider, the lanes of the narrower street share its lanes, so every lane of the wider street is fed. At a crossing of three or more streets every lane goes straight on in the same way, except the curb lane of a street with several lanes, which only turns right. A right turn starts only in the curb lane and ends in the curb lane of the new street, and a left turn starts only in the lane next to the centre line and ends in the lane next to the centre line of the new street. The stem of a T has no street straight ahead, so its outer lanes turn right and its inner lanes turn left, and every lane has a connection. Lanes that turn the same way enter the lanes of the new street in the same order: from the curb inwards for a right turn, and from the centre line outwards for a left turn. A street counts as straight ahead when it leaves within 30 degrees of the line of travel. It does not need another mod and works in the map editor. The game takes only its own lane connection objects, which the function makes with `api.type.LaneConnection.new()`. That type is missing from the Teal definitions. The lane numbers are the ones the game counts from the node, from left to right when looking along the street, so the lanes that lead to the node come first, and the sidewalk lanes count. A node that already has crosswalks keeps them. A node with three or more streets and no crosswalk gets one on every street whose template has `defaultWithCrosswalk`. A bend of two streets gets none. With `"off"` the nodes keep the empty configs.
- **Corner stubs:** the values `"stub_remove"` and `"stub_keep"` of `laneConnections` leave the work to Smart Lanes, which writes the lane connections of a junction a moment after a street joins it. They build a plain street of 30 m out of each corner that keeps two streets. With `"stub_remove"` the function removes it again as soon as the node has lane connections. It waits with commands that send an event no script handles, up to 150 of them for each corner. The removal command writes the node config again without the lane connections that touch the stub and without crosswalks, because a config that names a removed street crashes the game (`lc.segment1 not found`). A corner that has no connections after the wait keeps its stub and logs `wait_timeout`. This happens when Smart Lanes does not run, for example in the map editor. With `"stub_keep"` the stubs stay.
- **Large streets need node configs:** a grid with large streets MUST be built with node configs, or the game crashes in its simulation thread. The option `explicitNodeConfigs` is on by default when a large street is in the grid, and `explicitNodeConfigs=false` switches it off. See "Game API" in `ARCHITECTURE.md`.
- **Output:** every line starts with the tag `[BrushUpgrade] [grid]` and goes to the game log. The first line names the chosen strip, the corner, the heading, and whether the grid fits the map. The second line names the template of the strip and the large template with their `simBuildable`, `crosswalk`, and `country` flags. Each finished command gives a `built` line with the first and the last segment number of the command and how many of its segments are large. With `"own"`, the run ends with a `lane_connections` line that counts the nodes written, failed, refused (the game takes no connection list), and skipped (fewer than two streets), and each failed or refused node logs its own line. With stubs, each corner logs `bend_stub` lines: `built` or `failed`, then `connections_ready` or `wait_timeout` with the number of polls, the street count, and the number of lane connections in the node config, then `config_kept`, `removed` or `remove_failed`, and `after`. A refused command that will be sent again gives a `retry` line. A complete run ends with a `done` line, and a command that is refused on every attempt gives a `failed_at` line with its segment numbers and the message of the game (the message can be empty). A crash in the game stops the log after the last `built` line. An error of the function, such as `no_street_near_camera`, shows in the console.
- **Limit:** `grid_builder_test.lua` proves the geometry and the proposals against a stub of the game. It does not prove that the game accepts the proposals, so the first run in the game decides.

### Traffic light and left turn removal

The same module has four more console functions, `removeLights()`, `removeLeftTurns()`, `removeLightsAndLeftTurns()`, and `addCrosswalks()`. They work on the whole map and need no strip and no camera position. They change the map at once, and the game has no undo for them. Save the game first.

- **Call:** define the module once per game session, then call `removeLightsAndLeftTurns()`. The reload rule of the previous section applies:
  `grid = ug_require("kacsa_road_upgrade_brush::/road_upgrade_brush/rub_grid_builder.tl")`
  `grid.removeLightsAndLeftTurns()`
  The name `grid` then holds the module, so the grid builder is `grid.build()`.
- **Order:** the commands run in the background, and a function returns before its first command finishes. Two calls one after the other would run side by side, and `removeLeftTurns()` would skip the junctions whose light is not yet removed. `removeLightsAndLeftTurns()` starts the left turn removal after the last light command finished. To run the two by hand, call `removeLeftTurns()` only after the log shows `lights_done`.
- **Major-minor junction:** a node with at least 3 street edges, no edge of another player, an edge with several vehicle lanes in one direction (major), and an edge with exactly one (minor). Pedestrian lanes do not count. Both functions use this test.
- **`removeLights()`:** it takes the major-minor junctions that have a traffic light with the preference not yet "no". One command per node sets the preference to "no" and keeps the light settings of the node.
- **`removeLeftTurns()`:** it takes all major-minor junctions, with or without a light, and skips a junction that still has a traffic light (the phases of a light point to the lane connections by position), so it needs `removeLights()` to finish first. One command per junction writes the node config again with fewer lane connections and the crosswalks unchanged:
  - Left turns go. A turn is a left turn when the angle between the approach and the exit is over 45° to the left.
  - U-turns stay.
  - When a junction has exactly two major streets, they count as straight to each other, however sharply they bend at the node (the L shape of a T junction). Every other pair uses the angle.
  - A straight connection stays between lanes of one kind: a bus lane (bus allowed, car not) to a bus lane, a normal lane to a normal lane.
  - A right turn stays only from the outer lane of a kind to the outer lane of the same kind. The outer lane is the one at the right edge of the street in the driving direction. The code assumes traffic on the right.
  - A connection without road (tram) stays.
- **`addCrosswalks()`:** it takes every junction of the player (at least 3 streets, no street of another player), with or without a light. One command per junction writes the node config again with a crosswalk on every street of the junction, but only when at least one street is a town street: a street that is no country road (`country` flag of the template) and has a sidewalk lane. The rule is all or nothing per junction. A junction of only country roads and highways gets none, and a junction with a town street gets crosswalks on its country road and highway streets too. Large streets get crosswalks. A crosswalk that exists stays, and a junction with all of them is skipped. A junction without a node config is skipped. The lane connections and the light settings stay as they are. Call it with `grid.addCrosswalks()`, independent of the other functions.
- **Lane positions:** the code reads `lane0` and `lane1` of a lane connection as positions in `laneConfigs` (pedestrian lanes included), counted from left to right when looking from the node along the street. The game documents the order but not whether pedestrian lanes count. Before it changes a junction, the code checks every road connection against that reading: the lane exists, it is no pedestrian lane, and it runs in the right direction. A junction that fails the check stays unchanged and logs `turns_skipped N lane_mismatch`.
- **One command at a time:** each command starts in the callback of the previous one.
- **Output:** every line starts with the tag `[BrushUpgrade] [grid]`. A run ends with `lights_done`, `turns_done`, or `crosswalks_done` and the numbers `nodes N changed C skipped S failed F`. A refused node gives a `lights_failed` or `turns_failed` line with the game message. A skipped junction gives `turns_skipped N <reason>` with the reason `has_traffic_light`, `no_config`, `lane_mismatch`, `unchanged`, or `config_copy_failed`. A changed junction gives `turns_node N kept K of T`. `addCrosswalks()` logs `crosswalks_node N X added`, `crosswalks_skipped N <reason>` with the reason `no_config`, `no_town_street`, `unchanged`, or `config_copy_failed`, and `crosswalks_failed N <message>`.
- **Limit:** `grid_builder_test.lua` proves the filter, the rules, and the commands against a stub of the game. The first run in the game decides whether it accepts the proposals and whether the lane position reading is right.

### Small road speed

The same module has the console function `setSmallRoadSpeed(kmh)`. It works on the whole map and changes it at once. The game has no undo for it. Save the game first. The research behind it is `docs/research/road-speed-limits.md`.

- **Call:** define the module as in the previous section, then call `grid.setSmallRoadSpeed()` for 30 km/h, or `grid.setSmallRoadSpeed(40)`. A speed of 0 or less raises an error and sends nothing.
- **Roads:** the town and country small roads of both eras, with their variants (trees, barriers, bus, tram), that belong to the player or to nobody and are not part of a construction. The medium and large roads and `town_new_xsmall` stay as they are. Industry access roads are not detected and change like any other small road.
- **Command:** one command per road, each sent in the callback of the previous one. The command is `replaceSegment` with the template the road already has, with every lane of the new segment set to the speed. The mod writes the value in m/s (`kmh / 3.6`) and reads it back from the proposal. A road that already has the speed in every lane is left alone, so a second call changes nothing. A road whose new segment would lose an edge object (a signal or a stop) is skipped.
- **Cost:** each replacement is a player-initiated command, so the game may charge the player for each road.
- **Output:** every line starts with the tag `[BrushUpgrade] [grid]`. The run starts with `speed_start` (speed in km/h and m/s, number of small roads, number to change). A refused road gives `speed_failed <road> <message>`. A skipped road gives `speed_skipped <road> <reason>` with the reason `gone`, `replace_segment_failed`, `speed_not_kept`, `no_new_segment`, or `objects_lost`. The run ends with `speed_done roads N changed C skipped S failed F` and `speed_check small_roads T other_speed D`.
- **Reading `speed_check`:** the line counts the small roads whose lanes still have another speed after the last command. A value above the number of skipped and failed roads means the game replaced the road but did not keep the written speed. That settles the main open question of the research file. Vehicle speed on the road, the save, and the removal of the mod are not covered: the open questions 2, 4, and 6 of that file still need their game tests.
- **Limit:** `grid_builder_test.lua` proves the road filter, the edit, and the commands against a stub of the game. It does not prove that the game accepts the proposals.

## Other checks in the same flow

- **Generator:** `strings.json` and the texts of `mod.json` come from the generator in `C:\Users\Kacsa\tools\strings-gen` (`table.js` holds the translations, `build.js` writes `strings.json`). After a text change in `mod.json` or the code, update `table.js` and run `node build.js`.
- **Strings:** run `node build.js --check` in `C:\Users\Kacsa\tools\strings-gen`. It verifies every text of the mod against the 13 languages.
- **JSON:** run `node -e "JSON.parse(...)"` on `modinfo.json` and `strings.json`.
