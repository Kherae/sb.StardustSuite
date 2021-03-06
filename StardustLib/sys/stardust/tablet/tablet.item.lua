require "/lib/stardust/sync.lua"

--

function dump(o, ind)
  if not ind then ind = 2 end
  local pfx, epfx = "", ""
  for i=1,ind do pfx = pfx .. " " end
  for i=3,ind do epfx = epfx .. " " end
  if type(o) == 'table' then
    local s = '{\n'
    for k,v in pairs(o) do
      if type(k) ~= 'number' then k = '"'..k..'"' end
      s = s .. pfx .. '['..k..'] = ' .. dump(v, ind+2) .. ',\n'
    end
    return s .. epfx .. '}'
  else
    return tostring(o)
  end
end

--

function update(dt, fireMode, shiftHeld, moves)
  sync.runQueue()
  
  activeItem.setHoldingItem(false)
  
  if fireMode == "primary" and previousFireMode ~= "primary" then
    if status.stat("activeMovementAbilities") < 1 then
      fire(moves, shiftHeld)
    end
  end
  previousFireMode = fireMode
end

function fire(...)
  activeItem.interact("ScriptPane", "/sys/stardust/tablet/tablet.ui.config", activeItem.ownerEntityId())
end
