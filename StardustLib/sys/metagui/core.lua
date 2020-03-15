require "/scripts/util.lua"
require "/scripts/vec2.lua"
require "/scripts/rect.lua"

local function module(s) require("/sys/metagui/" .. s .. ".lua") end -- for easy repointing if needed

local debug = {
  --showLayoutBoxes = true,
}

-- metaGUI core
metagui = metagui or { }
local mg = metagui
mg.debugFlags = debug

module "gfx"

function mg.path(path)
  if not path then return nil end
  if path:sub(1, 1) == '/' then return path end
  return (mg.cfg.assetPath or "/") .. path
end

function mg.asset(path)
  if not path then return nil end
  if path:sub(1, 1) == '/' then return path end
  local ext = path:match('^.*%.(.-)$')
  if ext == "png" and not root.nonEmptyRegion(mg.cfg.themePath .. path) then return "/metagui/themes/fallbackAssets/" .. path end
  return mg.cfg.themePath .. path
end

do -- encapsulate
  local id = 0
  function mg.newUniqueId()
    id = id + 1
    return tostring(id)
  end
end

function mg.mkwidget(parent, param)
  local id = mg.newUniqueId()
  if not parent then
    pane.addWidget(param, id)
    return id
  end
  widget.addChild(parent, param, id)
  return table.concat{ parent, '.', id }
end

local getproto do
  local pt = { }
  getproto = function(parent)
    if not pt[parent] then
      pt[parent] = { __index = parent }
    end
    return pt[parent]
  end
  function mg.proto(parent, table) return setmetatable(table or { }, getproto(parent)) end
end

-- some operating variables
local redrawQueue = { }
local recalcQueue = { }
local lastMouseOver
local mouseMap = setmetatable({ }, { __mode = 'v' })
local scriptUpdate, scriptUninit = { }, { }

-- and widget stuff
mg.widgetTypes = { }
mg.widgetBase = {
  expandMode = {0, 0}, -- default: decline to expand in either direction (1 is "can", 2 is "wants to")
}
local widgetTypes, widgetBase = mg.widgetTypes, mg.widgetBase

function widgetBase:minSize() return {0, 0} end
function widgetBase:preferredSize() return {0, 0} end

function widgetBase:init() end

function widgetBase:queueRedraw() redrawQueue[self] = true end
function widgetBase:draw() end

function widgetBase:isMouseInteractable() return false end
function widgetBase:onMouseEnter() end
function widgetBase:onMouseLeave() end
function widgetBase:onMouseButtonEvent(btn, down) end

function widgetBase:captureMouse(btn) return mg.captureMouse(self, btn) end
function widgetBase:releaseMouse() return mg.releaseMouse(self) end
function widgetBase:hasMouse() return mg.hasMouse(self) end
function widgetBase:mouseCaptureButton() return mg.mouseCaptureButton(self) end
function widgetBase:mouseCapturePoint() return mg.mouseCapturePoint(self) end
function widgetBase:onCaptureMouseMove() end
function widgetBase:canPassMouseCapture() end
function widgetBase:onPassedMouseCapture() end
function widgetBase:passMouseCapture(w) -- pass to nearest accepting ancestor
  if not mg.hasMouse(self) then return nil end
  if not w then
    w = self.parent
    while w and not w:canPassMouseCapture() do w = w.parent end
  end
  if w then
    local pt = self:mouseCapturePoint()
    w:captureMouse(self:mouseCaptureButton())
    w:onPassedMouseCapture(pt)
    return true
  end
end

function widgetBase:grabFocus() return mg.grabFocus(self) end
function widgetBase:releaseFocus() return mg.releaseFocus(self) end
function widgetBase:onFocus() end
function widgetBase:onUnfocus() end
function widgetBase:onKeyEvent(key, down) end

function widgetBase:applyGeometry(selfOnly)
  self.size = self.size or self:preferredSize() -- fill in default size if absent
  local tp = self.position or {0, 0}
  local s = self
  while s.parent and not s.parent.isBaseWidget do
    tp = vec2.add(tp, s.parent.position or {0, 0})
    s = s.parent
  end
  s = s.parent -- we want the parent of the result
  -- apply calculated total position
  --sb.logInfo("processing " .. (self.backingWidget or "unknown") .. ", type " .. self.typeName)
  local etp
  if self.parent then etp = { tp[1], s.size[2] - (tp[2] + self.size[2]) } else etp = tp end -- if no parent, it must be a backing widget
  if self.backingWidget then
    widget.setSize(self.backingWidget, {math.floor(self.size[1]), math.floor(self.size[2])})
    widget.setPosition(self.backingWidget, {math.floor(etp[1]), math.floor(etp[2])})
  end
  --sb.logInfo("widget " .. (self.backingWidget or "unknown") .. ", type " .. self.typeName .. ", pos (" .. self.position[1] .. ", " .. self.position[2] .. "), size (" .. self.size[1] .. ", " .. self.size[2] .. ")")
  self:queueRedraw()
  if not selfOnly and self.children then
    for k,c in pairs(self.children) do
      if c.applyGeometry then c:applyGeometry() end
    end
  end
