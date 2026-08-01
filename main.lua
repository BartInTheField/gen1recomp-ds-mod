-- gen1recomp-ds: dual-screen (DS-style) presentation as a pure mod.
--
-- Stacks the engine's world pass (top) and UI pass (bottom) as two Game Boy
-- screens instead of the single letterboxed composite.  All of it rides the
-- engine's `render.compose` seam (docs/modding.md) -- the engine owns no
-- dual-screen policy; this mod supplies the layout and, on multi-display
-- Android, drives the bottom screen onto a second physical display.
--
-- Requires an engine build that exposes render.compose + Renderer:blitCanvas
-- (bryanthaboi/gen1recomp#543).  On an engine without the seam the hook never
-- fires and the mod is inert.

local Layout = nil

return function(mod)
  do
    local src = mod:read("layout.lua")
    if not src then mod.log:error("layout.lua missing -- reinstall the mod"); return end
    local chunk, err = load(src, "@" .. tostring(mod.path) .. "/layout.lua")
    if not chunk then mod.log:error("layout.lua did not compile: %s", tostring(err)); return end
    Layout = chunk()
  end

  -- persisted toggle, namespaced to this mod (survives save/load)
  local function enabled()
    return mod.save:get("enabled") == true
  end
  local function setEnabled(on)
    mod.save:set("enabled", on and true or false)
  end

  -- second persisted toggle: lay the two screens out SIDE BY SIDE (world left,
  -- ui right) instead of stacked.  Only meaningful in the single-window path;
  -- the second-physical-display path ignores it (world fills the panel, ui is
  -- pushed to the other display), which is why the row is hidden there.
  local function sideBySide()
    return mod.save:get("sideBySide") == true
  end
  local function setSideBySide(on)
    mod.save:set("sideBySide", on and true or false)
  end

  -- a second physical display is attached (Android Presentation).  Learned
  -- from the render.compose ctx and stashed on the mod so the OPTIONS row can
  -- see it; nil/absent bridge means single display.
  local function secondDisplayAttached()
    local ss = mod.secondScreen
    return (ss and ss.available and ss.available()) and true or false
  end

  -- a mod-owned snapshot of the last world frame, shown frozen on the top
  -- screen while a full-screen state (battle, title menu) covers the world
  local frozen = { canvas = nil, zones = nil, w = 0, h = 0 }
  local function snapshot(canvas, zones)
    if not (canvas and canvas.getWidth) then return end
    local w, h = canvas:getWidth(), canvas:getHeight()
    if not frozen.canvas or frozen.w ~= w or frozen.h ~= h then
      if frozen.canvas and frozen.canvas.release then frozen.canvas:release() end
      frozen.canvas = love.graphics.newCanvas(w, h, { dpiscale = 1 })
      frozen.canvas:setFilter("nearest", "nearest")
      frozen.w, frozen.h = w, h
    end
    love.graphics.setCanvas(frozen.canvas)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setShader()
    love.graphics.draw(canvas, 0, 0)
    love.graphics.setCanvas()
    frozen.zones = zones
  end

  -- palette-shaded copy of a screen, reused across frames.  The image handed
  -- to a second physical display must carry the SGB/GBC colours the window
  -- blit applies through the shade-remap shader -- the raw uiCanvas is the
  -- un-colourised 4-shade DMG surface, and pushing it verbatim is why the
  -- second screen ignored the colour scheme.
  local shaded = { canvas = nil, w = 0, h = 0 }

  -- OPTIONS row: DUAL SCREEN (ON / OFF).  Decorate the list after next() so
  -- every other mod's rows survive.
  mod.hooks:wrap("ui.options.rows", function(next, game, rows)
    local out = next(game, rows)
    if type(out) ~= "table" then return out end
    out[#out + 1] = {
      id = "gen1recomp_ds",
      label = "DUAL SCREEN",
      value = function() return enabled() and "ON" or "OFF" end,
      activate = function()
        setEnabled(not enabled())
        local ss = mod.secondScreen
        if ss and ss.setEnabled then ss.setEnabled(enabled()) end
      end,
    }
    -- SPLIT LAYOUT (STACKED / SIDE BY SIDE): only when dual screen is on and
    -- no second physical display is attached (on such a device the split has
    -- no meaning, so the row is not offered).
    if enabled() and not secondDisplayAttached() then
      out[#out + 1] = {
        id = "gen1recomp_ds_split",
        label = "DS SPLIT",
        value = function() return sideBySide() and "SIDE BY SIDE" or "STACKED" end,
        activate = function() setSideBySide(not sideBySide()) end,
      }
    end
    return out
  end)

  -- the seam: lay the two passes out as two stacked screens, or hand control
  -- back to the engine when the mod is off.
  mod.hooks:wrap("render.compose", function(next, renderer, ctx)
    if not enabled() then return next() end

    mod.secondScreen = ctx.secondScreen
    local ss = ctx.secondScreen
    local physical = ss and ss.available and ss.available()
    if ss and ss.setEnabled then ss.setEnabled(true) end

    -- freeze the world while an opaque full-screen state covers it
    if ctx.worldActive then
      snapshot(ctx.worldCanvas, ctx.worldZones or ctx.zones)
    end
    local topCanvas = ctx.worldActive and ctx.worldCanvas or (frozen.canvas or ctx.worldCanvas)
    local topZones = ctx.worldActive and (ctx.worldZones or ctx.zones) or frozen.zones

    -- palette-correct blit of a screen `canvas` (with its SGB `zones`) into a
    -- window box at integer scale `s`; going through Renderer:blitCanvas is
    -- what applies the shade-remap shader, so colours match the window.  The
    -- canvas is CENTRED in the box: the world pass is window-view-sized
    -- (Renderer:worldViewSize), so a fixed 160x144 box must show its centre
    -- (the player-centred GB view) rather than the top-left crop, which would
    -- push the character off toward a corner on any non-GB-multiple window.
    -- A canvas that already matches the box (the 160x144 UI) centres to a
    -- zero offset, so it is unaffected.
    local function place(canvas, zones, box, s)
      if not (canvas and canvas.getWidth) then return end
      local cw, ch = canvas:getWidth(), canvas:getHeight()
      local oxpx = box.ox - math.floor((cw * s - box.w) / 2)
      local oypx = box.oy - math.floor((ch * s - box.h) / 2)
      local psx, psy = s / ctx.dpiX, s / ctx.dpiY
      local dx, dy = oxpx / ctx.dpiX, oypx / ctx.dpiY
      local bxx, bxy = box.ox / ctx.dpiX, box.oy / ctx.dpiY
      local bw, bh = box.w / ctx.dpiX, box.h / ctx.dpiY
      renderer:blitCanvas(canvas, psx, psy, zones, psx, psy, dx, dy, bxx, bxy, bw, bh,
        ctx.dpiX, ctx.dpiY)
    end

    -- colourise `canvas` into the reused offscreen canvas at 1:1 (own DPI-less
    -- box so scissorClamped keeps every SGB zone) and hand the opaque result
    -- to the second physical display.
    local function pushSecond(canvas, zones)
      if not (ss and ss.push and canvas and canvas.getWidth) then return end
      local w, h = canvas:getWidth(), canvas:getHeight()
      if not shaded.canvas or shaded.w ~= w or shaded.h ~= h then
        if shaded.canvas and shaded.canvas.release then shaded.canvas:release() end
        shaded.canvas = love.graphics.newCanvas(w, h, { dpiscale = 1 })
        shaded.canvas:setFilter("nearest", "nearest")
        shaded.w, shaded.h = w, h
      end
      love.graphics.setCanvas(shaded.canvas)
      love.graphics.clear(0, 0, 0, 1)
      love.graphics.setColor(1, 1, 1, 1)
      renderer:blitCanvas(canvas, 1, 1, zones, 1, 1, 0, 0, 0, 0, w, h, 1, 1)
      love.graphics.setCanvas()
      local ok, img = pcall(function() return shaded.canvas:newImageData() end)
      if ok and img then
        -- push the ImageData's own pixel dims: with dpiscale=1 they equal
        -- w x h, and they are what the buffer's row stride matches (a
        -- dpiscale>1 canvas would read back larger and shear on the wire).
        pcall(ss.push, img, img:getWidth(), img:getHeight())
        if img.release then img:release() end
      end
    end

    love.graphics.setCanvas()
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.rectangle("fill", 0, 0, ctx.ww, ctx.wh)
    love.graphics.setColor(1, 1, 1, 1)

    if physical then
      -- second physical display attached: the main panel shows the world, the
      -- bottom (UI) screen is colourised and pushed to the 2nd display.  The
      -- world pass canvas is already window-view-sized (Renderer:worldViewSize
      -- = ceil(pw/scale) x ceil(ph/scale)), so blit it exactly like normal
      -- single-screen mode -- actual canvas dims, fit scale, centred, scissored
      -- to the whole panel -- which fills the panel and keeps the wide aspect
      -- (a fixed 160x144 box would show only a crop, off-centre on a wide panel).
      if topCanvas and topCanvas.getWidth then
        local wsp = ctx.scale
        local wsx, wsy = wsp / ctx.dpiX, wsp / ctx.dpiY
        local wvw, wvh = topCanvas:getWidth(), topCanvas:getHeight()
        local wox = math.floor((ctx.pw - wvw * wsp) / 2) / ctx.dpiX
        local woy = math.floor((ctx.ph - wvh * wsp) / 2) / ctx.dpiY
        renderer:blitCanvas(topCanvas, wsx, wsy, topZones, wsx, wsy,
          wox, woy, 0, 0, ctx.ww, ctx.wh, ctx.dpiX, ctx.dpiY)
      end
      pushSecond(ctx.uiCanvas, ctx.zones)
    else
      -- single display: place the two screens in the one window, stacked or
      -- side by side per the DS SPLIT setting
      local orientation = sideBySide() and "horizontal" or "vertical"
      local scale, world, ui = Layout.regions(ctx.pw, ctx.ph, orientation)
      place(topCanvas, topZones, world, scale)
      place(ctx.uiCanvas, ctx.zones, ui, scale)
    end

    -- warp/area fade: the engine paints renderer.worldFadeAlpha over its
    -- composite, but that path is skipped once the hook returns true.
    local fade = renderer.worldFadeAlpha
    if fade and fade > 0 then
      love.graphics.setColor(0, 0, 0, fade)
      love.graphics.rectangle("fill", 0, 0, ctx.ww, ctx.wh)
      love.graphics.setColor(1, 1, 1, 1)
    end

    return true
  end)
end
