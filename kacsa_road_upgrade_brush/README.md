# Road Upgrade Brush

A private Transport Fever 3 mod (`kacsa_road_upgrade_brush`). It puts two street upgrade tools in the road tools menu:

- **Combined Road Upgrade** is the single-click upgrader of "Road Upgrade All in One", unchanged.
- **Road Upgrade Brush** selects roads with a brush and upgrades them to a street type in one press.

## Before you start

- Switch off the original "Road Upgrade All in One" (`road_upgrade_suite`). This mod contains a copy of it with the same resource paths and string keys, so both cannot run together.
- Bulk Bulldozer MAY stay on. This mod uses its own names for everything.
- Pause is handled by the mod: it pauses the game while it upgrades and sets the old speed back when it is done.

## How the brush tool works

1. Everything sits in the one toolbar on the left, from top to bottom: the radius, the Underground button, the road options, the progress, and the **Upgrade** and **Clear** buttons. Pick the road type, and optionally alley trees and noise barriers.
2. Hold the left mouse button and paint over the roads. Every road that the brush circle touches is selected.
3. Hold Shift while painting to remove roads from the selection. Every selected road the brush touches leaves the selection.
4. Press **Upgrade**. The mod sends one command per road. A road leaves the selection as soon as it is done, or when it already had the target type, so the highlight shrinks while the status line shows the progress (for example "Upgrading 12 of 50" with a bar). Roads that fail count for the progress too, and the retry rounds show as "Retrying failed ones". While it runs, the **Clear** button reads **Cancel**, and a third line says that it stops the progress. At the end the status line shows "X updated, Y failed" with the cost: green when something was updated (with "Y failed" in yellow when some roads failed), red when nothing was updated and some roads failed. It stays until your next stroke, upgrade or clear.
5. **Clear** or a right click empties the selection. While an upgrade runs, the button reads **Cancel**: it stops the upgrade after the road in progress, keeps the roads that are not done selected, and the tool stays open. Esc does the same when the keyboard focus is on the map. After a click on the **Upgrade** button the game usually gives Esc to its own menu, which closes the tool; the upgrade then stops after the road in progress. Roads already upgraded stay upgraded.

## Limits

- Up to 50 roads per press.
- The brush offers the six two-way road types. The two one-way road types exist only in the single-click tool.
- Alley trees do not exist for country roads. The toolbar shows a red note for impossible combinations.
- The brush skips roads of other players, parts of constructions, and industry roads. It upgrades town roads and roads without an owner.
- A road that already has the target type (and the same trees or barriers) is left alone and not charged.
- A road whose command fails is tried again twice, each time after all other roads. Roads that still fail stay selected, so another press tries them again.
- "Remove buildings in the way" is on by default. Some roads in towns still fail with "Unexpected parcel on a segment"; the single-click tool fails on some of them too.
- The cost is known only after the upgrade. There is no cost preview.
- There is no undo.
- The tool remembers the radius, road type, trees, barrier, bus lane, tram track, lock, and "Remove buildings in the way" during one game session. A new session starts with the defaults.
- Bus lane, tram track, catenary, and lock are offered as in the single-click tool (bus lane: no cars on the outer driving lanes; tram track and catenary: tram lanes on the outer driving lanes; lock: towns do not change the road). Bus lane and lock are confirmed in the game. Tram track and catenary are new and not yet confirmed.
- The brush gives a road the lanes of the street type you choose. With Tram track or Bus lane off, an upgrade removes a tram track or a bus lane that the road has. The lock is never removed by the brush.
- The Underground button in the toolbar (or the shortcut G) switches the underground view on. While it is on, the brush selects tunnels only. While it is off, it selects roads on the ground only.
- The brush never selects a stand-alone tram track. A road with tram tracks on top of its lanes is selected.
- While the Underground button is on, alley trees and noise barriers are disabled and ignored: a tunnel has neither.

## Credits and use

- The single-click tool is "Road Upgrade All in One" by kurowasiichi (mod.io 6487083).
- The brush, selection, highlight, and toolbar code is taken from "Bulk Bulldozer" by square17 (mod.io 6434884). The headers of the copied files name the authors.
- This mod is for private use. Do not publish it without permission from both authors.

## Log

The mod writes to the game log (`crash_dump\stdout.txt`). Lines start with `[BrushUpgrade]`. The log shows each command, the game's messages, and the game speed. The `[RUS probe]` lines come from a diagnostic hook that is still in the mod.
