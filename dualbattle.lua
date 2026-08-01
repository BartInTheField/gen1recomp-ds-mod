-- DS-native battle split, ported from the fork's src/battle/DualBattle.lua.
-- Re-composes the live battle onto a 160x288 surface (field on the top screen,
-- command/move/text window on the bottom) by redrawing each element per side,
-- so nothing is sliced out of a finished composite. Reaches into BattleState
-- draw methods + PaletteFX; the caller capability-guards the whole module.

local PaletteFX = require("src.render.PaletteFX")

local DualBattle = { WIDTH = 160, HEIGHT = 288, SCREEN = 144 }

local ENEMY_DY = 4
local PLAYER_DY = 48
local MENU_DY = DualBattle.SCREEN

local function inRegion(y, h, dy, fn)
  local g = love.graphics
  local x0, y0, w0, h0
  if g.getScissor then x0, y0, w0, h0 = g.getScissor() end
  g.setScissor(0, y, DualBattle.WIDTH, h)
  g.push()
  g.translate(0, dy)
  -- pcall so the transform push and scissor stay balanced when a draw errors;
  -- re-raised for the caller's guard to degrade to base stacking
  local ok, err = pcall(fn)
  g.pop()
  if x0 then g.setScissor(x0, y0, w0, h0) else g.setScissor() end
  if not ok then error(err, 0) end
end

-- snap the animation layer to the side it plays on so cross-field effects land
-- on their mon instead of drifting (mirrors WideBattle, vertical)
local function animOffsetY(battle)
  local sprites
  if battle.animPlaying and battle.animPlayer then
    local step = battle.animPlayer.steps[battle.animPlayer.stepIndex]
    sprites = step and step.sprites
  elseif battle.lockedBall then
    sprites = battle.lockedBall
  end
  if not sprites or #sprites == 0 then return 0 end
  local minX, maxX = math.huge, -math.huge
  for _, s in ipairs(sprites) do
    minX = math.min(minX, s.x - 8)
    maxX = math.max(maxX, s.x)
  end
  return ((maxX + minX) / 2 < 80) and PLAYER_DY or ENEMY_DY
end

function DualBattle.draw(battle)
  local g = love.graphics

  local m = PaletteFX.mode
  if m == "og" or m == "og_inv" or m == "classic" then
    g.setColor(1, 1, 1, 1)
  else
    g.setColor(PaletteFX.paperShade(battle.data))
  end
  g.rectangle("fill", 0, 0, DualBattle.WIDTH, DualBattle.HEIGHT)
  g.setColor(1, 1, 1, 1)

  if battle.blankForAskName then return end

  local slide = (battle.introSlide or 0) * 4

  battle.wideRegion = true
  battle:drawPicsLayer(slide, 0, ENEMY_DY, "enemy", true)
  battle:drawPicsLayer(slide, 0, PLAYER_DY, "player", true)
  battle.wideRegion = nil

  -- force colorMode off so drawHPBar tints its own fill; the surface opts out
  -- of the zone pass, so nothing else would recolor it
  local realColorMode = battle.colorMode
  battle.colorMode = function() return false end
  inRegion(ENEMY_DY, 56, ENEMY_DY, function() battle:drawHUDs(slide) end)
  inRegion(56 + PLAYER_DY, DualBattle.SCREEN - (56 + PLAYER_DY), PLAYER_DY,
           function() battle:drawHUDs(slide) end)
  battle.colorMode = realColorMode

  inRegion(0, DualBattle.SCREEN, animOffsetY(battle),
           function() battle:drawAnimLayer(false) end)
  inRegion(MENU_DY, DualBattle.SCREEN, MENU_DY, function() battle:drawTextArea() end)
end

-- colorized modes opt the whole surface out of the zone pass (pics/HUDs draw
-- their own colors); forced-mono modes remap it to grays
function DualBattle.zones()
  local w, h = DualBattle.WIDTH, DualBattle.HEIGHT
  local m = PaletteFX.mode
  if m == "og" or m == "og_inv" or m == "classic" then
    return { PaletteFX.zone(PaletteFX.GRAYS, 0, 0, w / 8 - 1, h / 8 - 1) }
  end
  return { { colors = false, x = 0, y = 0, w = w, h = h } }
end

function DualBattle.canDraw(battle)
  return type(battle) == "table"
    and type(battle.drawPicsLayer) == "function"
    and type(battle.drawHUDs) == "function"
    and type(battle.drawAnimLayer) == "function"
    and type(battle.drawTextArea) == "function"
end

return DualBattle