end

function widgetBase:queueGeometryUpdate() -- find root
  local w = self
  while w.parent do w = w.parent end
  recalcQueue[w] = true
end
function widgetBase:updateGeometry() end

function widgetBase:addChild(param) return mg.createWidget(param, self) end
function widgetBase:clearChildren()
  local c = { }
  for _, v in pairs(self.children or { }) do table.insert(c, v) end
  for _, v in pairs(c) do v:delete() end
end
function widgetBase:delete()
  widgetBase.clearChildren(self) -- clear down first
  if self.parent then -- remove from parent
    for k, v in pairs(self.parent.children) do
      if v == self then table.remove(self.parent.children, k) break end
    end
    self.parent:queueGeometryUpdate()
  end
  if self.id and _ENV[self.id] == self then _ENV[self.id] = nil end -- remove from global
  self.deleted = true
  
  -- unhook from events and drawing
  redrawQueue[self] = nil
  recalcQueue[self] = nil
  if lastMouseOver == this then lastMouseOver = nil end
  self:releaseMouse()
  
  -- clear out backing widgets
  local function rw(w)
    local parent, child = w:match('^(.*)%.(.-)$')
    widget.removeChild(parent, child)
  end
  if self.backingWidget then rw(self.backingWidget) end
  if self.subWidgets then for _, sw in pairs(self.subWidgets) do rw(sw) end end
end

-- find parent of specific widget type
function widgetBase:findParent(wtype)
  local p = self
  while p.parent do p = p.parent
    if p.widgetType == wtype then return p end
  end
end

-- event subscription stuff
function widgetBase:subscribeEvent(ev, f)
  self.__event = self.__event or { }
  self.__event[ev] = f
end
function widgetBase:pushEvent(ev, ...)
  if self.__event then
    local e = self.__event[ev]
    if e and e(...) then return nil end -- return true to "catch"
  end
  -- else pass to children
  for _,c in pairs(self.children or { }) do c:pushEvent(ev, ...) end
end
function widgetBase:broadcast(ev, ...) self.parent:pushEvent(ev, ...) end -- just a quick shortcut

module "widgets"

-- populate type names
for id, t in pairs(widgetTypes) do t.widgetType = id end

function mg.createWidget(param, parent)
  if not param or not param.type or not widgetTypes[param.type] then return nil end -- abort if not valid
  local w = mg.proto(widgetTypes[param.type])
  if parent then -- add as child
    w.parent = parent
    w.parent.children = w.parent.children or { }
    table.insert(w.parent.children, w)
    parent:queueGeometryUpdate()
  end
  
  -- some basics
  w.id = param.id
  w.position = param.position or {0, 0}
  w.explicitSize = param.size
  w.size = param.size
  
  local base
  if parent then -- find base widget
    local f = parent
    while not f.isBaseWidget and f.parent do f = f.parent end
    base = f.backingWidget
  end
  w:init(base, param)
  
  -- enroll in mouse events
  if w.backingWidget then mouseMap[w.backingWidget] = w end
  if w.subWidgets then for _, sw in pairs(w.subWidgets) do mouseMap[sw] = w end end
  
  -- assign id
  if w.id and _ENV[w.id] == nil then
    _ENV[w.id] = w
  end
  return w
end

function mg.createImplicitLayout(list, parent, defaults)
  list = list or { }
  local p = { type = "layout", children = list }
  if parent then -- inherit some defaults off parent
    if parent.mode == "horizontal" then p.mode = "vertical"
    elseif parent.mode == "vertical" then p.mode = "horizontal" end
    p.spacing = parent.spacing
  end
  
  if defaults then util.mergeTable(p, defaults) end
  if type(list[1]) == "table" and not list[1][1] and not list[1].type then util.mergeTable(p, list[1]) end
  return mg.createWidget(p, parent)
end

local redrawFrame = { draw = function() theme.drawFrame() end }
function mg.setTitle(s)
  mg.cfg.title = s
  redrawQueue[redrawFrame] = true
end
function mg.setIcon(img)
  mg.cfg.icon = mg.path(img)
  redrawQueue[redrawFrame] = true
