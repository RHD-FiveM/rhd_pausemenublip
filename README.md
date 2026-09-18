# rhd_pausemenublip

A searchable list of every blip on the GTA V pause menu map, rendered in NUI.

Open the pause menu, go to the Map tab, and a panel appears listing everything
the map legend knows about: name, icon, colour. Type to filter, move with the
arrow keys, press Enter to set a waypoint. The selection stays in sync with the
game's own legend, so what you highlight in the panel is what the map
highlights too.

## Why this exists

I was told it is impossible to get the game's built-in blip list into NUI —
there is no native for it, and the legend only exists inside the pause menu
scaleform. This resource is the counter-argument.

The trick is a modified `pause_menu_pages_map.gfx` (in `stream/`) that answers
a few extra requests through the scaleform methods the game already exposes.
The Lua side asks, the scaleform replies, NUI displays. No client-side hooks,
no memory reading.

Because the point was to prove it works rather than to ship a product, the NUI
source (React + Mantine) is not included. What you get is the built bundle,
the Lua that talks to the scaleform, and the patched scaleform itself. Those
three pieces are enough to run it, study it, or wire your own UI on top.

## Controls

| Key             | Action                                                |
| --------------- | ----------------------------------------------------- |
| Type            | Filter the list                                       |
| ↑ / ↓           | Move selection (map highlight follows)                |
| ← / →           | Cycle through blips that share one legend entry       |
| Enter           | Set waypoint on the selected blip                     |
| Esc / Backspace | Work as usual                                         |

Game input keeps flowing while the panel is open. Focus is only taken fully
when the cursor is over the panel or you are typing.

## Installation

Requires [ox_lib](https://github.com/overextended/ox_lib).

```
git clone https://github.com/RHD-FiveM/rhd_pausemenublip.git
```

Then in `server.cfg`:

```
ensure ox_lib
ensure rhd_pausemenublip
```

No configuration. Every blip that appears in the map legend shows up
automatically.

## Caveats

- This resource **replaces** `pause_menu_pages_map.gfx`. Anything else that
  streams a file with the same name will conflict; only one can win.
- GTA V only.
- The list reflects whatever the game puts in the legend. Blips hidden from the
  legend by their display mode will not appear here either.

## Layout

```
client.lua               polling, cache, focus routing, NUI callbacks
modules/mapdata.lua      transport layer to the scaleform
stream/                  patched pause_menu_pages_map.gfx
html/                    NUI bundle, blip icons (.webp), font
```

## License

GPL-3.0. See [LICENSE](LICENSE).
