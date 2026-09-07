-- Run a plain-Lua suite through LÖVE's embedded LuaJIT when a standalone
-- luajit executable is unavailable.
--
--   POKEPORT_LUA_TEST=tests/engine/audio_device_lost_test.lua lovec .
--
-- Suites in tests/engine stub out the engine globals they exercise, which
-- includes replacing `love` itself (see tests/love_stub.lua).  So the real
-- module is captured before the suite runs and put back afterwards: without
-- that, love.event is gone by the time this file reports the result and the
-- run dies on "attempt to index field 'event'" no matter how the suite went.
local realLove = love
local root = realLove.filesystem.getWorkingDirectory()
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

function love.load()
  local target = os.getenv("POKEPORT_LUA_TEST")
  if not target or target == "" then
    print("POKEPORT_LUA_TEST is required")
    realLove.event.quit(2)
    return
  end
  _G.POKEPORT_TEST_CHILD = true
  local path = target:match("^%a:[/\\]") and target or (root .. "/" .. target)
  local ok, err = xpcall(function() dofile(path) end, debug.traceback)
  _G.POKEPORT_TEST_CHILD = nil
  _G.love = realLove
  if not ok then print(err) end
  realLove.event.quit(ok and 0 or 1)
end
