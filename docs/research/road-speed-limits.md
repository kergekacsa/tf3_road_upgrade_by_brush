# Road speed limits per road type

## Answer

**Partly yes.** A mod can change the speed of a vanilla street template without adding a template. The change is global: it applies to every road that uses the template, not to the roads the brush upgrades. A per-road-type speed that applies only inside the brush upgrade is possible in theory (a lane speed written into the `replaceSegment` proposal), but nothing in the files proves that the game honours it.

**Recommendation.**

1. MUST NOT build this into the brush before one in-game test of the per-edge write (test 1 below). The test costs one upgrade press and settles the main unknown.
2. If the test passes, SHOULD add the speed as a per-upgrade option in `bb_upgrade.tl`, next to the lane edit that `applyExtras` already does. This keeps the mod independent and changes no road that the player does not paint.
3. If the test fails, the only working route is a global template change in a `runFn` or `postRunFn` hook. SHOULD ship that as a separate mod, because it changes roads outside the brush and conflicts with other mods that patch the same templates.

## How to read this document

- Source tags: **[first-party]** is a game file or type definition in the install folder or in the unpacked `gui.zip`. **[mod]** is code of another published mod (secondary, it proves that something was tried, not that it works in every case). **[TF2]** is the Transport Fever 2 wiki (not proof for TF3). **[inference]** is my reading, not a file fact.
- Install folder: `C:\Program Files (x86)\Steam\steamapps\common\Transport Fever 3\`, shortened to `<TF3>`.
- Street template files are inside `<TF3>\base\content\infrastructure\street.zip`, written `street.zip!<entry>`. Entry line numbers refer to the text of the entry.
- The official TF3 wiki (`wiki.transportfever3.com`, page `modding:streettemplate`) returned "you don't have enough rights" on 2026-11-03. No official TF3 prose documentation was available. All TF3 claims come from definitions and scripts.

## 1. What sets the speed of a road

The speed is data in the street template, one number per lane.

| Item | Fact | Source |
|---|---|---|
| Per-lane speed | `LaneConfig.speed : number`, comment "Speed limit for the lane". | [first-party] `<TF3>\api\tealdef\api\type.d.tl:5377-5379` |
| Template lanes | `StreetTemplate.laneConfigs : {LaneConfig}`, "from left to right in the build direction". | [first-party] `type.d.tl:5494-5495` |
| Per-edge copy | `Engine.Component.BaseEdge.laneConfigs : {LaneConfig}` holds the lanes of each built edge. | [first-party] `<TF3>\api\tealdef\api\engine.d.tl:99-106` |
| Template modifier | `StreetTemplate.modifiers : Modifiers`, "Modifiers applied to vehicles on the road". `Modifiers.maxSpeedModifier` is an additive factor: top speed = base x (1 + X). | [first-party] `type.d.tl:5498-5499`, `type.d.tl:5393-5406` |
| Curve speed | `StreetTemplate.speedCoeffs : {number}`, "Max speed based on three different curvatures". The six road templates do not set it. | [first-party] `type.d.tl:5530-5531`; checked in the 12 template files |
| Vanilla value of the modifier | The 12 templates of the road types set `maxSpeedModifier = 0`. | [first-party] `street.zip!street/town/town_new_small.street_template.lua:70-75` and the 11 other files |
| Network edge | The transport network `Edge` record has `speedLimit` and `curveSpeedLimit`. The definition shows no setter. | [first-party] `type.d.tl:1113-1123` |
| Vehicle view | `VehicleEdgeInfo.speedLimit` and `getAverageSpeedLimits` read the limit for a vehicle. These are read-only queries. | [first-party] `<TF3>\api\tealdef\api\type\transformator.d.tl:437-446, 499-503` |
| Bridges, tunnels, crossings | `BridgeType.speedLimit` and `RailroadCrossingType.speedLimit` "limit top speed of road and tracks". These apply to the bridge or crossing type, not to the street. | [first-party] `type.d.tl:5043-5046`, `type.d.tl:5448-5451` |
| Edge decorations | `EdgeDecoration.modifiers : Modifiers`, "applied to vehicles travelling onto edges with such edge decoration". | [first-party] `type.d.tl:5325-5326` |

Unit: the speed is in **metres per second**.

- `api.util.formatSpeed` takes "speed in meter per second" (`<TF3>\api\tealdef\api\util.d.tl:36-38`) [first-party].
- The vanilla loader converts the legacy km/h field with `v.speed = data.speed / 3.6` (`C:\Users\Kacsa\tools\tf3-gamesrc\zip_base\base\base_mod.lua:109-113`) [first-party].
- So km/h = m/s x 3.6. Check: 13.89 x 3.6 = 50.0.

The legacy template field `speed` (km/h) no longer exists in the TF3 record. The base mod only converts old mod files that still use it (`base_mod.lua:94-118`) [first-party].

### Road templates the brush uses

The brush resolves each road type to the newest available template for the game year (`ARCHITECTURE.md`, "Origin of the copied code"; `rub_config.tl:7-12`). A road type therefore has two templates, "new" (from 1940) and "old" (until 1940). All lanes of a template, including the footpath lanes, carry the same speed.

| Road type | Template (new / old) | Lane setup | Speed new (m/s, km/h) | Speed old (m/s, km/h) |
|---|---|---|---|---|
| Town small | `town_new_small` / `town_old_small` | 2 car lanes + 2 footpaths | 13.89, 50 | 11.11, 40 |
| Town medium | `town_new_medium` / `town_old_medium` | 4 car lanes + 2 footpaths | 13.89, 50 | 11.11, 40 |
| Town large | `town_new_large` / `town_old_large` | 6 car lanes + 2 footpaths | 16.67, 60 | 16.67, 60 |
| Country small | `country_new_small` / `country_old_small` | 2 car lanes + 2 footpaths | 22.22, 80 | 16.67, 60 |
| Country medium | `country_new_medium` / `country_old_medium` | 4 car lanes + 2 footpaths | 22.22, 80 | 16.67, 60 |
| Country large | `country_new_large` / `country_old_large` | 6 car lanes + 2 footpaths | 22.22, 80 | 16.67, 60 |

- Source of every number: the `laneConfigs` entries of `street.zip!street/town/town_*_{small,medium,large}.street_template.lua` and `street.zip!street/country/country_*_{small,medium,large}.street_template.lua`. Example lines: `town_new_small` lines 25, 30, 38, 46 (lane speeds) and 70-75 (modifiers) [first-party].
- Era: `yearFrom = 1940` for "new", `yearTo = 1940` for "old" (same files) [first-party].
- km/h are rounded: 16.67 x 3.6 = 60.01, 22.22 x 3.6 = 79.99.
- The variants `_trees`, `_barriers`, `_bus`, `_tram`, `_tram_electrified` are separate template files. All 43 variants of the 12 templates carry the same lane speed as their base (checked by script over `street.zip`). A global template change MUST patch all of them, because the brush also writes these templates.
- A 30 km/h road exists in vanilla: `town_new_xsmall` has 8.33 m/s (30 km/h) and `town_old_xsmall` has 5.56 m/s (20 km/h) (`street.zip!street/town/town_new_xsmall.street_template.lua`). It is not one of the six road types of the brush. The brush does not offer it.

## 2. Can a mod change the speed of an existing template?

Yes, by five routes. Two more routes do not exist. Only route A and B are global.

| Route | Possible? | Scope | Evidence |
|---|---|---|---|
| A. `runFn` with `addModifier("loadStreetTemplate", fn)`, `fn` rewrites `data.laneConfigs[i].speed` | Yes | Global, at load | The base game registers the same modifier in its own `runFn` (`base_mod.lua:94-118`) [first-party]. `addModifier` is declared in `<TF3>\api\tealdef\main.d.tl:59` [first-party]. Mods Public Roads and twh_cost use it to change costs (`C:\Users\Public\mod.io\10640\mods\6460963\content\mod.script.lua:92-97`, `...\6447443\content\twh_cost.script.lua:32`) [mod]. |
| B. `postRunFn` with `api.res.streetTemplateRep.getAsTable(id)` and `setAsTable(id, t)` | Yes | Global, after load | The repository interface offers `get`, `getAsTable`, `setAsTable` (`<TF3>\api\tealdef\api\res.d.tl:14-18, 57-66`) [first-party]. The base game edits templates in place in its own post-run (`zip_base\base\post_run_util.tl:37-49`, cost scale) [first-party]. Public Roads does `getAsTable`/`setAsTable` on street templates (`6460963\content\mod.script.lua:109-130`) [mod]. |
| C. Change `modifiers.maxSpeedModifier` of the template (route A or B) | Probably | Global, relative (percent) | The field exists and is documented (`type.d.tl:5498-5499, 5406`) [first-party]. The vanilla value is 0. No file shows that the engine applies the template value to the simulated speed. The GUI only displays it (`construction_react_util.tl:2113-2117`) [first-party]. Unverified. |
| D. Edge decoration with a speed modifier | Yes, vanilla | Per edge, fixed -25% | `alley.edge.lua` and `alley_old.edge.lua` set `maxSpeedModifier = -0.25` (`edge_addons.zip!edge_addons/alley.edge.lua:52-57`) [first-party]. The brush already sets alley trees as an add-on. The mod Budok Tree Speed zeroes this value with `setAsTable` in `postRunFn` (`C:\Users\Public\mod.io\10640\mods\6427614\content\mod.script.lua:12-26`) [mod], which shows that the effect is real enough for players to remove it. |
| E. Write `lane.speed` of the added segment inside the `replaceSegment` proposal | Unproven | Per edge | The proposal exposes `addedSegments[i].comp : BaseEdge` with `laneConfigs` (`ARCHITECTURE.md`, "Game API"; `engine.d.tl:99-106`) [first-party]. The brush already writes `comp.laneConfigs[i].transportModes` and verifies the read-back (`kacsa_road_upgrade_brush\content\road_upgrade_brush\bb_upgrade.tl:233-258, 262-279`). The mod Devers writes `lanes[li].speed = tpl.laneConfigs[li].speed` into an edge of a hand-built proposal (`C:\Users\Public\mod.io\10640\mods\6418700\content\devers\devers_sync.script.lua:559-566`) [mod]. No file proves that the simulation reads this value. |
| F. `game.config` / `BaseConfig` | No | n/a | `BaseConfig` and `AdvancedOptions` hold town, industry and cost values. They hold no street speed (`type.d.tl:3481-3502`). `trafficSpeedSensitivityScale` only scales the effect of traffic speed on town growth [first-party]. |
| G. Dedicated command or `StreetEdgeNodeModifier` field for speed | No | n/a | `StreetEdgeNodeModifier` has no speed field (`<TF3>\base\tealdef\scripts\builtin.d.tl:157-187`). `cmd.d.tl` lists no command that edits a street edge. The edge commands go through `makeWorldBuildProposalCmd` (`cmd.d.tl:961-962`) [first-party]. |

Also not possible without a custom resource: a new edge decoration with another speed modifier. A mod could add one (`ResTypeRep.add`, `res.d.tl:40-45`), but that is a custom resource, which the request excludes.

Unknown: whether a mod can replace a vanilla template by shipping a file with the same path. No TF3 file states this, and I did not test it. Route A and B make the replacement unnecessary.

## 3. Setting a speed on one edge at runtime

- **Command or proposal.** The only way to change a built edge is a world build proposal (`makeWorldBuildProposalCmd`, `cmd.d.tl:961-962`) [first-party]. No command sets a speed limit alone. `Edge.speedLimit` in the transport network (`type.d.tl:1121`) has no setter in the definitions.
- **What a proposal can carry.** `BaseEdge.laneConfigs` is a per-edge list (`engine.d.tl:106`), and `LaneConfig.speed` is a plain number (`type.d.tl:5379`). So a proposal can hold a lane speed per edge. That is route E above.
- **What blocks certainty.**
  - The brush notes that the getters of the proposal may hand out copies, so every edit MUST be written back at every level (`ARCHITECTURE.md`, "Game API").
  - The brush notes a trap for `transportModes`: the game takes a complete list of 16 booleans, and a wrong write stops the game in its transport network (`ARCHITECTURE.md`, "Lanes and transport modes"). A `speed` write is a single number, so it has no such trap in the type definition. This is [inference]. A game test MUST confirm it.
  - `replaceSegment` rebuilds lanes from the template (`ARCHITECTURE.md`, "Game API": "its lanes are rebuilt from the template"). It is unknown whether the engine recomputes the speed from the template after the proposal is processed.
- **Read-back is possible.** The brush can read `BASE_EDGE.laneConfigs[i].speed` after the command and compare (same method as the mode check in `bb_upgrade.tl:262-279`). `getAverageSpeedLimits` and `VehicleEdgeInfo.speedLimit` need a vehicle on the edge, so they are no practical check.

## 4. Saves, other players, removal of the mod

All statements in this section are [inference] unless a source is given. No file in the install folder describes save contents, mod removal, or multiplayer.

| Question | Route A / B (template change) | Route E (per-edge lane speed) |
|---|---|---|
| Stored in the save? | No. Templates come from files and hooks, and the hooks run at each game start (the base game itself sets costs in `postRunFn`, `base\mod.json`, `mod.script.tl:257`) [first-party for the hook]. | Likely yes. `laneConfigs` is a field of the `BASE_EDGE` component (`engine.d.tl:106`), so it belongs to the edge entity. Unverified. |
| Edges that already exist | Unknown. If the edge keeps its own lane speeds, existing roads keep the old speed until they are replaced. If the simulation reads the template, they change at once. | Only the upgraded edges change. |
| Mod removed | Templates return to vanilla at the next start. Roads built or upgraded while the mod was on may keep the changed lane speed if edges store it (unknown). | Edges keep the written speed, if the engine stores it. Nothing resets it except a new upgrade. |
| Other players | No multiplayer API appears in the type definitions (search for `multiplayer`, `isHost`, `netplay` in `api\tealdef` found nothing). Unknown. | Unknown. A proposal travels as a command, so it would reach other clients if the game has multiplayer. [inference] |
| Other mods | Two mods that patch the same template conflict. The load order decides. | No conflict, except with mods that rewrite the same edge. |

A hint that edge lane speed is stored on the edge: the mod Devers adds a tiny offset (`SPEED_MARK`) to lane speeds of its template variants and reads it from placed edges to tell the variants apart (`6418700\content\mod.script.lua:411-418`) [mod]. This supports that `BASE_EDGE.laneConfigs[i].speed` survives on the edge. It is not proof.

## 5. Does vanilla TF3 have a per-edge speed limit in the UI?

No. Searches of the unpacked GUI (`C:\Users\Kacsa\tools\tf3-gamesrc\`) for `speedLimit`, `speed limit`, `maxSpeedModifier`, `speedCoeffs`, `overrideLaneConfigs`, and `laneConfig.*speed` found only these uses:

- A **display layer** "Speed Limit" with a colour legend in the infrastructure layers menu (`zip_gui\gui\layers\layer_infrastructure.tl:23-36, 103-109, 230`; icon `menu_layers_speed_limits` in `zip_gui\gui\context_helper\context_helper_react.tl:337`). It colours edges by speed. It sets nothing.
- **Bridge, tunnel and crossing menus** show `speedLimit` of the type (`zip_gui\gui\main\menu_category_util.tl:136-143, 468`), and the GUI picks the bridge whose limit is closest to the fastest lane of the road (`zip_gui\gui\construction\construction_react_util.tl:328-346`).
- **Description text** "Top Speed" for a template or a modifier (`zip_gui\gui\construction\construction_desc_react_util.tl:72-73, 670-679`).
- The street builder has the toolbar params `mode_street`, `overrideLaneConfigs` ("Override existing lane configs when upgrading"), `terrainMode`, `bend`, and so on (`construction_react_util.tl:1723-1788`). The lane tools in `gui\construction\tools\` are `bus_lane_tool`, `tram_track_tool`, `lane_modifier_tool`, and others. None has a speed parameter.

So the player cannot set a speed on one road in the vanilla UI. The only per-edge speed effect in vanilla is the alley tree decoration (-25%, route D).

## 6. Fit with the `replaceSegment` flow of the brush

- The flow today: `replaceSegment(entity, streetTemplate)` returns a `Proposal`. `bb_upgrade.tl` edits `comp.edgeDecorations`, `comp.laneConfigs[i].transportModes`, and `comp.roadDevelopmentLocked` of each added segment, reads them back, and sends the proposal only if the read-back matches (`bb_upgrade.tl:220-291`, `ARCHITECTURE.md`, "Game API").
- A speed value fits as one more field of the same lane objects: `lane.speed = x` for each lane of each added segment, then write back `comp.laneConfigs`, `segment.comp`, `street.addedSegments`, `p.proposal`, as the mode edit already does.
- The brush MUST write the same value to every lane of the segment, as the vanilla templates do (all lanes of a template share one speed, including footpaths). The mod MAY leave footpath lanes at the template value. Whether the footpath speed matters for the simulation is unknown.
- The "unchanged road" test (`carriesExtras`, `bb_upgrade.tl:331-341`) SHOULD then also compare the lane speed, or a press on a road that has only the wrong speed would count as unchanged.
- The speed MUST come from a new toolbar option per road type (or one option for all). The mod must store it as plain Lua data (`ARCHITECTURE.md`: copy views of engine data before other commands run).
- Cost: the proposal already replaces the whole segment, so a speed change adds no new command and no new cost entry [inference].
- Constraint: a road type has a "new" and an "old" template. A speed per road type applies to whichever template the game year selects.

## Open questions and game tests

Each test needs a small test road. The mod writes the result to the game log, and I read it. The user only runs the actions in the game and says when done.

| # | Open question | Test | What the result decides |
|---|---|---|---|
| 1 | Does the engine accept and keep a `lane.speed` written into the `replaceSegment` proposal? | Add a debug action (behind the existing debug option) that sets `speed` of all lanes of one added segment to 8.33 and reads `BASE_EDGE.laneConfigs[i].speed` after the command. User: select one small road with the brush, press Upgrade once, tell me when done. | Yes: route E is available. No: only the global routes remain. |
| 2 | Do vehicles drive at the written speed? | After test 1, a bus line over the test edge. Compare the vehicle speed on the edge to the neighbour edge (`VehicleEdgeInfo.speedLimit` or the speed display of the vehicle). User: run the line for a game day, tell me when done. | Whether the edge value reaches the simulation, not only the component. |
| 3 | Does the speed layer ("Speed Limit" in the layers menu) show the edge at the new speed? | After test 1, user switches on the layer and looks at the colour of the test edge. | A cheap visible check of the same question as test 2. |
| 4 | Is the speed stored in the save? | Save, reload, read `laneConfigs[i].speed` of the test edge again. | Whether route E survives a reload. |
| 5 | Does a global template change reach existing roads? | Test mod with `addModifier("loadStreetTemplate")` that sets `town_new_small` to 8.33 m/s. Start a save that has old small roads and read the lane speed of an old edge. | Whether route A/B changes old roads or only new ones. |
| 6 | After removing the test mod, what speed do the edges have? | Load the same save without the test mod and read the lane speed of the test edge. | Behaviour on mod removal (section 4). |
| 7 | Does `maxSpeedModifier` of the template change the driving speed? | Set `modifiers.maxSpeedModifier = -0.5` on `town_new_small` through route B. Compare vehicle speed on a new small road. | Whether route C works. |
| 8 | Does the game have multiplayer, and does it sync edge lane data? | Not testable with the files at hand. Needs the user to state whether multiplayer exists in the game build. | Section 4, other players. |
| 9 | Does a mod file at the path of a vanilla template replace it? | Not needed if route A/B works. Test only if a file-level override is wanted. | Optional. |
