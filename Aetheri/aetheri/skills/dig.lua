require "/scripts/util.lua"
require "/scripts/vec2.lua"
require "/lib/stardust/playerext.lua"
require "/lib/stardust/color.lua"

local function squareVec(angle, size)
  local fa = angle / (math.pi * 2)
  local sa = math.floor(fa*4) * math.pi * 0.5
  return vec2.rotate({ (((fa*4)%1) - 0.5) * -size, size * 0.5}, sa)
end

local function lightBlockedAt(pos)
  local mat = world.material(pos, "foreground")
  if not mat then return false end
  mat = root.materialConfig(mat)
  if not mat then return false end
  return not mat.config.renderParameters.lightTransparent
end

local liquidAccumulator = {}
local function collectLiquid(pos)
  local ll = world.destroyLiquid(pos)
  if not ll then return false end
  -- add to accumulator, since level is floating-point
  liquidAccumulator[ll[1]] = (liquidAccumulator[ll[1]] or 0) + ll[2]
  return true
end

local function processLiquidAccumulation()
  for id, lv in pairs(liquidAccumulator) do
    local ct = math.floor(lv)
    if ct >= 1 then -- give integer portion of accumulated liquid as its item
      liquidAccumulator[id] = lv - ct
      local cfg = root.liquidConfig(id).config
      if cfg.itemDrop then player.giveItem({ name = cfg.itemDrop, count = ct, parameters = { } }) end
    end
  end
end

function collectItems(pt, radius)
  if world.itemDropQuery(pt, radius)[1] then -- only spawn stagehand if items are present in range, lest allocation lag occur for no reason
    world.spawnStagehand(pt, "stardustlib:itemcollector", { radius = radius, target = activeItem.ownerEntityId() })
  end
end

--

local range, strength, maxSize, upgrades
local activeTime = 0.55

local spark

function init()
  activeItem.setHoldingItem(true)
  activeItem.setTwoHandedGrip(false)
  activeItem.setBackArmFrame("rotation")
  
  range = root.assetJson("/player.config:initialBeamGunRadius") + status.statusProperty("bonusBeamGunRadius", 0)
  strength = config.getParameter("baseStrength", 5)
  maxSize = config.getParameter("baseSize", 3)
  
  upgrades = config.getParameter("skillUpgrades", { })
  
  local appearance = status.statusProperty("aetheri:appearance", { })
  local spcol = "ffffffbf"
  if appearance.coreHsl then
    local hsl = appearance.coreHsl
    spcol = color.fromHsl { hsl[1], hsl[2], (hsl[3] + hsl[4])/2 } --appearance.glowColor
  end
  spark = string.format("/aetheri/skills/spark.png?multiply=%s", color.toHex(spcol))
  
  animator.setSoundVolume("digging", 0.0, 0)
end

function uninit()
  --
end

local rot = 0.0

local blockFire = true
local active = 0 local wasActive
local layer = { primary = "foreground", alt = "background" }
local tileMark = "/aetheri/skills/tileMark.png?multiply=ffffff3f"
--local spark = "/aetheri/skills/spark.png?multiply=ffffffbf"
local tileMarkLayer = "foregroundEntity+1"
function update(dt, fireMode, shiftHeld)
  local aimPos = vec2.add(activeItem.ownerAimPosition(), vec2.mul(mcontroller.velocity(), dt))
  local angle, dir = activeItem.aimAngleAndDirection(0, aimPos)
  activeItem.setFacingDirection(dir)
  activeItem.setArmAngle(angle - mcontroller.rotation() * dir)
  
  rot = (2 + rot - dt * dir * 0.32) % 1
  
  local selSize = shiftHeld and 1 or maxSize
  local tilePos = { math.floor(0.5 + (aimPos[1] - selSize/2)), math.floor(0.5 + (aimPos[2] - selSize/2)) }
  local centerPos = vec2.add(tilePos, {selSize * 0.5, selSize * 0.5})
  local tiles = { }
  
  do
    local rv = {vec2.mag(vec2.sub(centerPos, mcontroller.position())), 0} -- straight line since this is relative to the *arm* :|
    --animator.setFlipped(mcontroller.facingDirection() < 0)
    animator.setFlipped(false)
    animator.setSoundPosition("digging", rv)
    animator.setSoundPosition("start", rv)
  end
  
  if (active > 0) ~= wasActive then -- sound
    animator.setSoundVolume("digging", active > 0 and 1.5 or 0.0, 0.1)
    if active > 0 then animator.playSound("start") animator.playSound("start2") animator.stopAllSounds("digging") animator.playSound("digging", -1) end
  end
  wasActive = active > 0 active = active - dt
  
  if vec2.mag(vec2.sub(centerPos, mcontroller.position())) > range + 0.5 then return nil end
  
  for x = 0, selSize - 1 do for y = 0, selSize - 1 do
    local p = {tilePos[1] + x + 0.5, tilePos[2] + y + 0.5}
    table.insert(tiles, p)
    local c = lightBlockedAt(p)
      and { 63, 63, 63 }
      or { 47, 47, 47 }
    playerext.queueLight {
      active = true,
      position = p,--vec2.sub(activeItem.ownerAimPosition(), mcontroller.position()),
      color = c,
      range = 1,
      pointLight = false,
    }
  end end
  
  -- draw sparks around outline
  for i = 0, 7 do
    playerext.queueDrawable {
      position = vec2.add(centerPos, squareVec((rot + (i/8)) * math.pi * 2, selSize + (2/16))),
      absolute = true,
      --rotation = rot * math.pi * -4,
      image = spark,
      renderLayer = tileMarkLayer,
      fullbright = true,
    }
  end
  
  if fireMode == "none" then fireMode = nil end
  if fireMode and not blockFire then
    local sp = vec2.add(aimPos, vec2.mul(vec2.sub(aimPos, mcontroller.position()), 50)) -- particles *away* from user
    if world.damageTiles(tiles, layer[fireMode], sp, "blockish", strength * status.stat("aetheri:miningSpeed") * dt * (1 + maxSize - selSize)^2) -- does as much total damage to one tile as it would to the full square
    then active = activeTime end
    
    if upgrades.autoCollectItems then collectItems(centerPos, selSize * 1.5) end
    
    if upgrades.gatherLiquids and fireMode ~= "alt" then
      for _, p in pairs(tiles) do
        if collectLiquid(p) then active = activeTime end
      end processLiquidAccumulation()
    end
  elseif not fireMode then
    blockFire = false
  end
end
