-- Live end-to-end check for the Fakemon metadata request. Run with
--   POKEPORT_DRIVER=tests/drivers/nvidia_fakemon_live_test.lua
--   NVIDIA_FAKEMON_LIVE_TEST=1 lovec .
-- It drives the same worker thread the mod uses in game, so the configured
-- model, request shape, worker envelope, image pipeline, and definition
-- validation are all exercised rather than asserted from a canned response.
-- No sprite files are written and no save state is touched.
--
-- The plain-Lua suite under mods/nvidia_fakemon/tests is deliberately not
-- loaded here: it requires src.mods.Runtime, which would register the status
-- list a second time inside an already-running engine. Run that suite with
-- tools/love-luajit.cmd instead.
local function artIsValid(definition)
  local Generator = require("mods.nvidia_fakemon.sprite_generator")
  if definition.artSource == "cloudflare-image"
      or definition.artSource == "nim-image" then
    return Generator.validImageRows(definition.front,
        tonumber(definition.frontWidth) or 0,
        tonumber(definition.frontHeight) or 0)
      and Generator.validImageRows(definition.back,
        tonumber(definition.backWidth) or 0,
        tonumber(definition.backHeight) or 0)
  end
  return Generator.validRows(definition.front, 28, 28)
    and Generator.validRows(definition.back, 16, 16)
end

local function checkDefinition(definition, result)
  local Learnset = require("mods.nvidia_fakemon.learnset")
  if type(definition.name) ~= "string" or definition.name == ""
      or #definition.name > 10 then
    error("generated name failed validation: " .. tostring(definition.name), 0)
  end
  if definition.name:find("[^A-Z]") then
    error("generated name is not uppercase ASCII: " .. definition.name, 0)
  end
  local learnset = definition.learnset
  if type(learnset) ~= "table" or #learnset < 7 or #learnset > 10 then
    error("learnset length out of range: "
      .. tostring(learnset and #learnset or "nil"), 0)
  end
  local previous = 0
  for _, entry in ipairs(learnset) do
    if type(entry.level) ~= "number" or entry.level <= previous then
      error("learnset levels are not strictly increasing at "
        .. tostring(entry.level), 0)
    end
    if not Learnset.validMoves[entry.move] then
      error("learnset contains an invalid move: " .. tostring(entry.move), 0)
    end
    previous = entry.level
  end
  if type(definition.level1Moves) ~= "table"
      or #definition.level1Moves < 1 or #definition.level1Moves > 4 then
    error("level-1 moves out of range", 0)
  end
  for _, move in ipairs(definition.level1Moves) do
    if not Learnset.validMoves[move] then
      error("level-1 move is invalid: " .. tostring(move), 0)
    end
  end
  local stats = definition.baseStats
  local total = 0
  for _, key in ipairs({ "hp", "attack", "defense", "speed", "special" }) do
    local value = stats and stats[key]
    if type(value) ~= "number" or value < 15 or value > 155 then
      error("base stat out of Gen 1 range: " .. key .. "=" .. tostring(value), 0)
    end
    total = total + value
  end
  if total < 250 or total > 600 then
    error("base stat total out of range: " .. total, 0)
  end
  if not artIsValid(definition) then
    error("sprite rows do not match the recorded art format ("
      .. tostring(definition.artSource) .. ")", 0)
  end
  print(("validated: name=%s kind=%s types=%s art=%s stats_total=%d learnset=%d")
    :format(definition.name, tostring(definition.kind),
      table.concat(definition.types or {}, "/"), tostring(definition.artSource),
      total, #learnset))
  if result.warning then print("warning: " .. tostring(result.warning)) end
end

local function describe(definition)
  print(("level 1 moves: %s"):format(
    table.concat(definition.level1Moves or {}, ", ")))
  for _, entry in ipairs(definition.learnset or {}) do
    print(("  learn at %2d: %s"):format(entry.level, entry.move))
  end
  print(("description: %s"):format(tostring(definition.description)))
end

return function(game)
  if os.getenv("NVIDIA_FAKEMON_LIVE_TEST") ~= "1" then
    print("SKIP live Fakemon generation (set NVIDIA_FAKEMON_LIVE_TEST=1)")
    return
  end

  local Json = require("src.link.Json")
  local Client = require("mods.nvidia_fakemon.fakemon_client")
  Client.cleanupStagedFiles()

  print("live metadata model: " .. tostring(Client.model()))
  print("live endpoint: " .. tostring((Client.endpoint())))
  local key = os.getenv("NVIDIA_API_KEY")
  if type(key) ~= "string" or key == "" then
    error("NVIDIA_API_KEY is not set in this process", 0)
  end

  local channelName = "nvidia_fakemon_live_test_result"
  local channel = love.thread.getChannel(channelName)
  channel:clear()

  -- Variant 2 of the map that failed in the reported log, with the name that
  -- save already holds excluded so a collision cannot mask a real success.
  local context = {
    mapId = "VIRIDIAN_FOREST", tileset = "FOREST", variant = 2,
    forbiddenNames = { "PIKACHU", "FOLIASECT", "BUTTERFREE", "WEEDLE" },
  }
  local request = Client.buildRequest(context)
  local thread = love.thread.newThread("mods/nvidia_fakemon/fakemon_worker.lua")
  -- Metadata has a 90s budget and the optional Cloudflare image step another
  -- 180s, so wait long enough for both plus thread startup.
  thread:start(channelName, request, Json.encode(context),
    "nvidia_fakemon_live_test")
  local envelope = channel:demand(320)
  local result, requestErr = Client.decodeEnvelope(envelope)
  if not result then
    error("live Fakemon request failed: " .. tostring(requestErr), 0)
  end
  local definition = result.definition
  if type(definition) ~= "table" then error("worker returned no definition", 0) end

  describe(definition)
  checkDefinition(definition, result)
  print("PASS live Fakemon generation through the real worker thread")
end
