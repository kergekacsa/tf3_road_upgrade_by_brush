-- Tests of the input actions that the tool recipe of brush_upgrade.script.tl registers on its menu entry, and of the
-- focus target that it returns for a controller.
-- The recipe component sits inside the entry of the construction menu. In gamepad mode the menu renders it with
-- isActive = false until the player activates the entry. constructOpt1 and constructOpt2 share the buttons dpright and
-- dpleft with IA_NAV_RIGHT and IA_NAV_LEFT, so a registration on an inactive entry takes the menu navigation.
-- Every module and the game are stand-ins: the test proves which actions the recipe registers and what their handlers
-- ask of the menu, not what the game does with them.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check = support.check

-- A stand-in that answers every index, call and operator, so the script loads without the game.
local any
any = setmetatable({}, {
  __index = function() return any end,
  __call = function() return any end,
  __concat = function() return "" end,
  __add = function() return 0 end,
  __sub = function() return 0 end,
  __len = function() return 0 end,
  __lt = function() return false end,
  __le = function() return false end,
  __tostring = function() return "any" end,
})
-- A table with the given fields that answers every other index with the stand-in.
local function over(fields) return setmetatable(fields, { __index = any }) end

local noop = function() end
local recipes = {}
local registered, events, fired, mounts = {}, {}, {}, {}
-- The states and refs of the recipe keep their value from one render to the next, by the order of the calls.
local hooks, hookIndex = {}, 0
local function hook(initial)
  hookIndex = hookIndex + 1
  if hooks[hookIndex] == nil then
    local value = initial
    local h = {}
    function h:old() return value end
    function h:get() return value end
    function h:set(v) value = v end
    hooks[hookIndex] = h
  end
  return hooks[hookIndex]
end
local react = {
  RegisterRecipe = function(name, fn) recipes[name] = fn; return fn end,
  useState = hook, useRef = hook, useNodeRef = hook, useSelfRef = hook,
  ref = function(r) return r end,
  onStep = noop, onUnmount = noop,
  onMount = function(fn) mounts[#mounts + 1] = fn end,
  onEvent = function(name, fn) events[name] = fn end,
  fireEvent = function(_source, name) fired[#fired + 1] = name end,
  setForceFocusable = noop, setRestrictMouseFocus = noop,
  iaHandler = function(fn, enabled) return { fn = fn, enabled = enabled } end,
  useInputAction = function(action, handler) registered[action] = handler end,
}
local perf = { on = false }
function perf:start() return 0 end
function perf:stop() end
function perf:phase() end
function perf:wrap(_name, fn) return fn end

local inputMode = "mouse"
_G.api = over({
  util = over({ getInputMode = function() return inputMode end }),
  type = over({ enum = over({ InputMode = { Gamepad = "pad" } }) }),
  gui = over({ inputAction = over({ InputActionState = { Enabled = "Enabled", Disabled = "Disabled" } }) }),
})
_G.log = any
_G._ = function(text) return text end
_G.ug_require = function(path)
  if path:find("/gui/main/react.lua", 1, true) then return react end
  if path:find("/sqperf/", 1, true) then return { new = function() return perf end } end
  return any
end

assert(loadfile(support.buildDir .. "/brush_upgrade.script.lua"))()
local recipe = assert(recipes["BrushUpgradeAction"], "the tool recipe is not registered")

local actionFn
-- A new instance of the recipe in the given input mode.
local function fresh(mode)
  inputMode = mode
  hooks = {}
end
-- One render. Returns the names of the registered actions and what the recipe returned.
local function render(isActive)
  registered, events, mounts, hookIndex = {}, {}, {}, 0
  local result = recipe({ isActive = isActive, setActionFn = function(fn) actionFn = fn end, abort = noop,
    getCurrentParams = function() return {} end, gameCtx = any })
  local names = {}
  for name in pairs(registered) do names[#names + 1] = name end
  table.sort(names)
  return table.concat(names, ", "), result
end
-- Mounts the world layer: renders the action of the tool and runs its mount callbacks.
local function mountLayer()
  local recipeHooks, recipeIndex = hooks, hookIndex
  hooks, hookIndex, mounts = {}, 0, {}
  actionFn()
  for _, fn in ipairs(mounts) do fn() end
  hooks, hookIndex = recipeHooks, recipeIndex
end
local function state(action) return registered[action].enabled() end

local MOUSE_ACTIONS = "IA_NAV_ACTIVATE, IA_TEXT_ACCEPT, IA_UNDERGOUND_MODE_TOGGLE, constructOpt1, constructOpt2"
local PAD_ACTIONS = "IA_APPLY, IA_NAV_ACTIVATE, IA_OPTION2, IA_SELECT, IA_TEXT_ACCEPT, IA_UNDERGOUND_MODE_TOGGLE, constructOpt1, constructOpt2"

-- Mouse and keyboard
fresh("mouse")
local names, result = render(false)
check("mouse: an entry that is not active registers no input action", names == "", names)
names, result = render(true)
check("mouse: an active entry registers the radius, underground and Enter actions only", names == MOUSE_ACTIONS, names)
check("mouse: the recipe returns no focus target", result == nil)
events["constructionMenuChangeFocusMode"]("constructionMenuChangeFocusMode", "BottomBar")
check("mouse: the radius and underground keys carry no enabled check, so the focus of the menu cannot disable them",
  registered["constructOpt1"].enabled == nil and registered["constructOpt2"].enabled == nil and registered["IA_UNDERGOUND_MODE_TOGGLE"].enabled == nil)
mountLayer()
names, result = render(true)
check("mouse: a mounted world layer adds no focus target", result == nil)

-- Controller
fresh("pad")
names, result = render(false)
check("controller: an entry that is not active registers no input action", names == "", names)
check("controller: an entry that is not active returns no focus target", result == nil)
names, result = render(true)
check("controller: an active entry also registers Cross and Triangle", names == PAD_ACTIONS, names)
check("controller: no focus target before the world layer is mounted", result == nil)
mountLayer()
names, result = render(true)
check("controller: the focus target is returned once the world layer is mounted", result ~= nil)
registered["IA_OPTION2"].fn()
check("controller: Triangle asks the menu to move the focus to the toolbar",
  #fired == 1 and fired[1] == "constructionMenuToggleBottomBarFocus", table.concat(fired, ", "))
check("controller: the tool has the buttons while it has the focus",
  state("IA_APPLY") == "Enabled" and state("IA_OPTION2") == "Enabled" and state("constructOpt1") == "Enabled")
events["constructionMenuChangeFocusMode"]("constructionMenuChangeFocusMode", "BottomBar")
check("controller: the tool gives up its buttons while the toolbar has the focus",
  state("IA_APPLY") == "Disabled" and state("IA_SELECT") == "Disabled" and state("IA_OPTION2") == "Disabled"
  and state("constructOpt1") == "Disabled" and state("constructOpt2") == "Disabled"
  and state("IA_UNDERGOUND_MODE_TOGGLE") == "Disabled")
events["constructionMenuChangeFocusMode"]("constructionMenuChangeFocusMode", "Action")
check("controller: the tool takes its buttons back with the focus", state("IA_APPLY") == "Enabled" and state("constructOpt1") == "Enabled")

support.finish("tool_input")
