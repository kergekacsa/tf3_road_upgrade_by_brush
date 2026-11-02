# Road & Rail Upgrade Brush

A Transport Fever 3 mod with one tool. The player paints over roads or rails to select them, then upgrades all of them to one chosen type in one press.

## Language

**Brush**:
The tool and its circle on the map. Edges the circle touches join the selection.
_Avoid_: Painter, lasso

**Selection**:
The set of edges the brush has marked and that wait for Upgrade.
_Avoid_: Queue, batch

**Mode**:
The kind of edge the brush selects and upgrades: Roads or Rails. A switch at the top of the toolbar sets it. The toolbar shows only the options of the active mode.
_Avoid_: Layer, filter (a filter hides kinds the tool never offers; a mode chooses between two offered kinds)

**Catenary state**:
The Rails choice of what an upgrade does with the wiring: Keep leaves each track as it is, Add puts catenary on, Remove takes it off.
_Avoid_: Electrification

**Noise barrier state**:
The Rails choice of what an upgrade does with the noise barrier of the game on a track: Keep leaves each track as it is, Add puts the barrier on both sides, Remove takes it off.
_Avoid_: Wall, quiet track (the quiet track is a template of another mod)

**Track type**:
One of the three types the Rails mode offers: simple, standard or high speed. Each exists with and without catenary.
_Avoid_: Rail type, rail template

**Base track template**:
One of the six street templates of the game that make up the track types. A track with any other template is never selected or changed. The quiet copy of a base track template, made by the mod Station Noise Barriers, counts as that template when it is read. The brush skips it when it belongs to a construction. Otherwise an upgrade swaps it to the base template of the target.
_Avoid_: Supported template, known track

**Road type**:
One of the six two-way street types the Roads mode offers: town or country, each small, medium or large. The two one-way types of Road Upgrade All in One are not offered.
_Avoid_: Street type, road class

**Add-on**:
An option of a road upgrade besides the road type: bus lane, tram track, catenary, alley trees, noise barrier or lock.
_Avoid_: Extra, modifier

**Lock**:
The flag of a road that stops towns from changing it. An upgrade has three choices: Keep leaves the lock of each road, Lock sets it, Unlock removes it.
_Avoid_: Protection

**Press**:
One use of the Upgrade button. The brush upgrades the whole selection, up to the cap, in one run.
_Avoid_: Run, commit, batch

**Unchanged road**:
A selected road that already is what the upgrade would make of it. It shows blue, costs nothing and is left alone by the press.
_Avoid_: Skipped road, same road

**Failed road**:
A road whose upgrade command the game refused in every attempt. It stays selected, so another press tries it again.
_Avoid_: Skipped road (the hard rules drop a skipped road from the selection)

**Hard rules**:
The conditions that decide whether the brush may select or change an edge: it skips roads of other players, parts of constructions, industry roads and stand-alone tram tracks, and in Rails mode tracks with another template.
_Avoid_: Filter (see Mode)

**Cap**:
The most edges one selection and one press can hold: 200.
_Avoid_: Limit, max

**Preview**:
The colours on the map before the press. Edges under the circle that are not selected show light pink, selected edges red, and an unchanged road blue.
_Avoid_: Hover, highlight

**Copy**:
The middle click that reads the settings of the road or track under the pointer into the toolbar. It selects nothing.
_Avoid_: Pick, clone, eyedropper

**Underground button**:
The button of the game that switches the underground view on, with the shortcut G. With it on, the brush selects tunnels only, and alley trees and noise barriers are off.
_Avoid_: Tunnel mode

**Asset group**:
A placed decoration of the game, such as a tree group or a rock. One in the way makes a road fail with "Collision". With "Remove buildings in the way" on, a retry removes it.
_Avoid_: Building (houses and lots are not asset groups)

**Stand-alone tram track**:
A street none of whose lanes carries cars, buses or trucks. The Roads mode never selects it. A road with tram tracks next to car lanes is a normal road.
_Avoid_: Tram road
