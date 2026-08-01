-- Headless proof for the second-display colour + layout fix (run with luajit
-- from the mod root: `luajit tests/second_screen_color_test.lua`).
--
-- It cannot drive real Android, so it stubs love.graphics, the engine
-- Renderer:blitCanvas, and the SecondScreen bridge, then invokes the mod's
-- render.compose callback and asserts:
--   1. the image pushed to the second display is the palette-SHADED offscreen
--      canvas (drawn through blitCanvas), not the raw uiCanvas -- the colour bug;
--   2. on a second-display device the main panel is filled with the WORLD
--      screen (not the two-screen in-window stack) -- the layout bug.

local ok, err = pcall(function()

local calls = 0
local function check(cond, msg)
  calls = calls + 1
  if not cond then error("FAIL: " .. msg, 2) end
end

-- ---- love.graphics stub ------------------------------------------------
-- a device DPI > 1 (like the AYN Thor).  A canvas created WITHOUT dpiscale=1
-- allocates a texture at logical*DPI, and newImageData reads back those pixel
-- dims while getWidth/getHeight still report the logical size -- the exact
-- stride mismatch that sheared the second screen.
local FAKE_DPI = 2.755
local newCanvases = {}
local function newCanvas(w, h, settings)
  local ds = settings and settings.dpiscale
  local c
  c = {
    w = w, h = h, dpiscale = ds,
    getWidth = function() return c.w end,
    getHeight = function() return c.h end,
    setFilter = function() end,
    release = function() end,
    newImageData = function()
      local pw = (ds == 1) and c.w or math.floor(c.w * FAKE_DPI + 0.5)
      local ph = (ds == 1) and c.h or math.floor(c.h * FAKE_DPI + 0.5)
      return { w = pw, h = ph,
               getWidth = function() return pw end,
               getHeight = function() return ph end,
               release = function() end,
               getFFIPointer = function() return nil end }
    end,
  }
  newCanvases[#newCanvases + 1] = c
  return c
end
local G = { target = nil }
love = {
  graphics = {
    newCanvas = newCanvas,
    setCanvas = function(c) G.target = c end,
    clear = function() end,
    setColor = function() end,
    setShader = function() end,
    setScissor = function() end,
    rectangle = function() end,
    draw = function() end,
  },
}

-- ---- engine Renderer stub ---------------------------------------------
local blits = {}
local renderer = {
  blitCanvas = function(self, canvas, sx, sy, zones, zsx, zsy, bx, by,
                        boxX, boxY, boxW, boxH, dpiX, dpiY)
    blits[#blits + 1] = { canvas = canvas, target = G.target, sx = sx,
                          bx = bx, boxX = boxX, boxW = boxW, boxH = boxH, zones = zones }
  end,
}

-- ---- SecondScreen bridge stub (a display IS attached) -----------------
local pushed = {}
local secondScreen = {
  available = function() return true end,
  setEnabled = function() end,
  push = function(img, w, h) pushed[#pushed + 1] = { img = img, w = w, h = h } end,
}

-- ---- mod sandbox stub -------------------------------------------------
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

-- ---- load the mod and drive the seam ----------------------------------
local factory = assert(loadfile("main.lua"))()
factory(mod)
check(hooks["render.compose"] ~= nil, "mod registers a render.compose hook")

-- turn the option on (as the OPTIONS row would)
saved.enabled = true

-- world pass is window-view-sized (Renderer:worldViewSize = ceil(pw/scale) x
-- ceil(ph/scale)); on the 800x480 @scale 3 "panel" that is 268x160, wider
-- than a GB screen -- the case that broke centring on the Thor.
local worldCanvas = newCanvas(268, 160)
local uiCanvas = newCanvas(160, 144)
local zones = { { x = 0, y = 0, w = 160, h = 144, colors = { 1, 2, 3, 4 } } }
local ctx = {
  renderer = renderer, worldCanvas = worldCanvas, uiCanvas = uiCanvas,
  worldActive = true, zones = zones, worldZones = nil,
  ww = 800, wh = 480, pw = 800, ph = 480, ox = 0, oy = 0,
  vpw = 480, vph = 432, uiw = 160, uih = 144,
  scale = 3, Sx = 3, Sy = 3, dpiX = 1, dpiY = 1,
  secondScreen = secondScreen,
}

local baseCanvas = #newCanvases  -- fixtures above stand in for engine PixelCanvases
local handled = hooks["render.compose"](function() return false end, renderer, ctx)
check(handled == true, "the mod takes over composition (returns true)")

-- (1) colour: exactly one image pushed, and the blit that produced it drew
-- the uiCanvas while an OFFSCREEN target was bound (i.e. it was shaded, not
-- the raw uiCanvas grabbed verbatim)
check(#pushed == 1, "exactly one frame pushed to the second display")
check(pushed[1].w == 160 and pushed[1].h == 144, "pushed image is a 160x144 screen")
local shadedUiBlit = nil
for _, b in ipairs(blits) do
  if b.canvas == uiCanvas and b.target ~= nil then shadedUiBlit = b end
end
check(shadedUiBlit ~= nil,
  "the UI is blitted into an offscreen canvas (palette shader applied) before push")
check(shadedUiBlit.zones == zones,
  "the shaded UI blit carries the SGB zones so colours are baked in")

-- (1b) dpi stride: the pushed image must be a native 160x144 (not logical*DPI),
-- which only holds if every offscreen canvas is allocated with dpiscale=1 --
-- the fix for the sheared second screen on high-DPI Android.
check(pushed[1].w == 160 and pushed[1].h == 144,
  "pushed image is native 160x144 on a DPI>1 device (no row-stride shear)")
for i = baseCanvas + 1, #newCanvases do
  check(newCanvases[i].dpiscale == 1,
    "every mod-owned offscreen canvas is created with dpiscale=1")
end

-- (2) layout: on a second-display device the world FILLS the main panel (wide
-- aspect preserved) and is centred -- not a fixed 160x144 box. It is blitted
-- to the window (target == nil) at the fit scale.
local worldOnPanel = nil
for _, b in ipairs(blits) do
  if b.canvas == worldCanvas and b.target == nil then worldOnPanel = b end
end
check(worldOnPanel ~= nil, "the world screen is drawn to the main window panel")
check(worldOnPanel.sx == 3, "the world is drawn at the fit scale (3)")
check(worldOnPanel.boxW == ctx.ww,
  "the world fills the whole main panel (wide aspect preserved), not a 160x144 box")
check(worldOnPanel.bx == math.floor((ctx.pw - 268 * 3) / 2) / ctx.dpiX,
  "the wide world is centred on the panel")
-- and the UI is NOT stacked into the same window on a second-display device
local uiOnWindow = false
for _, b in ipairs(blits) do
  if b.canvas == uiCanvas and b.target == nil then uiOnWindow = true end
end
check(not uiOnWindow, "the UI is not stacked in the main window when a 2nd display exists")

-- ---- desktop / single-display path: no second display attached -----------
-- (the path the user confirmed working; guard the restructured else branch)
blits = {}
for i = #pushed, 1, -1 do pushed[i] = nil end
local singleScreen = {
  available = function() return false end,
  setEnabled = function() end,
  push = function() error("nothing should be pushed without a second display") end,
}
ctx.secondScreen = singleScreen
local handled2 = hooks["render.compose"](function() return false end, renderer, ctx)
check(handled2 == true, "single display: the mod still takes over composition")
check(#pushed == 0, "single display: nothing is pushed")
local worldStacked, uiStacked = nil, nil
local stackScale, worldBox, uiBox = dofile("layout.lua").regions(ctx.pw, ctx.ph)
for _, b in ipairs(blits) do
  if b.target == nil and b.canvas == worldCanvas then worldStacked = b end
  if b.target == nil and b.canvas == uiCanvas then uiStacked = b end
end
check(worldStacked ~= nil and worldStacked.sx == stackScale,
  "single display: the world screen is stacked at the layout scale")
check(worldStacked ~= nil and worldStacked.boxW == worldBox.w,
  "single display: the world is drawn into the 160-wide top screen box")
check(worldStacked ~= nil and worldStacked.bx < worldStacked.boxX,
  "single display: the wide world is centre-cropped in the box, not top-left")
check(uiStacked ~= nil and uiStacked.boxW == uiBox.w and uiStacked.bx == uiStacked.boxX,
  "single display: the 160x144 UI stacks with no crop offset")

print(string.format("second_screen_color_test: %d checks passed", calls))
end)

if not ok then print(tostring(err)); os.exit(1) end
