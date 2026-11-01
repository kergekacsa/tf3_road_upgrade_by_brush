# Development tools

The checks that run outside the game. This file sits next to the mod folder, so it is not part of the uploaded mod.

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
