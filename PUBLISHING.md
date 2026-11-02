# Publishing to mod.io

This file sits next to the mod folder, so it is not part of the uploaded mod. It is the guide for a release: what Transport Fever 3 requires to publish a mod or to update one, and the steps to follow.

Sources:

- [Publish a Mod](https://wiki.transportfever3.com/doku.php?id=modding:general:publishing)
- [Guidelines & Requirements](https://wiki.transportfever3.com/doku.php?id=modding:general:guidelines)
- [Mod Definition](https://wiki.transportfever3.com/doku.php?id=modding:general:moddefinition)
- [Mod Tags](https://wiki.transportfever3.com/doku.php?id=modding:general:modtags)

## Rules of the platform

- The author MUST have the copyright or the permission to distribute all content in the mod.
- The mod MUST be non-commercial and free in full for all users.
- The mod MUST NOT contain offensive or inappropriate content.
- The mod MUST follow the mod.io End User License Agreement and Terms of Use.
- Game files of Transport Fever 1, 2 and 3 MAY be used, and the source of such files MUST be stated.

## Requirements for the mod files

| Area | Requirement |
|---|---|
| Integrity | All resources load without errors or warnings. |
| Security | No batch files, shell scripts, or other executables. |
| Encoding | Text files (`.lua`, `.tl`, `.json`) are UTF-8 without BOM. |
| Size | At most 500 MB unpacked. |
| Names | Lowercase only, no spaces, no special characters. |
| Ballast | No source assets (`.psd`, `.fbx`) and no temporary files. |
| Scripts | Only the official scripting API. Scripts handle edge cases. |
| Textures | DDS with mipmaps, power-of-two sizes. Does not apply to this mod (the icons are `.tga` GUI files). |
| `mod.json` | `modId` uses only `a-z`, `0-9`, `_`. `severityAdd` and `severityRemove` are set correctly. |
| Console | No shaders. No change to basic gameplay that could harm performance. |

The game runs a validation pass when you click Upload. It checks structure, file acceptance, syntax, metadata, and resource integrity. A mod MUST pass it.

## Requirements for the mod page

| Item | Requirement | Where it lives |
|---|---|---|
| Name | At most 32 characters, Title Case, no line break | `_metadata/modinfo.json` |
| Summary | At most 100 characters, no line break | `_metadata/modinfo.json` |
| Description | English is mandatory. Use paragraphs, headers 1 to 3, bold, lists, and rules. Avoid tables, images, and videos. | `_metadata/modinfo.json` |
| Tags | Only tags from the official list | `_metadata/modinfo.json` |
| Cover | `_metadata/0.png`, 1920 x 1080, 16:9, at most 8 MB, English text only, if any | `_metadata/0.png` |
| Gallery | `_metadata/1.png`, `2.png`, and so on, 1920 x 1080 | `_metadata/` |
| Visibility | Set in the Mod Hub | Mod Hub |
| Changelog | A useful message for every update | Mod Hub, at upload |

The cover guideline for script mods allows a screenshot of the GUI, graphic overlays without text, or a schematic. It advises against text and logos on the cover. A small creator logo is optional.

Official tags: Map, Savegame, Temperate, Subarctic, Dry, Tropical, Custom, Locomotive, Wagon, Multiple Unit, Bus, Truck, Tram, Ship, Plane, Helicopter, Rail Station, Road Station, Airport/Heliport, Port, Track, Road, Bridge, Tunnel, Signal, Rail Crossing, Road Construction, Track Construction, Industry, Town Building, Warehouse, Landmark, Depot, Maintenance Building, Vegetation, Rock, Other Asset, Script Mod, Car, Resident, Animal, Sound, Shader.

## Documents stay outside the mod

The wiki requires that the mod holds only essential files. The README, `CONTEXT.md`, `ARCHITECTURE.md`, `docs/adr/`, `PUBLISHING.md`, `DEVELOPMENT-TOOLS.md`, `CLAUDE.md`, and `tests/` MUST stay in `staging_area`, next to the mod folder. The mod page text comes from `_metadata/modinfo.json`. No document is needed inside the mod.

## Checks before every upload

Run these on the exact build that you upload. The commands are in `DEVELOPMENT-TOOLS.md`.

1. The changes of the release are committed.
2. The Teal type check of every script reports 0 errors and 0 warnings.
3. `luac55 -p` reports no syntax error for the generated Lua and for the `.lua` files of the mod.
4. No file has a BOM. `mod.json`, `modinfo.json`, and `strings.json` parse.
5. `node build.js --check` in `strings-gen` reports "check ok".
6. `tests\run.ps1` reports that all test files passed.
7. `mod.json` holds the right `revision`. `severityAdd` and `severityRemove` are `None` when the mod saves nothing in a savegame. Every debug option has `defaultIndex` 0 (Off).
8. The mod folder has no executables, no source assets, no temporary files, and no uppercase letter or space in a name.
9. Start the game with this build and use the mod once with each debug option On. Then read `crash_dump\stdout.txt` for errors. A changelog line MUST say "Fixed" only when someone saw the failure before the change and could not make it happen after, by manual test or by log. If the failure could not be made to happen again, the line SHOULD say "should no longer".

## First upload

1. Copy the mod folder to `staging_area` in the userdata folder.
2. Start the game and open the Mod Hub, then My Mods.
3. Select the mod. Adjust name, tags, cover, gallery, and visibility.
4. Click Upload at the bottom left. The game validates the mod first.
5. After the upload the game writes `_metadata/mod.io_fileid.txt`. The entry opens on mod.io.

## Update of an existing mod

1. Increase `revision` in `mod.json`. Without an increase, players cannot tell the versions apart.
2. Keep `_metadata/mod.io_fileid.txt`. It holds the mod.io entry id. If the file is lost, create it again with the id from the info box on the right of the mod page.
3. Open the Mod Hub, then My Mods, and select the mod.
4. Check the box at the bottom left. It MUST read "The existing mod on mod.io will be updated" next to the Update button. If it does not, the file id is missing.
5. Back up any title or description text that you edited on mod.io. The upload overwrites them with `name` and `description` from `modinfo.json`.
6. Write a changelog message and click Update.
7. After the upload, check that `_metadata/mod.io_fileid.txt` still holds the same id and that the mod page shows the new revision.

Notes:

- A change that breaks savegames of players SHOULD get a new `modId` and an independent mod, not an update.
- The Version column of the Files page on mod.io is not the `revision`. The publish settings of the game have no version field. The revision shows in the in-game mod details.
