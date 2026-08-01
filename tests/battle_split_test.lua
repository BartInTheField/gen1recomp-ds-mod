-- Headless proof for the DS-native battle split (run with luajit from the mod
-- root: `luajit tests/battle_split_test.lua`).
--
-- The mod re-composes the LIVE battle (reached through the engine's state
-- stack) onto a 160x288 surface -- field on the top screen, command/move/text
-- window on the bottom -- and blits the two halves into the two screen boxes.
-- It cannot run a real engine, so it stubs love.graphics, Renderer:blitCanvas,
-- the SecondScreen bridge, PaletteFX, and Game.stack with a fake battle state,
-- then invokes the render.compose callback and asserts:
--   1. a battle re-composes onto a 160x288 surface by calling the BattleState
--      draw methods at their DS anchors (enemy high, player at the foot, menu
--      on the bottom), wrapped in the PaletteFX "ui" pass;
--   2. single display: the field half (source rows 0-144) lands in the top
--      screen box and the menu half (rows 144-288) in the bottom screen box;
--   3. second display: the field fills the main panel, the menu half is pushed
--      as its own 160x144 screen;
--   4. no battle (or a battle buried under an opaque menu) falls back to the
--      base stacking (world/frozen top, flat UI bottom);
--   5. an error mid-draw restores the battle object's borrowed fields.

