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
- **Files:** `support.lua` (module loading and the check function) and the `*_test.lua` files. `commit_flow_test.lua` tests `bb_upgrade.tl` with the real `bb_select.tl` and `proposal_probe.tl` against a stub of the game that records every command and every read of the game `api`. The reads of `bb_gather.tl` are not recorded, because the test replaces that module by a stub that describes the edges. The tests cannot load `brush_upgrade.script.tl`, so the calls of that script into the modules are not tested. `grid_builder_test.lua` tests `rub_grid_builder.tl` through its function `build`, and checks that the module creates no global variable.
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
  `for k in pairs(package.loaded) do if string.find(k, "rub_grid_builder", 1, true) then package.loaded[k] = nil end end; grid = ug_require("kacsa_road_upgrade_brush::/road_upgrade_brush/rub_grid_builder.tl").build`
  The second way is untested in the game.
- **Options:** the fields, their meaning, and their defaults are the docblocks of `RubGridOptions` in `brush_types.d.tl`. This file does not repeat them.
- **Start:** the function takes the street edge whose midpoint is nearest to the camera centre, within `cameraSearchRadiusM`, as the strip. Tracks do not count. The game does not offer a loop over all edges (`Cannot loop over this component type`), so the camera centre is the only anchor.
- **Corner and heading:** the grid starts at the second node of the strip, the end of the strip. The heading runs from the first node to the second node, so the strip is the approach road of the grid. The order of the two nodes of an edge is not documented. The option `flipStripDirection=true` swaps them, which starts the grid at the other end of the strip and runs it the other way.
- **Result:** `blocksAlong` blocks along the heading and `blocksLeft` blocks to the left of it, so `blocksAlong + 1` streets run to the left and `blocksLeft + 1` streets run along the heading. The streets take the owner of the strip, and the template and decorations of the strip unless they are large. The option `buildToRight` builds the blocks to the right of the heading, so the strip becomes the left edge of the grid. Every "left" in this section and in the options then means the right. The options `maxLengthAlongM` and `maxLengthLeftM` replace the block counts: the grid gets the most blocks that fit under the length, counted between the centre lines of the outer streets. A length under one block stops the function before the first command. The first log line names the blocks and the side that the function chose.
- **Large streets:** two options choose them, one for each kind of street. `largeEveryAlong` makes every Nth street that runs along the heading large. These streets are numbered from 0 to the left, so they sit `blockLengthLeftM` apart. `largeEveryLeft` makes every Nth street that runs to the left large. These streets are numbered from 0 along the heading, so they sit `blockLengthAlongM` apart. Line 0 of each kind starts at the strip end. The value 0 turns large streets off for that kind. A large segment takes the first template of `largeStreetBaseNames` that the game year allows (`rub_templates` resolves it), with the style, lanes and default decorations of that template. The other segments keep the template, lanes and decorations of the strip. The function stops before the first command when no large template exists for the year.
- **Build order:** the segments go in this order: the first street along the heading, then every street to the left, then the other streets along the heading. By default each command holds one segment (`edgesPerCommand`). A command starts only after the callback of the previous one. The function finds the nodes of earlier commands by position at every command and keeps no node id, because another mod can replace a node (Smart Lanes does at a lane-count change, and the game then logs `Apply: invalid entity`). With `edgesPerCommand` set to a number N, a command holds N segments. With 0, one command holds the whole grid. A node that segments of one command share is made once, with all its edges. A command that the game refuses is sent again with fresh nodes, up to 3 attempts in total, because Smart Lanes can replace a node at the moment a command uses it. The function leaves the strip as it is. After the last segment it handles the corners that keep two streets (see the next bullets).
- **Corners need a third street:** an empty node config works at a crossing or a junction, but a corner that keeps two streets has dead-end lanes (the red no-entry sign, no lane arcs, the crossing tool refuses). The game does not accept a Lua table as a lane connection (`bad argument #4 ... const LaneConnection expected`), so the function cannot write the connections itself. A corner works as soon as a third street attaches, and it keeps working after that street is removed. The lane connections of the junction appear a moment after the street is built, because the mod Smart Lanes writes them. A removal right after the build leaves the corner broken, so the function waits first.
- **Corner stubs:** the option `bendStubs` handles the corners that keep two streets. With `"remove"`, the default when `explicitNodeConfigs` is on, the function builds a plain street of 30 m out of each such corner and removes it again as soon as the node has lane connections. The function waits with commands that send an event no script handles, up to 150 of them for each corner. The removal command writes the node config again without the lane connections that touch the stub and without crosswalks, because a config that names a removed street crashes the game (`lc.segment1 not found`). If the game refuses that copy, the function logs `config_copy_failed` and keeps the stub. A corner that has no connections after the wait keeps its stub and logs `wait_timeout`. With `"keep"` the street stays, and `"off"` builds nothing. A corner that joins the strip has three streets and needs nothing.
- **Large streets need node configs:** a grid with large streets MUST be built with node configs, or the game crashes in its simulation thread. The option `explicitNodeConfigs` is on by default when a large street is in the grid, and `explicitNodeConfigs=false` switches it off. See "Game API" in `ARCHITECTURE.md`.
- **Output:** every line starts with the tag `[BrushUpgrade] [grid]` and goes to the game log. The first line names the chosen strip, the corner, the heading, and whether the grid fits the map. The second line names the template of the strip and the large template with their `simBuildable`, `crosswalk`, and `country` flags. Each finished command gives a `built` line with the first and the last segment number of the command and how many of its segments are large. With stubs, each corner logs `bend_stub` lines: `built` or `failed`, then `connections_ready` or `wait_timeout` with the number of polls, the street count, and the number of lane connections in the node config, then `config_kept` with the number of connections kept, then `removed` or `remove_failed`, then `after` with the same counts. A refused command that will be sent again gives a `retry` line. A complete run ends with a `done` line, and a command that is refused on every attempt gives a `failed_at` line with its segment numbers and the message of the game (the message can be empty). A crash in the game stops the log after the last `built` line. An error of the function, such as `no_street_near_camera`, shows in the console.
- **Limit:** `grid_builder_test.lua` proves the geometry and the proposals against a stub of the game. It does not prove that the game accepts the proposals, so the first run in the game decides.

## Other checks in the same flow

- **Strings:** run `node build.js --check` in `C:\Users\Kacsa\tools\strings-gen`. It verifies every text of the mod against the 13 languages.
- **JSON:** run `node -e "JSON.parse(...)"` on `modinfo.json` and `strings.json`.
