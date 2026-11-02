-- Shared helpers of the tests: loading the Lua that `tl gen` made from the mod's Teal files, and a small check function.
-- The tests run outside the game with a stub of the game's `api`. They prove the logic of the mod, not that the game
-- accepts a call.

local support = {}

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
support.buildDir = here .. "/.build"

local loaded = {}

-- Installs the global `ug_require` of the game. `stubs` maps a file name without extension (for example "bb_gather")
-- to a table that stands in for that module. Any other module loads from the build folder.
function support.installRequire(stubs)
  loaded = {}
  _G.ug_require = function(path)
    local name = path:match("([%w_%.]+)%.tl$")
    assert(name, "unknown module path " .. tostring(path))
    if stubs and stubs[name] then return stubs[name] end
    if not loaded[name] then
      local chunk = assert(loadfile(support.buildDir .. "/" .. name .. ".lua"))
      loaded[name] = chunk()
    end
    return loaded[name]
  end
end

local failures = 0
local count = 0

function support.check(name, condition, detail)
  count = count + 1
  if condition then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or ""))
  end
end

function support.contains(text, part)
  return type(text) == "string" and text:find(part, 1, true) ~= nil
end

-- Prints the result and ends the process with the matching exit code.
function support.finish(title)
  print(string.format("%s: %d checks, %d failed", title, count, failures))
  os.exit(failures == 0 and 0 or 1)
end

return support
