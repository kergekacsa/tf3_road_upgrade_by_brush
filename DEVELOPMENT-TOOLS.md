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
- **Files:** `support.lua` (module loading and the check function) and the `*_test.lua` files. `commit_flow_test.lua` tests `bb_upgrade.tl` with the real `bb_select.tl` and `proposal_probe.tl` against a stub of the game that records every command and every read of the game `api`. The reads of `bb_gather.tl` are not recorded, because the test replaces that module by a stub that describes the edges. The tests cannot load `brush_upgrade.script.tl`, so the calls of that script into the modules are not tested.
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

## Other checks in the same flow

- **Strings:** run `node build.js --check` in `C:\Users\Kacsa\tools\strings-gen`. It verifies every text of the mod against the 13 languages.
- **JSON:** run `node -e "JSON.parse(...)"` on `modinfo.json` and `strings.json`.
