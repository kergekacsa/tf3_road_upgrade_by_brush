# Road Upgrade Brush

A private Transport Fever 3 mod (`kacsa_road_upgrade_brush`). It puts one tool in the road tools menu: **Road Upgrade Brush**. It selects roads with a brush and upgrades them to a street type in one press. The mod is independent: it needs no other mod and is built to run next to the original mods "Road Upgrade All in One" and "Bulk Bulldozer". It has no single-click tool, so the original one does not appear twice in the menu.

## Before you start

- No other mod is needed. The original "Road Upgrade All in One" (`road_upgrade_suite`) and "Bulk Bulldozer" MAY stay on. This mod uses its own file paths, text keys (`rub_*`), menu parameter keys, and Teal type names (`Rub*`), so it replaces no file of the originals.
- Tested in the game on 2026-10-31 (user report): the checklist passed for this build. The brush appears once, it works, and it works next to the original mods.
- Three things are shared by design. (1) The toolbar status style: when Bulk Bulldozer or Smart Lanes is active, this mod uses their style rules and adds none of its own; the status text then looks as their style makes it. (2) The developer master switch mod `square_sqperf_all`, if installed, turns on the debug log of this mod. (3) The menu category `roads_tools` with order 5, the same order as the tool of Bulk Bulldozer; with both on, the menu lists both tools.
- Pause is handled by the mod: it pauses the game while it upgrades and sets the old speed back when it is done.

## How the brush tool works

1. Everything sits in the one toolbar on the left, from top to bottom: the radius, the Underground button, the road options, the progress, and the **Upgrade** and **Clear** buttons. Pick the road type, and optionally alley trees and noise barriers. Besides the slider, the keys **M** (larger) and **N** (smaller) change the radius step by step, and a held key repeats. They are the rotation keys of the game's construction tools, so rebinding them in the game settings rebinds them here.
2. Hold the left mouse button and paint over the roads. Every road that the brush circle touches is selected. Roads under the circle that are not selected yet show as a light pink preview, also while a selection waits. Selected roads are red.
3. Hold Shift while painting to remove roads from the selection. Every selected road the brush touches leaves the selection.
4. Press **Upgrade**. The mod sends one command per road. A road leaves the selection as soon as it is done, or when it already had the target type, so the highlight shrinks while the status line shows the progress (for example "Upgrading 12 of 50" with a bar). Roads that fail count for the progress too, and the retry rounds show as "Retrying failed ones". While it runs, the **Clear** button reads **Cancel**, and a third line says that it stops the progress. At the end the status line shows "X updated, Y failed" with the cost: green when something was updated (with "Y failed" in yellow when some roads failed), red when nothing was updated and some roads failed. It stays until your next stroke, upgrade or clear.
5. **Clear** or a right click empties the selection. While an upgrade runs, the button reads **Cancel**: it stops the upgrade after the road in progress, keeps the roads that are not done selected, and the tool stays open. Esc does the same when the keyboard focus is on the map. After a click on the **Upgrade** button the game usually gives Esc to its own menu, which closes the tool; the upgrade then stops after the road in progress. Roads already upgraded stay upgraded.

## Limits

- Up to 200 roads per press. When 200 roads are selected, the status line reads "200 selected (max)" in yellow. A run takes about half a second per road, and the game stays paused while it runs.
- The brush offers the six two-way road types. The two one-way road types of Road Upgrade All in One are not offered.
- Alley trees do not exist for country roads. The toolbar shows a red note for impossible combinations.
- The brush skips roads of other players, parts of constructions, and industry roads. It upgrades town roads and roads without an owner.
- A road that already has the target type (and the same trees or barriers) is left alone and not charged.
- A road whose command fails is tried again twice, each time after all other roads. Roads that still fail stay selected, so another press tries them again.
- "Remove buildings in the way" is on by default. A town road with building lots can fail with "Unexpected parcel on a segment". The brush cannot upgrade such a road and does not demolish any house for it. It stays selected and counts as failed. Upgrade it with the single-click tool of Road Upgrade All in One, which moves or removes the houses itself.
- A road that a placed asset (an asset group such as a decoration, a tree group, or a rock) blocks fails with "Collision". With "Remove buildings in the way" on, the first retry removes the asset, and the last retry sends the build with the game's errors ignored, as the Build Anyway mod does. The removal on the first retry is confirmed in the game; the forced build on the last retry is not.
- The cost is known only after the upgrade. There is no cost preview.
- There is no undo.
- The tool remembers the radius, road type, trees, barrier, bus lane, tram track, lock, and "Remove buildings in the way" during one game session. A new session starts with the defaults.
- Bus lane, tram track, catenary, and lock are offered as in Road Upgrade All in One (bus lane: no cars on the outer driving lanes; tram track and catenary: tram lanes on the outer driving lanes; lock: towns do not change the road). All four are confirmed in the game.
- The brush gives a road the lanes of the street type you choose. With Tram track or Bus lane off, an upgrade removes a tram track or a bus lane that the road has. The lock is never removed by the brush.
- The Underground button in the toolbar (or the shortcut G) switches the underground view on. While it is on, the brush selects tunnels only. While it is off, it selects roads on the ground only.
- The brush never selects a stand-alone tram track. A road with tram tracks on top of its lanes is selected.
- While the Underground button is on, alley trees and noise barriers are disabled and ignored: a tunnel has neither.

## Credits and use

- The road types, add-ons, and rules are taken from "Road Upgrade All in One" by kurowasiichi (mod.io 6487083). The headers of the copied files name the author. The tool icon and the mod.io image are drawn for this mod.
- The brush, selection, highlight, and toolbar code is taken from "Bulk Bulldozer" by square17 (mod.io 6434884). The headers of the copied files name the authors.
- This mod is for private use. Do not publish it without permission from both authors.

## Log

The mod writes to the game log (`crash_dump\stdout.txt`). Lines start with `[BrushUpgrade]`. The log shows each command, the game's messages, and the game speed. The diagnostic lines (tool instances, world layer, cursor, segment to send) are off. The `[RUS probe]` hover probe is kept in the code but nothing calls it now. To turn them on, set `probe.ENABLED = true` in `content/road_upgrade_brush/proposal_probe.tl`.

## Release files

- `mod.json`: modId `kacsa_road_upgrade_brush`, revision 1 (the first upload), no dependencies.
- `_metadata/modinfo.json`: name, summary, and description for mod.io.
- `image_00.jpg`: the mod.io image (1400 x 800).
- `content/gui/road_upgrade_brush/brush_tool@2x.tga` and `brush_tool_preview@2x.tga`: the tool icon and its preview in the menu.