end

local mouseCaptor, mouseCaptureBtn, mouseCapturePoint
function mg.captureMouse(w, btn)
  if w ~= mouseCaptor then
    mouseCaptor, mouseCaptureBtn, mouseCapturePoint = w, btn, mg.mousePosition
    return true
  end
end
function mg.releaseMouse(w) if w == mouseCaptor or not w then mouseCaptor = nil return true end end
function mg.mouseCaptureButton(w) if mouseCaptor and (w == mouseCaptor or not w) then return mouseCaptureBtn end end
function mg.mouseCapturePoint(w) if mouseCaptor and (w == mouseCaptor or not w) then return mouseCapturePoint end end
function mg.hasMouse(w) return w == mouseCaptor end

local keyFocus
function mg.grabFocus(w)
  if w ~= keyFocus then
    if keyFocus then keyFocus:onUnfocus() end
    keyFocus = w
    if keyFocus then keyFocus:onFocus() end
  end
end
function mg.releaseFocus(w) if w == keyFocus or w == true then mg.grabFocus(nil) return true end end

function mg.broadcast(ev, ...) paneBase:pushEvent(ev, ...) frame:pushEvent(ev, ...) end

-- -- --

local worldId
function init() -------------------------------------------------------------------------------------------------------------------------------------
  mg.cfg = config.getParameter("___") -- window config
  mg.inputData = mg.cfg.inputData -- alias
  
  mg.theme = root.assetJson(mg.cfg.themePath .. "theme.json")
  mg.theme.id = mg.cfg.theme
  mg.theme.path = mg.cfg.themePath
  _ENV.theme = mg.theme -- alias
  require(mg.theme.path .. "theme.lua") -- load in theme
  
  mg.cfg.icon = mg.path(mg.cfg.icon) -- pre-resolve icon path
  
  -- TODO set up some parameter stuff?? idk, maybe the theme does most of that
  
  -- store this for later
  worldId = player.worldId()
  
  -- set up IPC
  do local mt = getmetatable ''
    mt.metagui_ipc = mt.metagui_ipc or { }
    mg.ipc = mt.metagui_ipc
  end
  
  if mg.cfg.uniqueBy == "path" and mg.cfg.configPath then
    mg.ipc.uniqueByPath = mg.ipc.uniqueByPath or { }
    mg.ipc.uniqueByPath[mg.cfg.configPath] = function() pane.dismiss() end
  end
  
  -- set up basic pane stuff
  local borderMargins = mg.theme.metrics.borderMargins[mg.cfg.style]
  frame = mg.createWidget({ type = "layout", size = mg.cfg.totalSize, position = {0, 0}, zlevel = -9999 })
  paneBase = mg.createImplicitLayout(mg.cfg.children, nil, { size = mg.cfg.size, position = {borderMargins[1], borderMargins[4]}, mode = mg.cfg.layoutMode or "vertical" })
  
  mg.theme.decorate()
  mg.theme.drawFrame()
  
  local sysUpdate, sysUninit = update, uninit
  for _, s in pairs(mg.cfg.scripts or { }) do
    init, update, uninit = nil
    require(mg.path(s))
    if update then table.add(scriptUpdate, update) end
    if uninit then table.add(scriptUninit, uninit) end
    if init then init() end -- call script init
  end
  update, uninit = sysUpdate, sysUninit
  
  frame:updateGeometry()
  paneBase:updateGeometry()
  for w in pairs(redrawQueue) do w:draw() end
  recalcQueue, redrawQueue = { }, { }
  
  --setmetatable(_ENV, {__index = function(_, n) if DBG then DBG:setText("unknown func " .. n) end end})
end

function uninit()
  for _, f in pairs(scriptUninit) do f() end
  if mg.ipc.uniqueByPath and mg.cfg.configPath then mg.ipc.uniqueByPath[mg.cfg.configPath] = nil end
end

local eventQueue = { }
local function runEventQueue()
  local next = { }
  for _, v in pairs(eventQueue) do
    local f, err = coroutine.resume(v)
    if coroutine.status(v) ~= "dead" then table.insert(next, v) -- execute; insert in next-frame queue if still running
    elseif not f then sb.logError(err) end
  end
  eventQueue = next
  theme.update()
  for _, f in pairs(scriptUpdate) do f() end
end
function mg.startEvent(func, ...)
  local c = coroutine.create(func)
  coroutine.resume(c, ...)
  if coroutine.status(c) ~= "dead" then table.insert(eventQueue, c) end
  return c -- might as well
end

