# Publishing to mod.io

This file sits next to the mod folder, so it is not part of the uploaded mod. It records what Transport Fever 3 requires to publish a mod or to update one, and the status of this mod against each requirement.

Sources (read on 2026-11-01):

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

## First upload

1. Copy the mod folder to `staging_area` in the userdata folder (already done).
2. Start the game and open the Mod Hub, then My Mods.
3. Select the mod. Adjust name, tags, cover, gallery, and visibility.
4. Click Upload at the bottom left. The game validates the mod first.
5. After the upload the game writes `_metadata/mod.io_fileid.txt`. The entry opens on mod.io.

## Update of an existing mod

1. Increase `revision` in `mod.json`. Without an increase, players cannot tell the versions apart.
2. Keep `_metadata/mod.io_fileid.txt`. It holds the mod.io entry id. If the file is lost, create it again with the id from the info box on the right of the mod page.
3. Open the Mod Hub, then My Mods, and select the mod.
4. Check the box at the bottom left. It MUST read "The existing mod on mod.io will be updated" next to the Update button. If it does not, the file id is missing.
5. Write a changelog message and click Update.
6. Back up any title or description text that you edited on mod.io. The upload overwrites them with `name` and `description` from `modinfo.json`.
7. A change that breaks savegames of players SHOULD get a new `modId` and an independent mod, not an update.

## Status of this mod

Checked on 2026-11-01, build `bu`, before the second upload.

| # | Item | Status |
|---|---|---|
| 1 | Name 25 characters, summary 93 characters | OK |
| 2 | Tags: Track, Town Building, Track Construction, Script Mod, Road, Road Construction | OK, all in the official list |
| 3 | `0.png`, `1.png`, `2.png` are 1920 x 1080 PNG, each 4.3 to 4.7 MB | OK |
| 4 | Description in English, with headers, bold, and lists, with no table or image | OK |
| 5 | Mod folder size 16 MB, no executables, no source assets, no uppercase or space in names | OK |
| 6 | No BOM in `.tl`, `.lua`, `.json`. `mod.json`, `modinfo.json`, `strings.json` parse | OK |
| 7 | Teal type check of all 16 scripts, 0 errors. `luac55 -p` on the generated Lua and the `.lua` files, no syntax error | OK |
| 8 | `node build.js --check` in `strings-gen`: check ok, 42 keys in 12 languages | OK |
| 9 | `probe.ENABLED = false` | OK |
| 10 | `severityAdd` and `severityRemove` are `None`. The mod saves nothing in a savegame | OK |
| 11 | `mod.io_fileid.txt` is present (entry 6495139), so this is an update | OK |
| 12 | `revision` in `mod.json` raised from 1 to 2 | Done |
| 13 | Layer change (data layers with the brush open) committed | Open: commit before the upload |
| 14 | Data layers and the stuck ring tested in the game | Layers: tested, working (user). Stuck ring: not seen again |
| 15 | Changelog message | Draft below |
| 16 | Backup of title and description edits on mod.io | Open: check the mod page first |
| 17 | Permission of square17 and kurowasiichi for the copied code | OK, confirmed by the author. The credits are in the description and in the file headers |
| 18 | `image_00.jpg` in the mod root | OK, kept on purpose. The wiki does not name this file |

## Documents stay outside the mod

The wiki requires that the mod holds only essential files. The README, the SPEC, `CONTEXT.md`, `PUBLISHING.md`, and `DEVELOPMENT-TOOLS.md` MUST stay in `staging_area`, next to the mod folder. The mod page text comes from `_metadata/modinfo.json`. No document is needed inside the mod.

## Changelog draft (revision 2)

```text
- The data layers of the layers menu now work while the brush is open.
- Fixed: the brush circle could stay fixed on the map after switching the Underground button or the layers.
- The tool starts from its default state each time you open it. The brush radius is kept.
```

## Before the upload

1. Commit the open changes (item 13).
2. Run the checks again if a script changed. The commands are in `DEVELOPMENT-TOOLS.md`.
3. Confirm item 16.
4. Start the game, open the Mod Hub, and upload with the changelog.
5. Check that the new `_metadata/mod.io_fileid.txt` still holds the same id and that the mod page shows revision 2.
