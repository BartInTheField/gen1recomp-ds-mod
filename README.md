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
persisted per-save through `mod.save`.

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

## Status

- **Implemented & unit-checked:** the layout geometry (`layout.lua`) and the
  hook wiring/contract against the seam (mirrors the engine's
  `tests/engine/render_compose_seam.lua`).
- **Needs on-device verification:** the actual two-screen rendering, the frozen
  top-screen behaviour, and the Android second-display path require the LÖVE
  runtime (and, for the second display, multi-display Android hardware such as
  the AYN Thor). These were verified in the original fork; re-confirm here once
  the engine seam lands.
- **Not yet ported:** the DS-native battle *split* (battlefield on top, command/
  move/text window on bottom) is a follow-up layout on top of this base stacking.

## Layout

| module | role |
|---|---|
| `manifest.json` | mod metadata (`id: gen1recomp_ds`, api 2) |
| `layout.lua` | pure two-screen geometry (`regions`, `surfaceSize`, `screenAt`) |
| `main.lua` | options row + `render.compose` hook (stacking, freeze, second display) |
