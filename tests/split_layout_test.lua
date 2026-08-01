-- Headless proof for the side-by-side split (run with luajit from the mod
-- root: `luajit tests/split_layout_test.lua`).
--
-- Covers the new DS SPLIT setting:
--   1. layout.lua grows a "horizontal" orientation: two 160x144 boxes laid
--      out left/right with the gutter between, vs. the default stacked top/bottom;
--   2. the render.compose single-display path honours the setting (world/ui
--      placed into the horizontal boxes when SIDE BY SIDE is on);
--   3. the OPTIONS row for the split is offered on a single display but hidden
--      when a second physical display is attached.

local ok, err = pcall(function()

local calls = 0
local function check(cond, msg)
  calls = calls + 1
  if not cond then error("FAIL: " .. msg, 2) end
end

-- ---- (1) pure geometry -------------------------------------------------
local Layout = dofile("layout.lua")

-- 800x480: horizontal surface is 328x144 -> scale 2; vertical is 160x296 -> scale 1
local hScale, hWorld, hUi = Layout.regions(800, 480, "horizontal")
check(hScale == 2, "horizontal: integer scale fits the side-by-side surface")
check(hWorld.w == 320 and hWorld.h == 288, "horizontal: world box is 160x144 * scale")
check(hUi.w == hWorld.w and hUi.h == hWorld.h, "horizontal: both boxes are equal size")
check(hUi.oy == hWorld.oy, "horizontal: boxes share the top edge (laid out side by side)")
check(hUi.ox == hWorld.ox + hWorld.w + Layout.GAP * hScale,
  "horizontal: ui box sits to the right of the world box across the gutter")

local vScale, vWorld, vUi = Layout.regions(800, 480, "vertical")
check(vUi.ox == vWorld.ox, "vertical: boxes share the left edge (stacked)")
check(vUi.oy == vWorld.oy + vWorld.h + Layout.GAP * vScale,
  "vertical: ui box sits below the world box across the gutter")

-- default (nil orientation) stays vertical: back-compat for existing callers
local _, dWorld, dUi = Layout.regions(800, 480)
check(dUi.ox == dWorld.ox and dUi.oy > dWorld.oy, "default orientation is stacked (vertical)")

-- screenAt threads the orientation through
check(Layout.screenAt(hUi.ox + 1, hUi.oy + 1, 800, 480, "horizontal") == "ui",
  "screenAt honours horizontal orientation")

-- ---- stubs to drive the mod hooks --------------------------------------
local G = { target = nil, color = { 1, 1, 1, 1 } }
local function newCanvas(w, h, settings)
  local c
  c = { w = w, h = h,
    getWidth = function() return c.w end,
    getHeight = function() return c.h end,
    setFilter = function() end, release = function() end,
    newImageData = function()
      return { getWidth = function() return c.w end,
               getHeight = function() return c.h end,
               release = function() end, getFFIPointer = function() return nil end }
    end,
  }
  return c
end
love = {
  graphics = {
    newCanvas = newCanvas,
    setCanvas = function(c) G.target = c end,
    clear = function() end,
    setColor = function(r, g, b, a) G.color = { r, g, b, a } end,
    setShader = function() end, setScissor = function() end,
    rectangle = function() end, draw = function() end,
  },
}

local blits = {}
local renderer = {
  blitCanvas = function(self, canvas, sx, sy, zones, zsx, zsy, bx, by,
                        boxX, boxY, boxW, boxH)
    blits[#blits + 1] = { canvas = canvas, target = G.target,
                          boxX = boxX, boxW = boxW }
  end,
}

local saved = {}
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
check(hooks["ui.options.rows"] ~= nil, "mod registers an options-rows hook")

local worldCanvas = newCanvas(268, 160)
local uiCanvas = newCanvas(160, 144)
local zones = { { x = 0, y = 0, w = 160, h = 144, colors = { 1, 2, 3, 4 } } }
local singleScreen = {
  available = function() return false end,
  setEnabled = function() end,
  push = function() error("nothing should be pushed without a second display") end,
}
local function ctx()
  return {
    renderer = renderer, worldCanvas = worldCanvas, uiCanvas = uiCanvas,
    worldActive = true, zones = zones, worldZones = nil,
    ww = 800, wh = 480, pw = 800, ph = 480,
    scale = 3, dpiX = 1, dpiY = 1, secondScreen = singleScreen,
  }
end

-- ---- (2) render path honours SIDE BY SIDE ------------------------------
saved.enabled = true
saved.sideBySide = true
blits = {}
local handled = hooks["render.compose"](function() return false end, renderer, ctx())
check(handled == true, "side-by-side: mod takes over composition")
local hs, hw, hu = Layout.regions(800, 480, "horizontal")
local worldBox, uiBox = nil, nil
for _, b in ipairs(blits) do
  if b.target == nil and b.canvas == worldCanvas then worldBox = b end
  if b.target == nil and b.canvas == uiCanvas then uiBox = b end
end
check(worldBox ~= nil and worldBox.boxW == hw.w,
  "side-by-side: world is drawn into the horizontal world box")
check(uiBox ~= nil and uiBox.boxW == hu.w and uiBox.boxX == hu.ox,
  "side-by-side: ui is drawn into the horizontal ui box (to the right)")

-- OFF -> stacked: the ui box left edge differs from the horizontal one
saved.sideBySide = false
blits = {}
hooks["render.compose"](function() return false end, renderer, ctx())
local _, _, vBox = Layout.regions(800, 480, "vertical")
local uiStacked = nil
for _, b in ipairs(blits) do
  if b.target == nil and b.canvas == uiCanvas then uiStacked = b end
end
check(uiStacked ~= nil and uiStacked.boxX == vBox.ox,
  "stacked: ui is drawn into the vertical ui box")

-- ---- (3) options-row gating --------------------------------------------
local function splitRow()
  local out = hooks["ui.options.rows"](function() return {} end, {}, {})
  for _, r in ipairs(out) do
    if r.id == "gen1recomp_ds_split" then return r end
  end
  return nil
end

-- single display, dual screen on: the split row is offered
mod.secondScreen = singleScreen
check(splitRow() ~= nil, "gating: DS SPLIT row is offered on a single display")

-- dual screen off: no split row (setting only makes sense when DS is on)
saved.enabled = false
check(splitRow() == nil, "gating: DS SPLIT row is hidden when dual screen is off")
saved.enabled = true

-- a second physical display is attached: the split row is hidden
mod.secondScreen = {
  available = function() return true end,
  setEnabled = function() end, push = function() end,
}
check(splitRow() == nil,
  "gating: DS SPLIT row is hidden when a second physical display is attached")

print(string.format("split_layout_test: %d checks passed", calls))
end)

if not ok then print(tostring(err)); os.exit(1) end
