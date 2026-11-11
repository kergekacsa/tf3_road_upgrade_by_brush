# Road & Rail Upgrade Brush

A Transport Fever 3 mod with one tool. The player paints over roads or rails to select them, then upgrades all of them in one press: to one chosen type, or with their type kept and only their add-ons changed.

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

**Add-on state**:
The three-way choice of what an upgrade does with one add-on of a road: bus lane, tram track, catenary, alley trees or noise barrier. Keep leaves each road as it is, Add puts the add-on on, Remove takes it off. Keep is the default. The lock has its own three ways (Keep, Lock, Unlock).
_Avoid_: Toggle, check box

**Keep road type**:
The Roads choice of road type that leaves the road type of each road as it is, so the upgrade changes only add-ons. It is the first entry of the road type list and the default.
_Avoid_: No change, skip

**Listed road**:
A road whose template belongs to one of the six road types: the plain template, its variant with alley trees or noise barrier, or the base game variant with a bus lane or a tram track.
_Avoid_: Supported road, known road

**Unlisted road**:
A road that is no listed road, such as a one-way road, a highway or a road of another mod. With Keep road type, an upgrade changes only its bus lane, tram track, catenary and lock, never its alley trees or noise barrier.
_Avoid_: Unknown road, modded road

**Catenary state**:
The add-on state of the wiring. In Rails mode it puts catenary on a track or takes it off. In Roads mode it acts on every lane that carries a tram track after the upgrade.
_Avoid_: Electrification

**Noise barrier state**:
The add-on state of the noise barrier. In Rails mode it sets the barrier of the game on both sides of a track. In Roads mode a road has alley trees or a noise barrier, never both, so Add of one replaces the other.
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
An option of a road upgrade besides the road type: bus lane, tram track, catenary, alley trees, noise barrier or lock. Each has an add-on state, and the lock has its three ways.
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
_Avoid_: Skipped road

**Skipped road**:
A selected road that the press leaves alone for a reason: a hard rule, or lanes that the new road type cannot keep. It leaves the selection, and the result names the reason.
_Avoid_: Failed road, dropped road

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
The middle click that reads the settings of the road or track under the pointer into the toolbar: a concrete type, and Add or Remove for each add-on. It selects nothing.
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
