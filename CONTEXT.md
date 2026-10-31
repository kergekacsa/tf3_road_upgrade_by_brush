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
One of the six street templates of the game that make up the track types. A track with any other template is never selected or changed. The quiet copy of a base track template, made by the mod Station Noise Barriers, counts as that template when it is read. It belongs to a station, so the brush does not select it.
_Avoid_: Supported template, known track
