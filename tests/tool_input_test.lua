-- Tests of the input actions that the tool recipe of brush_upgrade.script.tl registers on its menu entry.
-- The recipe component sits inside the entry of the construction menu. In gamepad mode the menu renders it with
-- isActive = false until the player activates the entry. constructOpt1 and constructOpt2 share the buttons dpright and
-- dpleft with IA_NAV_RIGHT and IA_NAV_LEFT, so a registration on an inactive entry takes the menu navigation.
-- Every module and the game are stand-ins: the test proves which actions the recipe registers, not what the game does
-- with them.

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

local recipes = {}
local registered = {}
local noop = function() end
local function holder(value)
  local h = {}
  function h:old() return value end
  function h:get() return value end
  function h:set(v) value = v end
  return h
end
local react = {
  RegisterRecipe = function(name, fn) recipes[name] = fn; return fn end,
  useState = holder,
  useRef = holder,
  onStep = noop, onMount = noop, onUnmount = noop, onEvent = noop,
  setForceFocusable = noop, setRestrictMouseFocus = noop,
  iaHandler = function(fn) return fn end,
  useInputAction = function(action) registered[#registered + 1] = action end,
}
local perf = { on = false }
function perf:start() return 0 end
function perf:stop() end
function perf:phase() end
function perf:wrap(_name, fn) return fn end

_G.api = any
_G.log = any
_G._ = function(text) return text end
_G.ug_require = function(path)
  if path:find("/gui/main/react.lua", 1, true) then return react end
  if path:find("/sqperf/", 1, true) then return { new = function() return perf end } end
  return any
end

assert(loadfile(support.buildDir .. "/brush_upgrade.script.lua"))()
local recipe = assert(recipes["BrushUpgradeAction"], "the tool recipe is not registered")

local function render(isActive)
  registered = {}
  recipe({ isActive = isActive, setActionFn = noop, abort = noop, getCurrentParams = function() return {} end, gameCtx = any })
  table.sort(registered)
  return table.concat(registered, ", ")
end

check("an entry that is not active registers no input action", render(false) == "", render(false))
check("an active entry registers the radius, underground and Enter actions",
  render(true) == "IA_NAV_ACTIVATE, IA_TEXT_ACCEPT, IA_UNDERGOUND_MODE_TOGGLE, constructOpt1, constructOpt2", render(true))

support.finish("tool_input")
