hud = { }

local px = 1/8 -- tile to pixel

local apGainAmt = 0
local apGainTime = 0
local apGainColor = ""

local manaShowTime = 0

local hudLayer = "foregroundEntity+5"

local function safeFloor(num)
  if (type(num) ~= "number") or (num ~= num) or (num + 1 == num) then return 0 end -- starbound has faulty NaN behavior??
  return math.floor(num)
end

function hud.update(p)
  --
  if itemutil.property(world.entityHandItemDescriptor(entity.id(), "primary"), "isAetherSkill") and status.resourcePercentage("aetheri:mana") < 1.0 then
    manaShowTime = 2
  end
  if manaShowTime > 0 then
    -- mana gauge
    local numWidth = 5
    local drw = { }
    local str = string.format("%d/%d", math.floor(0.5 + status.resource("aetheri:mana") or 0), math.floor(0.5 + status.resourceMax("aetheri:mana") or 0))
    --local str = string.format("%d", safeFloor(0.5 + status.resourcePercentage("aetheri:mana") * 100))
    local off = ((str:len() - 1) * numWidth - 4) * -0.5
    local mult = string.format("?multiply=ffffff%02x", math.floor(0.5 + math.min(1, manaShowTime) * 255))
    local y = playerext.getHUDPosition("bottom", 1)
    for i = 1, str:len() do
      table.insert(drw, {
        position = { (off + (i - 1) * numWidth) * px, y },
        image = string.format("/aetheri/species/hud/ap.png:num%s%s", str:sub(i, i), mult),
        fullbright = true,
        renderLayer = hudLayer
      })
    end
    playerext.queueDrawable(table.unpack(drw))
    manaShowTime = manaShowTime - p.dt
  end
  
  if apGainTime > 0 then
    local dispTime = util.clamp(apGainTime, 0, 1) -- limit display without limiting timing
    local numWidth = 5
    local drw = { }
    local str = string.format("+%dA", math.floor(0.5 + apGainAmt))
    local off = (str:len() - 1) * numWidth * -0.5
    local mult = string.format("?multiply=%s?multiply=ffffff%02x", apGainColor, math.floor(0.5 + dispTime * 255))
    local y = (16 + math.floor((1 - dispTime) * 40)) * px
    for i = 1, str:len() do
      table.insert(drw, {
        position = { (off + (i - 1) * numWidth) * px, y },
        image = string.format("/aetheri/species/hud/ap.png:num%s%s", str:sub(i, i), mult),
        fullbright = true,
        renderLayer = hudLayer
      })
    end
    playerext.queueDrawable(table.unpack(drw))
    apGainTime = apGainTime - p.dt / 0.75
    --
  end
  
end

function hud.gainAP(amt)
  apGainColor = color.toHex(color.fromHsl{ appearance.settings.coreHsl[1], appearance.settings.coreHsl[2], 0.85 })
  apGainAmt = amt + (apGainTime > 0 and apGainAmt or 0)
  if amt >= 10 then apGainTime = 1 + util.clamp((apGainAmt-100)/4900, 0, 1) end -- higher amounts/combos display for longer
end