local ok, err = pcall(function()

local calls = 0
local function check(cond, msg)
  calls = calls + 1
  if not cond then error("FAIL: " .. msg, 2) end
end

-- ---- love.graphics stub ------------------------------------------------
local newCanvases = {}
local function newCanvas(w, h, settings)
  local c
  c = { w = w, h = h, dpiscale = settings and settings.dpiscale,
    getWidth = function() return c.w end,
    getHeight = function() return c.h end,
    setFilter = function() end, release = function() end,
    newImageData = function()
      return { getWidth = function() return c.w end,
               getHeight = function() return c.h end,
               release = function() end, getFFIPointer = function() return nil end }
    end,
  }
  newCanvases[#newCanvases + 1] = c
  return c
end
local G = { target = nil, color = { 1, 1, 1, 1 } }
love = {
  graphics = {
    newCanvas = newCanvas,
    setCanvas = function(c) G.target = c end,
    clear = function() end,
    setColor = function(r, g, b, a) G.color = { r, g, b, a } end,
    setShader = function() end,
    setScissor = function() end,
    getScissor = function() return nil end,
    push = function() end, pop = function() end, translate = function() end,
    rectangle = function() end, draw = function() end,
  },
}

-- ---- engine Renderer stub ---------------------------------------------
local blits = {}
local renderer = {
  blitCanvas = function(self, canvas, sx, sy, zones, zsx, zsy, bx, by,
                        boxX, boxY, boxW, boxH, dpiX, dpiY)
    blits[#blits + 1] = { canvas = canvas, target = G.target, sx = sx, sy = sy,
                          bx = bx, by = by, boxX = boxX, boxY = boxY,
                          boxW = boxW, boxH = boxH, zones = zones }
  end,
}

-- ---- PaletteFX stub (colorized mode: whole-surface trueColor opt-out) ---
local passes = {}
package.loaded["src.render.PaletteFX"] = {
  mode = "gbc",
  paperShade = function() return 1, 1, 1 end,
  GRAYS = { { 255, 255, 255 }, { 170, 170, 170 }, { 85, 85, 85 }, { 0, 0, 0 } },
  zone = function(colors, tx1, ty1, tx2, ty2)
    return { colors = colors, x = tx1 * 8, y = ty1 * 8,
             w = (tx2 - tx1 + 1) * 8, h = (ty2 - ty1 + 1) * 8 }
  end,
  setPass = function(name) passes[#passes + 1] = name == nil and "nil" or name end,
}

-- ---- fake battle state + Game.stack -----------------------------------
-- Upstream marks battles by class, NOT an isBattleScreen flag, so the fake
-- battle carries the BattleState metatable and no flag -- exercising the
-- metatable-identity detection the live engine actually needs.
local BattleStateMT = {}
package.loaded["src.battle.BattleState"] = BattleStateMT
local drawn = {}
local function newBattle()
  return setmetatable({
    isOpaque = true,
    data = {}, introSlide = 0, animPlaying = false,
    drawPicsLayer = function(self, slide, sx, sy, side)
      drawn[#drawn + 1] = { kind = "pics", side = side, sy = sy }
    end,
    drawHUDs = function() drawn[#drawn + 1] = { kind = "huds" } end,
    drawAnimLayer = function() drawn[#drawn + 1] = { kind = "anim" } end,
    drawTextArea = function() drawn[#drawn + 1] = { kind = "text" } end,
  }, BattleStateMT)
end
local Game = { stack = { states = {} } }
package.loaded["src.core.Game"] = Game

-- ---- mod sandbox stub -------------------------------------------------
local saved = { enabled = true }
local hooks = {}
local mod = {
  path = ".",
  read = function(_, name) local f = io.open(name); local s = f:read("*a"); f:close(); return s end,
  save = { get = function(_, k) return saved[k] end,
           set = function(_, k, v) saved[k] = v end },
  log = { error = function(_, ...) error(string.format(...)) end },
  hooks = { wrap = function(_, name, cb) hooks[name] = cb end },
}

local factory = assert(loadfile("main.lua"))()
factory(mod)
check(hooks["render.compose"] ~= nil, "mod registers a render.compose hook")

local Layout = dofile("layout.lua")
local worldCanvas = newCanvas(268, 160)
local uiCanvas = newCanvas(160, 144)         -- the flat battle composite (unused when split)
local zones = { { x = 0, y = 0, w = 160, h = 144, colors = { 1, 2, 3, 4 } } }
local singleScreen = {
  available = function() return false end,
  setEnabled = function() end,
  push = function() error("nothing should be pushed without a second display") end,
}
local function ctx(second)
  return {
    renderer = renderer, worldCanvas = worldCanvas, uiCanvas = uiCanvas,
    worldActive = false, zones = zones, worldZones = nil,   -- battle covers the world
    ww = 800, wh = 480, pw = 800, ph = 480,
    scale = 3, dpiX = 1, dpiY = 1, secondScreen = second or singleScreen,
  }
end

local function battleSurfaceBlits()
  local out = {}
  for _, b in ipairs(blits) do
    if b.target == nil and b.canvas and b.canvas.getHeight
       and b.canvas:getWidth() == 160 and b.canvas:getHeight() == 288 then
      out[#out + 1] = b
    end
  end
  return out
end

-- ---- (1) single-display stacked split ---------------------------------
Game.stack.states = { newBattle() }
drawn = {}; blits = {}; passes = {}
local handled = hooks["render.compose"](function() return false end, renderer, ctx())
check(handled == true, "battle: mod takes over composition")

-- the two-screen surface was re-composed by calling the BattleState methods
local pics, huds, anim, text = 0, 0, 0, 0
local enemySy, playerSy
for _, d in ipairs(drawn) do
  if d.kind == "pics" then
    pics = pics + 1
    if d.side == "enemy" then enemySy = d.sy elseif d.side == "player" then playerSy = d.sy end
  elseif d.kind == "huds" then huds = huds + 1
  elseif d.kind == "anim" then anim = anim + 1
  elseif d.kind == "text" then text = text + 1 end
end
check(pics == 2, "battle: both pics (enemy + player) are drawn once each")
check(huds == 2, "battle: both HUDs are drawn")
check(anim == 1 and text == 1, "battle: the anim layer and the text/menu window are drawn")
check(enemySy == 4 and playerSy == 48,
  "battle: the enemy anchors high (dy 4) and the player at the foot (dy 48)")
check(passes[1] == "ui" and passes[2] == "nil",
  "battle: the re-compose runs inside the PaletteFX 'ui' pass and restores it")

-- and blitted as two halves into the two screen boxes
local scale, world, ui = Layout.regions(800, 480, "vertical")
local top, bottom
for _, b in ipairs(battleSurfaceBlits()) do
  if b.boxY == world.oy then top = b elseif b.boxY == ui.oy then bottom = b end
end
check(top ~= nil, "split: the field half is blitted into the top screen box")
check(bottom ~= nil, "split: the menu half is blitted into the bottom screen box")
check(top.boxW == world.w and top.sx == scale,
  "split: the top screen is the layout world box at the layout scale")
check(top.by == world.oy,
  "split: the field half anchors source row 0 at the top box (srcY 0)")
check(bottom.by == ui.oy - 144 * scale,
  "split: the menu half anchors source row 144 at the bottom box (srcY 144)")
check(top.zones == bottom.zones and top.zones[1] and top.zones[1].colors == false,
  "split: colorized mode blits the surface raw (whole-surface trueColor opt-out)")
-- the flat battle composite is NOT used when the split runs
local flatUsed = false
for _, b in ipairs(blits) do if b.canvas == uiCanvas then flatUsed = true end end
check(not flatUsed, "split: the flat battle composite (ctx.uiCanvas) is not blitted")

-- ---- (2) side-by-side split -------------------------------------------
saved.sideBySide = true
drawn = {}; blits = {}; passes = {}
hooks["render.compose"](function() return false end, renderer, ctx())
local hscale, hworld, hui = Layout.regions(800, 480, "horizontal")
local lTop, rBottom
for _, b in ipairs(battleSurfaceBlits()) do
  if b.boxX == hworld.ox then lTop = b elseif b.boxX == hui.ox then rBottom = b end
end
check(lTop ~= nil and rBottom ~= nil,
  "side-by-side: field half on the left screen, menu half on the right screen")
check(rBottom.by == hui.oy - 144 * hscale,
  "side-by-side: the right screen still shows the menu half (srcY 144)")
saved.sideBySide = false

-- ---- (3) second physical display --------------------------------------
local pushed = {}
local secondScreen = {
  available = function() return true end,
  setEnabled = function() end,
  push = function(img, w, h) pushed[#pushed + 1] = { w = w, h = h } end,
}
drawn = {}; blits = {}; passes = {}
hooks["render.compose"](function() return false end, renderer, ctx(secondScreen))
check(#pushed == 1 and pushed[1].w == 160 and pushed[1].h == 144,
  "second display: exactly one 160x144 screen (the menu half) is pushed")
local fieldOnPanel = nil
for _, b in ipairs(battleSurfaceBlits()) do
  if b.target == nil and b.by ~= nil then fieldOnPanel = b end
end
check(fieldOnPanel ~= nil, "second display: the field is drawn to the main panel")
-- single-screen fit on the 800x480 panel is scale 3 (min(800/160, 480/144))
check(fieldOnPanel.sx == 3, "second display: the field fills the panel as one screen at the fit scale")

-- ---- (4) fallback: battle buried under an opaque menu -----------------
Game.stack.states = { newBattle(), { isOpaque = true, isBattleScreen = false } }
drawn = {}; blits = {}; passes = {}
hooks["render.compose"](function() return false end, renderer, ctx())
check(#drawn == 0, "fallback: an opaque menu over the battle drops the split (no re-compose)")
local uiUsed = false
for _, b in ipairs(blits) do if b.canvas == uiCanvas then uiUsed = true end end
check(uiUsed, "fallback: the flat UI composite is stacked on the bottom screen")

-- ---- (5) fallback: no battle in the stack -----------------------------
Game.stack.states = { { isOpaque = true, isBattleScreen = false } }
drawn = {}; blits = {}
hooks["render.compose"](function() return false end, renderer, ctx())
check(#drawn == 0, "no battle: nothing is re-composed")
check(#battleSurfaceBlits() == 0, "no battle: the 160x288 surface is not blitted")

-- ---- (6) a mid-draw error restores the battle's borrowed fields -------
local boom = newBattle()
local realCM = function() return true end
boom.colorMode = realCM
boom.drawHUDs = function() error("boom") end   -- fail after wideRegion/colorMode are borrowed
Game.stack.states = { boom }
blits = {}
local handled6 = hooks["render.compose"](function() return false end, renderer, ctx())
check(handled6 == true, "draw error: the mod still composes a frame (falls back gracefully)")
check(boom.colorMode == realCM, "draw error: battle.colorMode is restored, not left stubbed")
check(boom.wideRegion == nil, "draw error: battle.wideRegion is restored")
local uiFallback = false
for _, b in ipairs(blits) do if b.canvas == uiCanvas then uiFallback = true end end
check(uiFallback, "draw error: falls back to the flat UI composite")

-- ---- (7) fork-style detection: the isBattleScreen flag, no BattleState mt ----
local forkBattle = {
  isOpaque = true, isBattleScreen = true,
  data = {}, introSlide = 0, animPlaying = false,
  drawPicsLayer = function() drawn[#drawn + 1] = { kind = "pics" } end,
  drawHUDs = function() drawn[#drawn + 1] = { kind = "huds" } end,
  drawAnimLayer = function() drawn[#drawn + 1] = { kind = "anim" } end,
  drawTextArea = function() drawn[#drawn + 1] = { kind = "text" } end,
}
Game.stack.states = { forkBattle }
drawn = {}; blits = {}
hooks["render.compose"](function() return false end, renderer, ctx())
check(#drawn > 0 and #battleSurfaceBlits() == 2,
  "fork-style: a state flagged isBattleScreen (no BattleState metatable) still splits")

print(string.format("battle_split_test: %d checks passed", calls))
end)

if not ok then print(tostring(err)); os.exit(1) end
