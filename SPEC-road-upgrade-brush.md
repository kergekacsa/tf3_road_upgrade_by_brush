# Spec: brush street upgrade for Transport Fever 3

## Outcome

The player paints a brush over street segments, sees them highlighted, picks a road type and options, and presses Upgrade. The tool upgrades up to 200 selected segments in one press. The street upgrade tool of the base game changes one segment per click.

The same tool has a second mode, Rails, that selects rail tracks with the brush and upgrades them to a track type in one press.

The result is one mod, `kacsa_road_upgrade_brush`. It combines the road types and options of Road Upgrade All in One with the brush selection of Bulk Bulldozer. The mod is independent of both and has no single-click tool.

## Scope

In scope:

- A brush upgrade tool: select with a brush, then upgrade by street template.
- Road type, alley trees, noise barriers, bus lane, tram track, catenary, lock, and the Underground button.
- A Rails mode: select tracks with the brush and upgrade them to a track type (simple, standard, high speed) with a catenary state (keep, add, remove).

Out of scope:

- One-way road types.
- Upgrading stations, assets, or town buildings.
- Tracks with a template other than the six base track templates.
- More than 200 segments per press.

## Requirements

### Mod

- The mod MUST use the modId `kacsa_road_upgrade_brush`.
- The mod folder MUST be `C:\Program Files (x86)\Steam\userdata\56068363\3493540\local\staging_area\kacsa_road_upgrade_brush\`.
- The mod MUST contain one tool with two menu entries: "Road Upgrade Brush" in the road tools (`roads_tools`) and "Rail Upgrade Brush" in the rail tools (`rail_tools`). Both entries use the same script: `brush_upgrade.res.lua` and `brush_upgrade_rail.res.lua` point to the same `getDefinition`, which tells the entry by the resource name it gets (a name with `rail`). The road entry opens in the Roads mode and the rail entry in the Rails mode. The mod MUST NOT add a single-click upgrade tool.
- The mod MUST NOT contain a Bulldoze button or any removal code.
- The mod MUST be independent: no mod dependency. It MUST work with and without Road Upgrade All in One (`road_upgrade_suite`) and Bulk Bulldozer switched on. Every file path and text key of the mod MUST be unique (`road_upgrade_brush/rub_*`, `rub_*` keys, `gui/road_upgrade_brush/`), and every global Teal type name carries the prefix `Rub`.
- The mod MUST ship its own tool icon (`gui/road_upgrade_brush/brush_tool@2x.tga` and `brush_tool_preview@2x.tga`) and the mod.io pictures `_metadata/0.png` (the cover: a screenshot with the title card) and `_metadata/1.png` (a gallery picture: the same screenshot without the card), both PNG, 1920 x 1080, at most 8 MB. It MUST NOT ship image files of another mod.
- The mod folder MUST hold only files that the mod needs, with lowercase names (the README and the SPEC stay outside it). `_metadata/modinfo.json` MUST have a name of at most 32 characters, a summary of at most 100 characters without line breaks, and an English description, and its tags MUST be tags of the game (`Script Mod`, `Road Construction`).
- The mod revision in `mod.json` MUST be 1.
- `strings.json` MUST hold every text that the code and `mod.json` pass to the translation (`_()`, the name, tooltip, and values of the settings of `mod.json`) in the 12 languages of the game besides English (`base/strings/`: de, es, fr, it, ja, ko, nl, pl, pt_BR, ru, zh_CN, zh_TW). English uses the text as written in the code, and a key only for the `rub_*` texts. A text that is also a key in the `strings.json` of Bulk Bulldozer MAY reuse its translation; the README credits it. Every reason text of the commit MUST have an entry in the label table of `bb_status.tl`. The names of the road types MUST be the names the game gives to its street templates. A text of the code that has the same English text as a text of the game (`base.mo`) MUST use the game's translation, except where the game's word is a mistranslation for this use (Off in Italian: the game says Mai, the mod says No as in the settings screens of the game). A text of the status chip MUST fit `status.MAX_CHARS` (36 columns, CJK characters count 2) in every language; the chip shows the short problem texts (`rub_chip_*`) and the toolbar notes show the full texts (`rub_problem_*`).
- The mod MUST keep the original authors' names in the headers of copied files (including `rub_types.d.tl`). The README MUST name the copied texts of `strings.json`, which cannot carry a header.
- A comment in the code MUST state only a contract, an invariant, a unit, or a constraint that holds now. Generated Lua is the same before and after a comment change.

### Selection

- The selection cap MUST be 200 segments, and the command budget per press MUST be 200 (one command per segment). Both come from `sel.STROKE_CAP`.
- The brush MUST keep the bulldozer's selection rules: it skips other players' roads, construction parts, industry roads, and gone entities. It allows town-owned and unowned roads.
- A road MUST be selected when the brush circle touches it (the curve of the road comes within the radius of the circle). This holds for the hover preview, for a painted stroke, and for the Shift stroke that removes from the selection. A road is not required to have both end points inside the circle.
- While the underground view is on, the brush MUST select tunnels only (filter field `surface` false, reason `surface`). While it is off, tunnels are not selected (reason `underground`).
- The brush MUST NOT select a stand-alone tram track, that is a street none of whose lanes carries a car, a bus, or a truck (`isTramOnly` in `bb_gather.tl`, reason `tram_only`). A road with tram tracks besides its vehicle lanes is selected.
- The brush MUST NOT offer filters for stations, assets, and town buildings. The mode sets the filters: Roads selects streets only (kind `road`), Rails selects tracks only (kind `track`: edges of the player with no `BASE_EDGE_STREET`).
- In the Rails mode the brush MUST select only tracks whose template is one of the six base track templates (`rails.parse`; any other track gets the reason `track_type`). A track with another template, for example the quiet copies of Station Noise Barriers (`station_noise_walls_1::/quiet_tracks/...`), MUST NOT be selected or changed: the replacement by a base template would remove what the other template adds (the noise reduction). The hard-rule recheck before each command applies the same rule.
- A switch of the mode MUST clear a waiting selection, because the selection holds edges of one kind (`cancelPending("mode switch")` on the toolbar event).
- The brush MUST check the hard rules again on fresh engine reads right before each command.
- The keys M and N MUST change the brush radius by one step of `brush.RADII` (M larger, N smaller; a held key repeats), and the toolbar slider MUST follow. The keys are the input actions `constructOpt1` and `constructOpt2` of the game (the rotation keys; `settings_keys_v3.lua` binds them to M and N), so the player can rebind them. Only the instance whose world layer is mounted acts.
- While a selection waits for Upgrade (and Shift is not held), the roads under the ring that are not selected yet MUST show as the hover preview (light pink lines), as they do when nothing is selected. Selected roads stay red. The preview shares the line budget `hl.MAX_SEGMENTS` with the selection overlay.
- A road that already is what the upgrade would make of it MUST show blue instead of red (light blue instead of light pink in the hover preview). The test is the one the commit uses to leave a road alone (`upgrade.matcher`): road type, alley trees, noise barriers, bus lane, tram track, catenary, and lock of the toolbar. In the Rails mode the test is the per-track target of `rails.targeter`: a track is blue when it already has the template the upgrade would give it (track type and catenary state of the toolbar). The colour MUST follow a change of any of these settings while a selection waits. Such a road stays in the selection, and Upgrade leaves it unchanged. The blue lines are drawn by the overlay only: a road in blue MUST NOT be in `highlightedEntities`, because the engine tint has one colour.
- When the selection holds `sel.STROKE_CAP` (200) roads, the status chip MUST read `200 selected (max)` in the warning colour (yellow). This holds whether the cap stopped a stroke or the selection reached 200 exactly.
- The cursor tooltip MUST NOT show the radius and MUST NOT show the skip reasons. It keeps the hints, the cap note, and the message of the game.
- The tool MUST remember its settings during one game session: the radius, the road type, alley trees, noise barrier, "Remove buildings in the way", the track type, and the catenary state. The mode is not remembered: each menu entry opens in its own mode. Closing the tool and opening it again, or switching to another tool and back, keeps the last values. The values live in file-scope variables (`g_radius`, `g_toolParams` in `brush_upgrade.script.tl`) and are used as the defaults when the toolbar is built. They are lost when the GUI is rebuilt, for example when another save loads.
- After the user used other tools and selected the brush again, the ring MUST follow the pointer, strokes MUST select roads, and the toolbar buttons MUST work, also when the menu has created a second instance of the tool.

### Toolbar

- The tool MUST show all its params in one window, the toolbar on the left (`location = Toolbar`). It MUST NOT use the Settings callout of the default location. The order MUST be: mode, radius, Underground, the road options (road type, bus lane, tram track, catenary, alley trees, noise barrier, lock, remove buildings, the red notes), the rail options (track type, catenary state), the progress chip, the Upgrade and Clear buttons. The params of the other mode are hidden (`checkEnabledFn` returns `Hidden`; `onlyInMode` in `brush_options.tl`); radius, Underground, the chip, and the buttons show in both modes.
- The mode MUST be a two-button switch with the key `rub_mode` (1 Roads, 2 Rails). The road entry of the menu starts in Roads and the rail entry in Rails (`defaultIndex`; the remembered values of other params do not override it). The words are the game's own words for roads and tracks.
- The Rails mode MUST offer the track type as a combo box (`rub_trackType`: simple, standard, high speed; the names are the names the game gives the plain templates) and the catenary state as a combo box (`rub_trackCatenary`: Keep, Add, Remove; Keep is the default). The track type list MUST hold only the types the game offers in the game year (`rails.offeredTypes`: counted from the first whose plain template is available); the toolbar is built once at game load, so each list length has its own combo box (`rub_trackType` for all three types, `rub_trackType2` for two) and `checkEnabledFn` shows the one that matches the number of offered types; with one offered type there is no combo box. The catenary combo box MUST show only while the chosen type has its catenary template available (`rails.hasCatenary`), so it is hidden when no type has one. For a type without catenary the upgrade MUST give the tracks no catenary. The Rails mode has no red notes for the year.
- The radius slider MUST be labelled "Brush radius", and its tooltip MUST name the keys M and N.
- Enter MUST do what the Upgrade button does while a selection waits (phase `selected`). The tool registers the input actions `IA_NAV_ACTIVATE` and `IA_TEXT_ACCEPT`, which the game binds to Return and Keypad Enter. Only the instance whose world layer is mounted acts, and two reports within `ENTER_MIN_GAP` count as one. The tooltip of the Upgrade button MUST say it.
- A middle click on a road MUST copy its settings to the toolbar. The tool acts on the release of the middle button (event `Clicked` or `Released`) when the pointer moved at most `MMB_CLICK_MAX_PX` since the press (`Pressed` or `PressedOutside`), so a camera drag does nothing. The tool does not consume the middle events. It does nothing while an upgrade runs or the left button is down. Ctrl + click is not usable: the game takes it as a multi-select of entities, opens the entity details, and closes the tool before the tool sees the click. The road is the street under the pointer (`brush_clone.tl`): the pointer on the ground MUST lie within the width of the street, which is half the sum of the widths of its lanes (`laneConfigs`, sidewalks included, at least `MIN_HALF_WIDTH`) measured from the centre line. The lane offsets are small shifts and do not count. When several streets cover the point, the one with the nearest centre line wins. A click beside a street picks nothing. A tunnel counts only while the underground view is on, any other street only while it is off. A bridge above the point is not told apart from the ground below it. The copied settings are the road type (the base name of the street template without `_trees` and `_barriers`), alley trees or noise barriers (from that suffix), bus lane, tram track, and catenary (the combination that `carriesExtras` accepts for the street template), and the lock (a locked road sets Lock, any other road sets Keep). When no combination matches, bus lane, tram track, and catenary are set off and the status line MUST say that the lanes are edited. A one-way road type, a street template that is none of the road types of the tool, and a click with no street near the cursor MUST NOT change the toolbar and MUST show a note in the status line. The tooltip of the road type MUST name the middle click. In the Rails mode the middle click acts on the track under the pointer (`copyTrack`; the same pick with the tracks flag, width and position rules, at least `MIN_HALF_WIDTH`): it sets the track type and the catenary state (Add for a track with catenary, Remove for a track without), and nothing else. A track that belongs to a construction is copied too (the copy reads only). A track with a template that is none of the six base templates, a road under the pointer (note "That is a road: switch to Roads"), and a click with no track near the cursor MUST NOT change the toolbar and MUST show a note. In the Roads mode a track under the pointer shows the note "That is a track: switch to Rails". The tooltip of the track type MUST name the middle click.
- The brush tool MUST offer the six two-way road types, the alley trees option, and the noise barrier option. It MUST NOT offer the two one-way road types, and its description MUST say so.
- The brush tool MUST have the Underground button (key `undergroundMode`). When it is on, the brush shows the underground view and selects tunnels. The shortcut G (input action `IA_UNDERGROUND_MODE_TOGGLE`) MUST switch it, and the button MUST follow. When it is switched off, the underground view MUST be off again. While it is on, alley trees and noise barriers are disabled and ignored.
- The brush tool MUST offer the toolbar choice "Remove buildings in the way", on by default. When it is on, the commands use a context with `gatherBuildings` and `gatherFields` set, so a road that a building blocks is upgraded and the building is demolished. When it is off, such a road is skipped and the message of the game is shown.
- Error messages MUST be red and warnings MUST be yellow, in the game's theme colours (`Error` and `Warning` from `default_colors.gres`), set inline with `meta.styleSheet` (`brush_style.tl`). Errors: the notes about impossible combinations in the toolbar, "Cannot upgrade", "Upgrade failed", "No answer from the game", and a result with no upgraded road. Warnings: "Nothing selected" after a press without a selection, and `200 selected (max)`. Other text keeps its colour.
- After a run, the status chip MUST show the end status in its head line as `X updated, Y failed` (X = roads upgraded, Y = roads whose command failed in all attempts). The head MUST be green (theme colour `Ok`) when X > 0, with the part `Y failed` in yellow when Y > 0, and red when X is 0 and Y > 0. The detail line lists the unchanged roads, other skipped roads, the main reasons of the failures, and the cost. After a cancel the head is `Cancelled · X updated` in yellow. The end status MUST stay until the next stroke, the next upgrade, or Clear, also while failed roads are still selected.
- While an upgrade runs, the status chip MUST show the progress: the head `Upgrading n of N` and a text bar with the percentage. A road counts once in a pass, also when its command failed, so the first pass reaches 100 %. When a retry pass starts, the chip MUST show `Retrying failed ones a/b` with the bar for the roads of that pass. A third line MUST say `Cancel button stops the progress`, and the cursor tooltip MUST say the same.
- While an upgrade runs, the label of the Clear button MUST be `Cancel`. The label of the Clear button MUST be in the warning colour of the theme (yellow).

### Upgrade

- The brush tool MUST upgrade a segment with `api.engine.util.proposal.replaceSegment(edge, template)` and send the proposal with `api.cmd.makeWorldBuildProposalCmd`.
- The brush tool MUST offer bus lane, tram track, catenary, and lock. Each option MUST give the same result on a segment as the single-click tool of Road Upgrade All in One: bus lane removes the car from the outer driving lane on both sides, tram track adds the tram, catenary adds the electric tram, lock sets `roadDevelopmentLocked`. The tool applies them by editing `laneConfigs` and the lock flag of the added segment of the `replaceSegment` proposal (`applyExtras` in `bb_upgrade.tl`).
- The brush tool MUST NOT send a proposal whose lanes or lock flag do not read back as meant (`applyExtras`). The check covers every lane: the edited lanes read back as meant, and the other lanes as they were before the edit.
- The lock option MUST have three states, in this order: Keep (the lock of each road stays as it is), Lock (`roadDevelopmentLocked` true), Unlock (false). It is a combo box with the key `rub_lock`; a remembered 1 or 2 of the former check box reads as Keep or Lock. A road whose lock differs from Lock or Unlock is not the target (`carriesExtras`).
- With Tram track or Bus lane off, an upgrade removes a tram track or a bus lane that the road has (`carriesExtras`, `templateOuterModes`).
- In the Rails mode the brush MUST upgrade a track with the same `replaceSegment(edge, template)` and command, with a template that it computes per track (`rails.targeter`): the chosen track type, with the catenary of the track (Keep), with catenary (Add), or without (Remove). The base templates are `::/infrastructure/track/<type>/<type>.street_template` and `<type>_catenary.street_template` for the types `simple`, `standard`, and `high_speed`. The proposal needs no lane edit and no decoration. A track that already has its target template MUST be left alone and counted as unchanged. A track with no target (a template that is none of the six, or a target that is not available in the game year) MUST be left alone, leave the selection, and count as skipped with the reason "other track type". The hard rules keep tracks (`assertHardRules` with the kind `track`) instead of roads. The Rails mode sends the commands with `removeBuildings` false, and the toolbar has no such choice for it. Everything else (pause, one command per edge, retry passes, cancel, cost, the cap of 200) is the same as for roads.
- The log line of the proposal of every edge MUST name the number of edge objects (signals, stops) of the old edge and of the new segment, and MUST mark `OBJECTS LOST` when the new segment has fewer. A status warning for lost objects is not implemented (no loss was seen; see Decisions).
- The brush MUST leave a road alone, with no command and no charge, when it already has the target street template and, for a template that brings edge decorations, the same decorations. The result line counts these roads as "unchanged", not as skipped.
- The brush MUST send the commands for all roads first, then try each road whose command failed again. It MUST make two such retry passes, each after all other roads. A road that fails in all three attempts is skipped with the last message of the game and stays selected. The result counts a road that a retry upgraded as upgraded.
- After a press, the roads whose command failed in all attempts MUST stay selected and highlighted, and all other roads MUST leave the selection. Another press then tries only those roads. When no road failed, the selection clears.
- While an upgrade runs, a road MUST leave the selection and the highlight as soon as it is done: upgraded, already the target, or dropped by the hard rules. The commit reports each road through the callback `onRoad` (`bb_status.tl`).
- The brush MUST send its commands only while the game is paused (game speed 0). When the game runs, the brush MUST pause it with `api.cmd.makeGameSetSpeedCmd(0)`, check the speed afterwards, and set the old speed back when the upgrade is done. Before every command it MUST check the pause again, because the player may unpause. A game speed that cannot be read counts as "cannot pause". When the game cannot be paused, the brush MUST send no further command, keep the roads selected, and show the red message "Pause the game first".
- The brush MUST wait 0.1 seconds after each sent command before it builds and sends the next one. The tool recipe drives the wait with `commit.tick()` on every step.
- The recipe MUST give a commit at least 120 seconds without progress (each finished road restarts the time) before it stops waiting for the result. It then MUST end the commit with `commit.abort()`: the commit ignores every later callback, sets the old game speed back, and frees the commit slot. The chip shows "No answer from the game".
- Only one commit runs at a time. A new commit while one runs MUST send nothing, keep the roads selected, and show "Nothing upgraded: previous upgrade still running".
- An error while a command is prepared MUST fail that road with "script error" and the run goes on.
- Esc while an upgrade runs SHOULD stop the upgrade after the road in progress and leave the tool open, as the Clear button does (`cancelUpgrade` in the tool script). When the tool is closed while an upgrade runs, the brush MUST cancel the upgrade after the road in progress, so that the game speed is set back. Without a running upgrade, Esc clears a selection first and leaves the tool when nothing is selected.
- With "Remove buildings in the way" on, the brush MUST handle a road that fails with a single message and whose only colliding entities (besides the road itself) are asset groups. The first retry of that road puts the asset groups in the `toRemove` list of its proposal; the last retry also sends the command with `ignoreErrors` set. The test does not compare the message text, because the game translates it. Asset groups that no longer exist MUST be dropped from the list. Any other collision (a road, a construction, a node, a mix) MUST NOT be forced. The log line of such a retry names the number of asset groups and whether `ignoreErrors` was used.
- A town road with building lots, which the game refuses with "Unexpected parcel on a segment", is a known limit. The brush MUST report such a road as failed, MUST keep it selected, and MUST NOT remove any house or lot for it. The user upgrades these roads with the single-click tool of Road Upgrade All in One.
- The cost MUST be shown after the upgrade, from the cost the game reports for each command. A cost before the upgrade is not available.
- The failure log line of a road MUST describe the road (normal, bridge or tunnel; template; edge objects; decorations), so the reason for a repeated failure can be found in the log.

## Facts

### Paths and tools

| Item | Value |
|---|---|
| Game install | `C:\Program Files (x86)\Steam\steamapps\common\Transport Fever 3\` |
| Test mod folder parent | `C:\Program Files (x86)\Steam\userdata\56068363\3493540\local\staging_area\` (this spec file and the git root sit there) |
| Game log | `C:\Program Files (x86)\Steam\userdata\56068363\3493540\local\crash_dump\stdout.txt` (the game overwrites it at every start) |
| Type definitions | `api\tealdef\` and `base\tealdef\` in the install folder, plus `vscode-template\` |
| mod.io copies of the original mods (do not edit) | `C:\Users\Public\mod.io\10640\mods\6487083\` (Road Upgrade All in One), `...\6434884\` (Bulk Bulldozer) |
| Teal compiler | Teal 0.24.8 at `C:\Users\Kacsa\tools\teal\tl-0.24.8-windows-x86_64\tl.exe` (not on PATH). Run it from `staging_area\`, for example `tl check kacsa_road_upgrade_brush/content/road_upgrade_brush/bb_upgrade.tl`. |
| Type check setup | `staging_area\tlconfig.lua` (includes the game's `api/tealdef` and `base/tealdef` and the mod's `content`) and `staging_area\all_def.tl` (copy of the game's `vscode-template`, loads `road_upgrade_brush.rub_types`) |
| Lua | Lua 5.5 with scoop (`luac55 -p` checks the syntax of generated Lua) |
| Vanilla script source | Not readable in the install folder. The unpacked copy of `gui.zip` is at `C:\Users\Kacsa\tools\tf3-gamesrc\`. |

### Mod format (wiki.transportfever3.com)

- A mod folder holds `mod.json`, an optional `strings.json`, and `content/` for resources.
- `modId` MAY contain only `a-z`, `0-9`, and `_`. The recommended form is `<author>_<modname>`.
- `mod.json` hooks are `preRunScript`, `runScript`, and `postRunScript`, written as `<modid>::<file>@<function>`.
- Scripts are Lua, usually the Teal dialect (`.tl`). `local` is mandatory. Imports use `ug_require "<modid>::/path/file.tl" as TypeName`.
- A `.res.lua` file registers a resource. The tool resource has `type = "construction_tool"` and a `getDefinitionFn` that points to a script function.
- The mod uses `strings.json` for text, with keys per language. A text without a key shows as written in the code.

### Origin of the copied code

| Source | Files in this mod |
|---|---|
| Road Upgrade All in One (`road_upgrade_suite`, mod.io 6487083, kurowasiichi) | `rub_config`, `rub_options`, `rub_rules`, `rub_templates`, `rub_types.d.tl`, and the English and Traditional Chinese texts of `strings.json`, with renamed paths, keys, and types |
| Bulk Bulldozer (`square_bulk_bulldozer`, mod.io 6434884, square17) | `bb_brush`, `bb_select`, `bb_gather`, `bb_highlight`, `bb_status`, `bb_types.d.tl`, `brush_upgrade.css.lua`, `sqperf/*`, and the recipe in `brush_upgrade.script.tl`, with a new module prefix, `STROKE_CAP` 200 (the original has 400), and no removal code. 38 texts of `strings.json` in 12 languages are its translations, and a few more in some languages. |
| This mod | `bb_upgrade.tl` (the upgrade commit), `brush_options.tl`, `brush_style.tl`, `brush_clone.tl`, `brush_rails.tl`, `brush_types.d.tl`, `proposal_probe.tl`, the icons, and the image |

- Road Upgrade All in One sends no command. It fills a `streetEdgeNodeModifier` and returns the vanilla action `ACTION_STREET_BUILDER_UPGRADER`; the game builds and sends the command on click. Its `config.tl` lists eight road types (the last two are one-way); trees and barriers are templates with the suffixes `_trees` and `_barriers`; country roads have no trees template; `templates.resolve` picks the newest available template for the current year; `rules.check` returns the problems of an option combination.
- Bulk Bulldozer removes entities with `makeSegmentsRemoveProposal`. The brush copies its selection, highlight, status, and recipe code, not its commit or batch code.

### Game API

- `api.engine.util.proposal.replaceSegment(entity, streetTemplate?) : Proposal` refreshes a street or track segment. The type definition says "Use with caution" (`api\tealdef\api\engine\util.d.tl:987-991`).
- The `StreetEdgeNodeModifier` (`base\tealdef\scripts\builtin.d.tl:157-187`) has `busLane`, `tramTrackType`, `symmetricLanes`, `overrideLaneConfigs`, `overrideEdgeDecorations`, `roadDevelopmentLocked`, and more. No API applies it to a proposal: the vanilla tools only fill it (`gui/construction/construction_react_util.tl:3181-3316`) and the engine applies it on click.
- `Proposal` is a userdata type with no way to merge two proposals. Its field `proposal : StreetProposal` holds `addedSegments`, `removedSegments`, and node and edge object lists. Each added segment has `comp : BaseEdge` with `roadTemplate`, `laneConfigs`, `edgeDecorations`, and `roadDevelopmentLocked`. The getters may hand out copies, so edits are written back at every level.
- `replaceSegment` keeps the `edgeDecorations` of the old road, while the street template carries its own in `defaultEdgeDecorations`. The brush writes the decorations of the template.
- `makeProposalData` rejects the proposal of `replaceSegment` in every form (`bad argument #2 ... SimpleProposal expected, got Proposal`). So the cost is unknown before the command and known from its result.
- A replaced segment may get a new entity id.
- Tracks are street templates too (`roadType = "TRACK"`, one lane of width 4, `trackDistance` 5). The base game has `simple` (catenary from 1921), `standard` (from 1930), and `high_speed` (from 1980), each with a `_catenary` twin; `catenaryAdd` and `catenaryRemove` of a template name the twin. A track edge keeps its template in `BASE_EDGE.roadTemplate`, and its lane has the modes TRAIN and TRAM_TRACK, and with catenary also ELECTRIC_TRAIN and ELECTRIC_TRAM_TRACK. `BaseEdge.objects` holds `{entity, EdgeObjectType}` pairs (`SIGNAL`, `STOP_LEFT`, `STOP_RIGHT`).
- The game lists many more templates under `/track/`: the variants `_dv`, `_dvf`, `_dvp`, and `_dvs` of each base type, and the quiet copies that Station Noise Barriers (`station_noise_walls_1`) registers as `station_noise_walls_1::/quiet_tracks/<path>` with `noiseModifier` lowered by 0.65 for the track modules of stations with a noise wall. The `catenaryRemove` of a quiet copy names the plain base template.
- The vanilla proposal for one hovered road replaces many connected segments; `replaceSegment` replaces one segment per road.

### Lanes and transport modes

- The transport mode numbers are PERSON 0, CARGO 1, CAR 2, BUS 3, TRUCK 4, TRAM 5, ELECTRIC_TRAM 6.
- The game gives out the modes of a lane as a table with the mode numbers 0 to 15 as keys and booleans as values. It takes them in as a complete list of 16 booleans, one per mode, counted from 1: the mode number plus one is the index. A table with only some indexes gives the lane the modes 0 and 1. A lane written back with the keys it was read with comes out with every mode one number lower.
- A wrong write gives a vehicle lane the cargo mode and the game stops in its transport network (`TransportNetworkSystem.cpp IsValidTransition: Assertion 'person0 == person1' failed`).
- The lanes of the added segment per option (`<` and `>` are the two directions):

| Options on | Lanes |
|---|---|
| none | `<0+1 <2+3+4 >2+3+4 >0+1` |
| Bus lane | `<0+1 <3+4 >3+4 >0+1` (car removed from the outer driving lane) |
| Tram track | `<0+1 <2+3+4+5 >2+3+4+5 >0+1` |
| Tram track and catenary | `<0+1 <2+3+4+5+6 >2+3+4+5+6 >0+1` |
| Lock | `roadDevelopmentLocked true` on the added segments |
| Unlock | `roadDevelopmentLocked false` on the added segments |

### Failures

- Town roads with building lots on both sides fail with "Construction Not Possible; Unexpected parcel on a segment" on every press. The single-click tool upgrades many of them: its proposal puts the houses on the lots (constructions with one town building) in `toRemove` (removed) and `toAdd` (moved). `townBuildingSystem.getBuilding(parcel)` returns the TOWN_BUILDING entity; its `construction` field is the entity of the `toRemove` list. The brush with the houses of the lots in `toRemove` still fails with "Parcel N for segment M is not removed". With the lot entities in `toRemove`, `makeWorldBuildProposalCmd` throws "Unknown exception" in `PreprocessProposal`. `parcelSystem.getParcelData(segment)` returns a native object with the lists `leftEntities` and `rightParcels`.
- A road that an asset group blocks fails with the single message "Collision". An asset group is an entity with the component `ASSET_GROUP` (and no `BASE_EDGE`, `CONSTRUCTION`, or `BASE_NODE`). Putting it in `toRemove` upgrades the road. Roads that share one asset group make the removal list of a later road hold an entity that is gone, and the game throws "Unknown exception"; so the list is filtered with `api.engine.entityExists`. Other mods send the same proposal with `ignoreErrors` on (Build Anyway). Other "Collision" failures exist whose entities are not asset groups; the brush does not force them.
- Further refusals ("Too Much Incline", "Construction Not Possible") are reported as failed with the message of the game.
- The game crashes when commands run at a running game speed (speed 4: a crash after 4 commands of a press of 40 roads), probably because the simulation moves vehicles on the roads that a command replaces. At speed 0 a press of 34 roads ran 47 commands without a crash. Rare crashes also occurred at speed 0, in the code of the game while it validated the proposal of a road with a large junction; the cause is not confirmed. Reading parcels and components of colliding entities in the command callback is not done, because the crashes happened right before that callback returned.
- The mod Smart Lanes (`square_smart_lanes`) rewrites junctions after each build; it was examined as a cause and not confirmed.
- A press runs at about 0.43 s per road with the 0.1 s wait (193 roads in 82 s).

### Menu, input, and instances

- The menu has two parameter windows. Params with `location = Toolbar` go to the toolbar on the left; params without it go to a callout titled Settings.
- Slider params with `numbers` give the number (metres for the radius) to `onChangeFn`.
- The game registers the shortcut G only for tools whose action has a street, bulldozer, or similar builder (`construction_react_util.tl:3882-3895`), and it answers the request `streetBuilderRequestUnderground` only for its own builder tools. The brush handles G itself and changes the toolbar button through the params API of the menu. It keeps that API from the call of `construction_react_util.getActionParams` (the 8th argument, `refSublistParams`; `installApiCapture` in the tool script).
- The Underground button only switches the underground view and the selection filter; it does not make roads tunnels.
- The game gives Esc to its own menu when the keyboard focus sits on the toolbar, which is usually the case after a click on Upgrade. The menu then closes the construction mode and the tool cannot take the key. The Cancel button works in every case. Esc was not observed to cancel a running upgrade.
- Mods cannot add input actions. M and N are the rotation keys of the game.
- The menu can create a second instance of the tool recipe, and the world layer that stays mounted can belong to the older instance. Then the newest instance passes its params to the instance that owns the layer (`g_layerOwnerId`, `g_layerOwnerSetParam`), and only that instance steps and handles the clicks.
- The game sets the tooltip of a toolbar param once, when the component is created, and updates it only when the name, labels, numbers, or type of the param change (`construction.tl` `ConstructionParam`, `refTooltip`). Components are matched by position. A slider with the same name, labels, and values as the slider of another tool shows the tooltip of that tool. This is why the brush slider is labelled "Brush radius", not "Radius" (the label of Bulk Bulldozer).
- Shared by design with Bulk Bulldozer: the toolbar style (the style rules of `brush_upgrade.css.lua` are skipped when Bulk Bulldozer or Smart Lanes is active), the developer master switch mod `square_sqperf_all` (it turns on the debug log of this mod), and the menu category `roads_tools` with order 5.

### Verified in the game

- Road types, alley trees, noise barriers, bus lane, tram track, catenary, lock, and the Underground button with the shortcut G.
- Upgrading presses of up to 200 roads, the retry passes, the automatic pause, the Cancel button, and the removal of a tram track and a bus lane when their options are off.
- The removal of asset groups on the first retry and the option "Remove buildings in the way".
- The keys M and N, the hover preview over a waiting selection, the chip `200 selected (max)`, and the "Brush radius" label with its tooltip.
- The pause path (a press at speed 0 and at speed 1 with the speed set back) and the lane check with the bus lane (`edit verified` on every road).
- Closing the tool during a run cancels the run after the road in progress and sets the game speed back.
- The brush appears once in the menu, with and without the original mods.
- Tracks (probe builds `bg` and `bh`, test save): `replaceSegment` with a track edge and a base track template succeeds and sends as one command; the track keeps its nodes and gets a new entity id; a change of the track type keeps the catenary state; the lane modes follow the template (ELECTRIC_TRAIN only with catenary); a `SIGNAL` on the edge is still on the new edge; the second registration file adds the tool to the rail tools tab (`rail_tools`); a track with a Quiet Tracks template is refused when it is not a base template.
- The Rails mode (build `bi`): the mode switch with the hidden params, the clearing of the selection by a switch, the filters per mode, tracks with a Quiet Tracks template are not selected (reason `track_type`), blue marking and "already the target" for 6 tracks, an upgrade of 6 tracks to simple with Keep and to high speed with Add (6 commands, all ok, a signal kept on its track), and the middle click copy of a track.
- The middle click copies the settings of a track that belongs to a construction (a station track), although the brush cannot select it. This is kept: the copy only reads the template.

### Not verified in the game

- Enter: whether `IA_NAV_ACTIVATE` or `IA_TEXT_ACCEPT` reaches the tool (the log line `Enter (...): upgrade` names it), and whether a focused toolbar button also reacts to the same key.
- Middle click: whether the events arrive (the log lines `middle …` name them), the street pick, the toolbar changes by `changeParam` for the combo box, the check boxes, and the catenary, the order of the steps with alley trees and noise barriers, and the status notes.
- The lock states Keep, Lock, and Unlock on a press, and the Unlock read-back.
- The blue colour of roads that already are the target, its update when a toolbar setting changes, and its cost with 200 roads (the `same_roads` entry of the `sqperf` log).
- Tram track and lock with the check of every lane, and the bus lane together with the tram track.
- The rule for an unreadable game speed, the abort after 120 s, and the refusal of a second commit. The situations did not occur in testing.
- The asset-group decision without the message text.
- The display of the translations in the game: whether the texts of `strings.json` show in each of the 12 languages, whether the long texts fit, and whether the text of `strings.json` or the text of the game wins for the same word.
- The forced build (`ignoreErrors`) on the last retry.
- The Rails mode, the notes and texts in all 13 languages, and the blue colour of tracks that match a Keep choice after a type change.
- Waypoints (`SIGNAL` objects were tested), tracks on bridges and in tunnels, tracks with stop objects, and trains that run on the tracks during an upgrade (the pause handling is the one of roads).
- That the track type list grows, and the catenary choice appears per type, when a later year makes more available.
- Esc cancelling a running upgrade when the keyboard focus is on the map.
- Whether the menu builds the toolbar again on each open.

## Mod layout

All paths are under `kacsa_road_upgrade_brush\content\`.

| Path | Role |
|---|---|
| `road_upgrade_brush/brush_upgrade.script.tl`, `.res.lua`, `.css.lua`, `brush_upgrade_rail.res.lua` | The tool: definition, toolbar params, recipe (mouse, brush, highlight, selection, buttons), and the toolbar style. The two `.res.lua` files are the two menu entries (roads, rail) of the same script. |
| `road_upgrade_brush/bb_brush`, `bb_select`, `bb_gather`, `bb_highlight`, `bb_status`, `bb_types.d.tl` | Brush geometry, selection rules, octree reads, highlight lines, status text, and the global types |
| `road_upgrade_brush/bb_upgrade.tl` | The upgrade commit: hard-rule recheck per road, one `replaceSegment` proposal per road, lane and lock edits, pause handling, retry passes, asset-group handling, result counts |
| `road_upgrade_brush/brush_options.tl`, `brush_types.d.tl`, `brush_style.tl` | The toolbar options of the brush (the six two-way road types and the add-ons), the street template for the chosen options, setting the options from a copied road, and the style of the red and yellow texts |
| `road_upgrade_brush/brush_clone.tl` | Middle click: finds the street or the track under the pointer and reads its settings |
| `road_upgrade_brush/brush_rails.tl` | The six base track templates: name, parse, availability, and the per-track target of an upgrade |
| `road_upgrade_brush/rub_config`, `rub_options`, `rub_rules`, `rub_templates`, `rub_types.d.tl` | Road types, options, rules, and templates from Road Upgrade All in One |
| `road_upgrade_brush/proposal_probe.tl` | Diagnostics. `probe.ENABLED = false` switches off all diagnostic log lines (probe, instances, world layer, cursor, segment to send). `probe.install` has no caller. |
| `sqperf/kacsa_road_upgrade_brush.lua`, `..._types.d.tl` | Performance log; `mod.json` has its parameter `sqperf_log` |
| `gui/road_upgrade_brush/` | The tool icon and its preview |

Names that differ from Bulk Bulldozer, so that both run together: the log prefix `[BrushUpgrade]`, the events `BrushUpgrade.*`, the toolbar keys `brush_upgrade_*`, the recipes `BrushUpgradeAction` and `BrushUpgradeStatus`, the tool id `brush-upgrade-tool`, and the global Teal types with the prefix `Rub`.

## Decisions

- The cap and the command budget stay equal. A cap larger than the budget would highlight more roads than one press upgrades.
- The cost is shown after the upgrade only. The tool script does not preview it.
- The brush has no one-way road types. The tool description and the README say so.
- A road upgraded through the brush gets the lanes of the chosen street template. The brush removes a tram track or a bus lane when its option is off. It changes the lock only with Lock or Unlock.
- The copy sets a road without a lock to Keep, not to Unlock. Unlock would remove the lock from every road of the next upgrade, which a copy of one road does not mean.
- The brush does not remove houses or lots. It removes asset groups on a retry.
- One tool with a mode switch, not a second tool: the selection, blue marking, Enter, copy, Cancel, and the retry passes stay shared. A second registration file gives the rail menu entry its own category and start mode. If the game refused two entries from one script, the fallback would be one entry listed in both menus.
- The catenary state of the Rails mode has three states, with Keep as the default, so a change of the track type does not strip the catenary from electric lines. The road tool's yes/no catenary would remove it by default.
- Only the six base templates are offered. Tracks with another template are never changed, because the swap to a base template would drop what the template adds (the quiet copies of Station Noise Barriers lose their noise reduction).
- A switch of the mode clears a waiting selection. A hidden selection of the other kind would need two sets in the count, the highlight, and the cap.
- The copy of a track sets Add or Remove, not Keep, because it copies what the track has.
- Lost edge objects: the choice was to upgrade anyway and warn. The probe builds lost none, so the commit only logs `OBJECTS LOST` per edge and shows no status warning. If a test shows a loss, the warning (a count of tracks that lost objects in the result line) is added.
