-- Two-screen stacking geometry: two 160x144 Game Boy screens with a small
-- black gutter, centred and integer-scaled into the window.  Pure math, no
-- love.graphics, so it is unit-testable and shared by the desktop in-window
-- path and the second-physical-display path.  Ported from the fork's
-- src/render/DualScreen.lua (the layout policy the engine deliberately does
-- not own; it lives here in the mod against the render.compose seam).

local Layout = {}

Layout.GAP = 8
Layout.W = 160
Layout.H = 144

function Layout.surfaceSize(orientation, w, h)
  w = w or Layout.W
  h = h or Layout.H
  if orientation == "horizontal" then
    return w * 2 + Layout.GAP, h
  end
  return w, h * 2 + Layout.GAP
end

-- regions in framebuffer pixels: the integer scale plus the two screen boxes.
-- pw/ph are the framebuffer pixel size of the window.  orientation is
-- "vertical" (world on top, ui below -- the default) or "horizontal" (world
-- left, ui right).
function Layout.regions(pw, ph, orientation, w, h)
  w = w or Layout.W
  h = h or Layout.H
  local surfW, surfH = Layout.surfaceSize(orientation, w, h)
  local scale = math.max(1, math.floor(math.min(pw / surfW, ph / surfH)))
  local boxW = w * scale
  local boxH = h * scale
  local gap = Layout.GAP * scale
  if orientation == "horizontal" then
    local ox = math.floor((pw - (boxW * 2 + gap)) / 2)
    local oy = math.floor((ph - boxH) / 2)
    local world = { ox = ox, oy = oy, w = boxW, h = boxH }
    local ui = { ox = ox + boxW + gap, oy = oy, w = boxW, h = boxH }
    return scale, world, ui
  end
  local ox = math.floor((pw - boxW) / 2)
  local top = math.floor((ph - (boxH * 2 + gap)) / 2)
  local world = { ox = ox, oy = top, w = boxW, h = boxH }
  local ui = { ox = ox, oy = top + boxH + gap, w = boxW, h = boxH }
  return scale, world, ui
end

-- which screen a window pixel falls in, for input/debug ("world" | "ui" | nil)
function Layout.screenAt(px, py, pw, ph, orientation, w, h)
  local _, world, ui = Layout.regions(pw, ph, orientation, w, h)
  local function inside(r)
    return px >= r.ox and px < r.ox + r.w and py >= r.oy and py < r.oy + r.h
  end
  if inside(world) then return "world" end
  if inside(ui) then return "ui" end
  return nil
end

return Layout
