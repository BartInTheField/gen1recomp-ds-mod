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

  -- a mod-owned snapshot of the last world frame, shown frozen on the top
  -- screen while a full-screen state (battle, title menu) covers the world
  local frozen = { canvas = nil, zones = nil, w = 0, h = 0 }
  local function snapshot(canvas, zones)
    if not (canvas and canvas.getWidth) then return end
    local w, h = canvas:getWidth(), canvas:getHeight()
    if not frozen.canvas or frozen.w ~= w or frozen.h ~= h then
      if frozen.canvas and frozen.canvas.release then frozen.canvas:release() end
      frozen.canvas = love.graphics.newCanvas(w, h)
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
    return out
  end)

  -- the seam: lay the two passes out as two stacked screens, or hand control
  -- back to the engine when the mod is off.
  mod.hooks:wrap("render.compose", function(next, renderer, ctx)
    if not enabled() then return next() end

    mod.secondScreen = ctx.secondScreen
    local scale, world, ui = Layout.regions(ctx.pw, ctx.ph)
    local sx, sy = scale / ctx.dpiX, scale / ctx.dpiY

    -- keep the second display in sync with the toggle
    if ctx.secondScreen and ctx.secondScreen.setEnabled then
      ctx.secondScreen.setEnabled(true)
    end

    -- freeze the world while an opaque full-screen state covers it
    if ctx.worldActive then
      snapshot(ctx.worldCanvas, ctx.worldZones or ctx.zones)
    end
    local topCanvas = ctx.worldActive and ctx.worldCanvas or (frozen.canvas or ctx.worldCanvas)
    local topZones = ctx.worldActive and (ctx.worldZones or ctx.zones) or frozen.zones

    -- black window, then each pass palette-correct into its screen box (units)
    love.graphics.setCanvas()
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.rectangle("fill", 0, 0, ctx.ww, ctx.wh)
    love.graphics.setColor(1, 1, 1, 1)

    local function place(canvas, zones, box)
      if not (canvas and canvas.getWidth) then return end
      local bx, by = box.ox / ctx.dpiX, box.oy / ctx.dpiY
      local bw, bh = box.w / ctx.dpiX, box.h / ctx.dpiY
      renderer:blitCanvas(canvas, sx, sy, zones, sx, sy, bx, by, bx, by, bw, bh,
        ctx.dpiX, ctx.dpiY)
    end
    place(topCanvas, topZones, world)
    place(ctx.uiCanvas, ctx.zones, ui)

    -- multi-display Android: mirror the bottom (UI) screen onto the second
    -- physical display when one is attached
    local ss = ctx.secondScreen
    if ss and ss.available and ss.available() and ss.push and ctx.uiCanvas.newImageData then
      local ok, img = pcall(function() return ctx.uiCanvas:newImageData() end)
      if ok and img then
        pcall(ss.push, img, ctx.uiCanvas:getWidth(), ctx.uiCanvas:getHeight())
        if img.release then img:release() end
      end
    end

    return true
  end)
end
