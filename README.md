# Dual Screen (DS-style) — a gen1recomp mod

   | Overworld | Battle |
   |:---:|:---:|
   | <img width="325" alt="image" src="https://github.com/user-attachments/assets/dbcdee1c-ce5c-4767-b82c-a801045b60f2" /> | <img width="325" alt="image" src="https://github.com/user-attachments/assets/1a2f7339-0a64-4185-ad3d-4e9688e0a8c1" /> |

Renders the game as two stacked Game Boy screens, DS-style: the **overworld on
the top screen**, every **UI layer on the bottom screen** (text boxes, the START
menu, shops, the PC, battles), with a small black gutter between them. On
multi-display Android it drives the bottom screen onto a **second physical
display**. Purely presentational — nothing about the split reaches gameplay.

This is a **pure mod**: no engine fork. It rides one engine seam,
`render.compose`, added upstream in **bryanthaboi/gen1recomp#543**. The engine
owns no dual-screen policy; this mod supplies the layout.

## Requires

An engine build with the `render.compose` seam + `Renderer:blitCanvas`
(gen1recomp#543). On an engine without the seam the hook never fires and the mod
is inert — nothing breaks, dual screen just isn't available.

## Install

Drop the folder into the game's `mods/` directory (or install through the mod
manager). Toggle it in **Options → DUAL SCREEN (ON / OFF)**; the choice is
persisted per-save through `mod.save`. With dual screen on, **Options → DS SPLIT
(STACKED / SIDE BY SIDE)** chooses whether the two screens are stacked (world on
top) or placed next to each other (world left, UI right). That row is hidden
when a second physical display is attached, where the split has no meaning.

## How it works

`main.lua` wraps `render.compose`. When the option is on it takes over the
window: it reads the finished `worldCanvas` and `uiCanvas` (and their SGB zones)
off the hook `ctx`, computes two 160×144 screen boxes (`layout.lua`, centred and
integer-scaled), and blits each pass into its box through
`ctx.renderer:blitCanvas(...)` so SGB colouring is preserved. While a full-screen
state covers the world (a battle, a title-screen menu) the top screen holds the
last overworld frame, frozen (a mod-owned snapshot). When the option is off it
calls `next()` and the engine composites its normal single-window frame,
byte-for-byte.

The second physical display (Android Presentation) is driven through the
`ctx.secondScreen` bridge the seam exposes (`available` / `push` / `setEnabled`).

```
render.compose (engine seam)
   └── this mod: layout.lua (geometry) + blitCanvas (draw) + secondScreen (push)
```

## Status (1.0.0)

First stable release. Verified live on desktop (Linux) and on second-display
Android hardware (AYN Thor). The single-display and second-display code paths
are unit-checked in `tests/second_screen_color_test.lua`
(run: `luajit tests/second_screen_color_test.lua`).

- **In-window stack (single display):** the world and UI render as two stacked
  160×144 screens with a gutter. The window-view-sized world pass is
  centre-cropped into its screen box so the player stays centred at any window
  size.
- **In-window split orientation (single display):** with **DS SPLIT = SIDE BY
  SIDE** the two 160×144 screens are laid out left/right (world left, UI right)
  instead of stacked, both integer-scaled to fit the window. Offered only on a
  single display; ignored when a second physical display drives the UI.
- **Second physical display (e.g. AYN Thor):** the main panel is filled with the
  world — centred, at the fit scale, preserving the wide aspect like normal
  single-screen mode — and the UI screen is driven onto the second display.
- **Colour-correct second screen:** the UI is drawn through the engine's palette
  shader (`Renderer:blitCanvas`) into an offscreen canvas before it is pushed, so
  the second display carries the SGB/GBC colour scheme.
- **High-DPI safe:** the mod's offscreen canvases are allocated with
  `dpiscale = 1` and pushed at their native pixel size, so the second screen is
  not sheared on high-DPI Android.
- **Not yet ported:** the DS-native battle *split* (battlefield on top, command/
  move/text window on bottom) is a follow-up layout on top of this base stacking.

## Layout

| module | role |
|---|---|
| `manifest.json` | mod metadata (`id: gen1recomp_ds`, api 2) |
| `layout.lua` | pure two-screen geometry, stacked or side-by-side (`regions`, `surfaceSize`, `screenAt`) |
| `main.lua` | options row + `render.compose` hook (stacking, freeze, second display) |