local function findWindowPosition()
  if not mg.windowPosition then mg.windowPosition = {0, 0} end -- at the very least, make sure this exists
  local fp
  local sz = mg.cfg.totalSize
  local max = {1920, 1080} -- technically probably 4k
  
  local ws = "_tracker" -- widget to search for
  
  -- initial find
  for y=0,max[2],sz[2] do
    for x=0,max[1],sz[1] do
      if widget.inMember(ws, {x, y}) then
        fp = {x, y} break
      end
    end
    if fp then break end
  end
  
  if not fp then return nil end -- ???
  
  local isearch = 32
  -- narrow x
  local search = isearch
  while search >= 1 do
    while widget.inMember(ws, {fp[1] - search, fp[2]}) do fp[1] = fp[1] - search end
    search = search / 2
  end
  
  -- narrow y
  local search = isearch
  while search >= 1 do
    while widget.inMember(ws, {fp[1], fp[2] - search}) do fp[2] = fp[2] - search end
    search = search / 2
  end
  
  mg.windowPosition = fp
end

mg.mousePosition = {0, 0} -- default

local bcv = { "_tracker", "_mouse", "_keys" }
local bcvmp = { {0, 0}, {0, 0}, {0, 0} } -- last saved mouse position

local lastMouseOver
function update()
  if player.worldId() ~= worldId then return pane.dismiss() end
  
  if not mg.windowPosition then
    findWindowPosition()
  else
    if not widget.inMember(bcv[1], mg.windowPosition) or not widget.inMember(bcv[1], vec2.add(mg.windowPosition, mg.cfg.totalSize)) then findWindowPosition() end
  end
  
  local lmp = mg.mousePosition
  -- we don't know which of these gets mouse changes properly, so we loop through and
  for k,v in pairs(bcv) do -- set the mouse position whenever one detects a change
    local bc = widget.bindCanvas(v)
    if bc then
      local mp = bc:mousePosition()
      if not vec2.eq(bcvmp[k], mp) then
        bcvmp[k] = mp
        mg.mousePosition = mp
        bcvmp[0] = true
      end
    end
  end
  
  runEventQueue() -- not entirely sure where this should go in the update cycle
  
  local mw = mouseCaptor
  if not mw then
    local mwc = widget.getChildAt(vec2.add(mg.windowPosition, mg.mousePosition))
    mwc = mwc and mwc:sub(2)
    while mwc and not mouseMap[mwc] do
      mwc = mwc:match('^(.*)%..-$')
    end
    if mwc then mw = mouseMap[mwc] end
    while mw and not mw:isMouseInteractable() do
      mw = mw.parent
    end
  end
  
  if mw ~= lastMouseOver then
    if mw then mw:onMouseEnter() end
    if lastMouseOver then lastMouseOver:onMouseLeave() end
  end
  lastMouseOver = mw
  widget.setVisible(bcv[2], not not (mw or keyFocus))
  
  if mouseCaptor then -- send mouse move event
    mouseCaptor:onCaptureMouseMove(vec2.sub(mg.mousePosition, lmp))
  end
  
  do -- handle key focus widget
    local kf, kw = not not keyFocus, not not widget.bindCanvas(bcv[3])
    if kf ~= kw then
      if kf then pane.addWidget({ type = "canvas", size = {0, 0}, zlevel = -99998, captureKeyboardEvents = true }, bcv[3])
      else pane.removeWidget(bcv[3]) end
    end
  end
  
  if keyFocus then widget.focus(bcv[3])
  elseif mw then widget.focus(bcv[2])
  else widget.focus(bcv[1]) end
  
  for w in pairs(recalcQueue) do w:updateGeometry() end
  for w in pairs(redrawQueue) do w:draw() end
  redrawQueue = { } recalcQueue = { }
end

function cursorOverride(pos)
  if not bcvmp[0] then -- no registered mouse positions
    if mg.windowPosition then mg.mousePosition = vec2.sub(pos, mg.windowPosition) end
  else
    --
  end
end

function createTooltip()
  --return "lol"
end

function _mouseEvent(_, btn, down)
  if lastMouseOver then
    local w = lastMouseOver
    while not w:isMouseInteractable() or not w:onMouseButtonEvent(btn, down) do
      w = w.parent
      if not w then break end
    end
  end
  if down and keyFocus and keyFocus ~= lastMouseOver then mg.grabFocus() end -- clear focus on clicking other widget
end
function _clickLeft() _mouseEvent(nil, 0, true) end
function _clickRight() _mouseEvent(nil, 2, true) end

function _keyEvent(key, down) if keyFocus then keyFocus:onKeyEvent(key, down) end end
