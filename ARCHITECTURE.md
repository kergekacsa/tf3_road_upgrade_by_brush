# Architecture

How the mod is built, which rules its code follows, and what the game does that the type definitions do not show. The player-facing behaviour is in `README.md`, the terms are in `CONTEXT.md`, and the reasons for the main design choices are in `docs/adr/`. This file sits next to the mod folder, so it is not part of the uploaded mod.

## Mod layout

All paths are under `kacsa_road_upgrade_brush\content\`.

| Path | Role |
|---|---|
| `road_upgrade_brush/brush_upgrade.script.tl`, `.res.lua`, `.css.lua`, `brush_upgrade_rail.res.lua` | The tool: definition, toolbar params, recipe (mouse, brush, highlight, selection, buttons), and the toolbar style. The two `.res.lua` files are the two menu entries (roads, rail) of the same script. |
| `road_upgrade_brush/bb_brush`, `bb_select`, `bb_gather`, `bb_highlight`, `bb_status`, `bb_types.d.tl` | Brush geometry, selection rules, octree reads, highlight lines, status text, and the global types. |
| `road_upgrade_brush/bb_upgrade.tl` | The upgrade commit: hard-rule recheck per road, one `replaceSegment` proposal per road, lane and lock edits, pause handling, retry passes, asset-group handling, result counts. |
| `road_upgrade_brush/brush_options.tl`, `brush_types.d.tl`, `brush_style.tl` | The toolbar options of the brush (the six two-way road types and the add-ons), the street template for the chosen options, setting the options from a copied road, and the style of the red and yellow texts. |
| `road_upgrade_brush/brush_layer.tl` | The state of the world layer of every instance of the tool recipe, its owner, which instance may take it on a mouse event, which instance hands its tool state to the owner, and the test for a stuck ring. |
| `road_upgrade_brush/brush_clone.tl` | Middle click: finds the street or the track under the pointer and reads its settings. |
| `road_upgrade_brush/brush_rails.tl` | The six base track templates: name, parse, availability, and the per-track target of an upgrade. |
| `road_upgrade_brush/rub_config`, `rub_options`, `rub_rules`, `rub_templates`, `rub_types.d.tl` | Road types, options, rules, and templates from Road Upgrade All in One. |
| `road_upgrade_brush/proposal_probe.tl` | Diagnostics. The mod option "Debug: upgrade log" (`rub_log` in `mod.json`, Off by default) switches all of them on. See "Diagnostic log". |
| `sqperf/kacsa_road_upgrade_brush.lua`, `..._types.d.tl` | Performance log. `mod.json` has its parameter `sqperf_log`. It is independent of `rub_log`. |
| `gui/road_upgrade_brush/` | The tool icons and their previews. |

## Conventions

- The mod id is `kacsa_road_upgrade_brush`. It does not change.
- The mod MUST be independent: no mod dependency. It MUST work with and without Road Upgrade All in One (`road_upgrade_suite`) and Bulk Bulldozer switched on.
- Every file path and text key MUST be unique: `road_upgrade_brush/rub_*`, `rub_*` keys, `gui/road_upgrade_brush/`. Every global Teal type name carries the prefix `Rub`. Global names are shared by all loaded mods.
- Names that differ from Bulk Bulldozer, so that both run together: the log prefix `[BrushUpgrade]`, the events `BrushUpgrade.*`, the toolbar keys `brush_upgrade_*`, the recipes `BrushUpgradeAction` and `BrushUpgradeStatus`, and the tool id `brush-upgrade-tool`.
- Shared with Bulk Bulldozer by design: the toolbar style (the style rules of `brush_upgrade.css.lua` are skipped when Bulk Bulldozer or Smart Lanes is active), the developer master switch mod `square_sqperf_all` (it turns on the debug log of this mod), and the menu category `roads_tools` with order 5.
- The mod MUST keep the original authors' names in the headers of copied files, including `rub_types.d.tl`. The README names the copied texts of `strings.json`, which cannot carry a header.
- The mod MUST NOT add a single-click upgrade tool, a Bulldoze button, or any removal code.
- The mod folder MUST hold only files that the mod needs, with lowercase names. It MUST NOT ship image files of another mod.
- `strings.json` MUST hold every text that the code and `mod.json` pass to the translation, in the 12 languages of the game besides English. English uses the text as written in the code. A text with the same English words as a text of the game (`base.mo`) MUST use the game's translation. The exception is a word that is a mistranslation for this use (Off in Italian: the game says Mai, the mod says No).
- The names of the road types MUST be the names the game gives to its street templates.
- A text of the status chip MUST fit `status.MAX_CHARS` (36 columns, CJK characters count 2) in every language. The chip shows the short problem texts (`rub_chip_*`). The toolbar notes show the full texts (`rub_problem_*`).
- Every reason text of the commit MUST have an entry in the label table of `bb_status.tl`.
- A comment in the code MUST state only a contract, an invariant, a unit, or a constraint that holds now. Generated Lua is the same before and after a comment change.

## Origin of the copied code

| Source | Files in this mod |
|---|---|
| Road Upgrade All in One (`road_upgrade_suite`, mod.io 6487083, kurowasiichi) | `rub_config`, `rub_options`, `rub_rules`, `rub_templates`, `rub_types.d.tl`, and the English and Traditional Chinese texts of `strings.json`, with renamed paths, keys, and types |
| Bulk Bulldozer (`square_bulk_bulldozer`, mod.io 6434884, square17) | `bb_brush`, `bb_select`, `bb_gather`, `bb_highlight`, `bb_status`, `bb_types.d.tl`, `brush_upgrade.css.lua`, `sqperf/*`, and the recipe in `brush_upgrade.script.tl`, with a new module prefix, a cap of 200 (the original has 400), and no removal code. 38 texts of `strings.json` in 12 languages are its translations, and a few more in some languages. |
| This mod | `bb_upgrade.tl` (the upgrade commit), `brush_options.tl`, `brush_style.tl`, `brush_clone.tl`, `brush_rails.tl`, `brush_layer.tl`, `brush_types.d.tl`, `proposal_probe.tl`, the icons, and the image |

- Road Upgrade All in One sends no command. It fills a `streetEdgeNodeModifier` and returns the vanilla action `ACTION_STREET_BUILDER_UPGRADER`. The game builds and sends the command on click. Its `config.tl` lists eight road types (the last two are one-way). Trees and barriers are templates with the suffixes `_trees` and `_barriers`. Country roads have no trees template. `templates.resolve` picks the newest available template for the current year. `rules.check` returns the problems of an option combination.
- Bulk Bulldozer removes entities with `makeSegmentsRemoveProposal`. The brush copies its selection, highlight, status, and recipe code, not its commit or batch code.
- Mod copies for reference (do not edit): `C:\Users\Public\mod.io\10640\mods\6487083\` (Road Upgrade All in One) and `...\6434884\` (Bulk Bulldozer).

## Game API

- `api.engine.util.proposal.replaceSegment(entity, streetTemplate?) : Proposal` refreshes a street or track segment. The type definition says "Use with caution" (`api\tealdef\api\engine\util.d.tl:987-991`). The brush upgrades one segment per road with it and sends the proposal with `api.cmd.makeWorldBuildProposalCmd`.
- The `StreetEdgeNodeModifier` (`base\tealdef\scripts\builtin.d.tl:157-187`) has `busLane`, `tramTrackType`, `symmetricLanes`, `overrideLaneConfigs`, `overrideEdgeDecorations`, `roadDevelopmentLocked`, and more. No API applies it to a proposal. The vanilla tools only fill it (`gui/construction/construction_react_util.tl:3181-3316`) and the engine applies it on click.
- `Proposal` is a userdata type with no way to merge two proposals. Its field `proposal : StreetProposal` holds `addedSegments`, `removedSegments`, and node and edge object lists. Each added segment has `comp : BaseEdge` with `roadTemplate`, `laneConfigs`, `edgeDecorations`, and `roadDevelopmentLocked`. The getters may hand out copies, so edits MUST be written back at every level.
- `replaceSegment` keeps the `edgeDecorations` of the old road, while the street template carries its own in `defaultEdgeDecorations`. The brush writes the decorations of the template.
- `makeProposalData` rejects the proposal of `replaceSegment` in every form (`bad argument #2 ... SimpleProposal expected, got Proposal`). So the cost is unknown before the command and known from its result.
- The base game tools change the template, not only the lanes: the bus lane tool gives the `_bus` template (`country_new_medium_bus`, outer lanes without the car), the tram track tool gives the `_tram` template (`town_old_large_tram`), and the upgrade mode with a tram gives `_tram_electrified` (`town_new_small_tram_electrified`). The vanilla proposal for a road with lots has the lot houses in `toRemove` (`moved` or `removed`, one construction each) and the moved ones again in `toAdd`; the game warns "N Buildings Will Be Moved; M Buildings Will Be Removed".
- A replacement with the template the road already has: the new segment keeps the lock flag, its lanes are rebuilt from the template (a tram track with catenary is gone), and it keeps the old `edgeDecorations`. So a change to the plain template does not remove alley trees by itself. Each replacement gives the road a new entity id.
- The vanilla proposal for one hovered road replaces many connected segments. `replaceSegment` replaces one segment per road.
- Tracks are street templates too (`roadType = "TRACK"`, one lane of width 4, `trackDistance` 5). The base game has `simple` (catenary from 1921), `standard` (from 1930), and `high_speed` (from 1980), each with a `_catenary` twin. `catenaryAdd` and `catenaryRemove` of a template name the twin.
- A track edge keeps its template in `BASE_EDGE.roadTemplate`. Its lane has the modes TRAIN and TRAM_TRACK, and with catenary also ELECTRIC_TRAIN and ELECTRIC_TRAM_TRACK. `BaseEdge.objects` holds `{entity, EdgeObjectType}` pairs (`SIGNAL`, `STOP_LEFT`, `STOP_RIGHT`).
- The game lists many more templates under `/track/`: the variants `_dv`, `_dvf`, `_dvp`, and `_dvs` of each base type, and the quiet copies that Station Noise Barriers (`station_noise_walls_1`) registers as `station_noise_walls_1::/quiet_tracks/<path>` with `noiseModifier` lowered by 0.65 for the track modules of stations with a noise wall. The `catenaryRemove` of a quiet copy names the plain base template.
- The game has a noise barrier for tracks as an edge decoration: `barrier_track_a.edge` (wooden, until 1939) and `barrier_track_b.edge` (concrete, from 1940), set on both sides as `{id, false}` and `{id, true}` in `edgeDecorations`. A change of the barrier alone is a full replacement of the track by the same template, so the game charges the template cost for it, also for Remove.

## Lanes and transport modes

- The transport mode numbers are PERSON 0, CARGO 1, CAR 2, BUS 3, TRUCK 4, TRAM 5, ELECTRIC_TRAM 6.
- The game gives out the modes of a lane as a table with the mode numbers 0 to 15 as keys and booleans as values. It takes them in as a complete list of 16 booleans, one per mode, counted from 1: the mode number plus one is the index. A table with only some indexes gives the lane the modes 0 and 1. A lane written back with the keys it was read with comes out with every mode one number lower.
- A wrong write gives a vehicle lane the cargo mode, and the game stops in its transport network (`TransportNetworkSystem.cpp IsValidTransition: Assertion 'person0 == person1' failed`). So the brush MUST NOT send a proposal whose lanes do not read back as meant.
- The lanes of the added segment per option (`<` and `>` are the two directions):

| Options on | Lanes |
|---|---|
| none | `<0+1 <2+3+4 >2+3+4 >0+1` |
| Bus lane | `<0+1 <3+4 >3+4 >0+1` (car removed from the outer driving lane) |
| Tram track | `<0+1 <2+3+4+5 >2+3+4+5 >0+1` |
| Tram track and catenary | `<0+1 <2+3+4+5+6 >2+3+4+5+6 >0+1` |
| Lock | `roadDevelopmentLocked true` on the added segments |
| Unlock | `roadDevelopmentLocked false` on the added segments |

## Failures

- Town roads with building lots on both sides fail with "Construction Not Possible; Unexpected parcel on a segment" on every press. The single-click tool upgrades many of them: its proposal puts the houses on the lots (constructions with one town building) in `toRemove` (removed) and `toAdd` (moved). `townBuildingSystem.getBuilding(parcel)` returns the TOWN_BUILDING entity, and its `construction` field is the entity of the `toRemove` list. The brush with the houses of the lots in `toRemove` still fails with "Parcel N for segment M is not removed". With the lot entities in `toRemove`, `makeWorldBuildProposalCmd` throws "Unknown exception" in `PreprocessProposal`. `parcelSystem.getParcelData(segment)` returns a native object with the lists `leftEntities` and `rightParcels`. Calling it crashes the game (an access violation in `TransportFever3.exe`). The mod MUST NOT call it. The houses of the lots are in `toRemove` and `toAdd` of the proposal of the base game tool.
- A road that an asset group blocks fails with the single message "Collision". An asset group is an entity with the component `ASSET_GROUP` (and no `BASE_EDGE`, `CONSTRUCTION`, or `BASE_NODE`). Putting it in `toRemove` upgrades the road. Roads that share one asset group make the removal list of a later road hold an entity that is gone, and the game throws "Unknown exception". So the list MUST be filtered with `api.engine.entityExists`. Other mods send the same proposal with `ignoreErrors` on (Build Anyway). Other "Collision" failures exist whose entities are not asset groups, and the brush does not force them.
- Further refusals ("Too Much Incline", "Construction Not Possible") are reported as failed with the message of the game.
- Rare crashes occurred at speed 0, in the code of the game while it validated the proposal of a road with a large junction. The cause is not confirmed. No code of the mod reads parcels. The callback of a build command MUST read only the result data, the own `BASE_EDGE` of the road, the `ASSET_GROUP` component of the colliding entities, and the `GAME_SPEED` and `GAME_TIME` components of the world.

## Diagnostic log

- The option "Debug: upgrade log" (`rub_log` in `mod.json`, Off by default) switches the diagnostics on. With the option Off the probe reads no road and no proposal.
- `installApiCapture` hooks `getProposalStringsFn` of three base game tools (the street builder in upgrade mode, the bus lane tool, the tram track tool) and logs their proposal under the cursor. The hook reads components inside a callback of the base game, with the option On only.

## Menu, input, and instances

- The menu has two parameter windows. Params with `location = Toolbar` go to the toolbar on the left. Params without it go to a callout titled Settings.
- Slider params with `numbers` give the number (metres for the radius) to `onChangeFn`.
- The game registers the shortcut G only for tools whose action has a street, bulldozer, or similar builder (`construction_react_util.tl:3882-3895`). It answers the request `streetBuilderRequestUnderground` only for its own builder tools. The brush handles G itself and changes the toolbar button through the params API of the menu. It keeps that API from the call of `construction_react_util.getActionParams` (the 8th argument, `refSublistParams`; `installApiCapture` in the tool script).
- The Underground button only switches the underground view and the selection filter. It does not make roads tunnels.
- With a data layer picked in the layers menu, the world layer draws that layer (`preferredLayerConfig`) and no underground view, while the base tools show both. The base tools put `undergroundMode` on the builder of their `ConstructionAction`, and the brush has none. The mod does not add a `ConstructionAction` builder.
- The game gives Esc to its own menu when the keyboard focus sits on the toolbar, which is usually the case after a click on Upgrade. The menu then closes the construction mode, and the tool cannot take the key. The Cancel button works in every case.
- Mods cannot add input actions. M and N are the rotation keys of the game (`constructOpt1` and `constructOpt2`).
- Ctrl + click is not usable for the middle-click copy: the game takes it as a multi-select of entities, opens the entity details, and closes the tool before the tool sees the click.
- The menu can create a second instance of the tool recipe, and the world layer that stays mounted can belong to the older instance. One game log showed the game sending the mouse events to the newer instance, whose ring has no cursor position. This cause of the stuck ring is not confirmed. `brush_layer.tl` keeps the owner of the layer. The newest instance passes its params to the owner, and only the owner steps and handles the clicks. A mouse event never makes another instance the owner while the owner is alive. An owner whose unmount callback was lost stays alive while its step runs, so the other instances drop their mouse events until the layer mounts again.
- The game sets the tooltip of a toolbar param once, when the component is created. It updates it only when the name, labels, numbers, or type of the param change (`construction.tl` `ConstructionParam`, `refTooltip`). Components are matched by position. A slider with the same name, labels, and values as the slider of another tool shows the tooltip of that tool. This is why the brush slider is labelled "Brush radius", not "Radius" (the label of Bulk Bulldozer).
- The stuck ring (the circle stayed fixed on the map after switching the Underground button or the map layers) also occurs in Bulk Bulldozer, which has the same layer flag, mount and unmount callbacks, and underground `LayerConfig` child.
