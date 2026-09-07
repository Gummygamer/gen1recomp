-- Runtime wrapper for environments that have LÖVE's embedded LuaJIT but no
-- standalone luajit executable.
-- POKEPORT_DRIVER=tests/drivers/nim_npc_mod_test.lua lovec .
return function(game)
  _G.POKEPORT_TEST_CHILD = true
  _G.NIM_NPC_TEST_GAME = game
  local ok, err = pcall(dofile,
    "mods/nim_npc_chat/tests/nim_npc_chat_test.lua")
  _G.NIM_NPC_TEST_GAME = nil
  _G.POKEPORT_TEST_CHILD = nil
  if not ok then error(err, 0) end
  print("nim_npc_chat LÖVE runtime test passed")
  if os.getenv("NIM_NPC_LIVE_TEST") == "1" then
    local Client = require("mods.nim_npc_chat.nim_client")
    local request = Client.buildRequest({
      mapId = "PALLET_TOWN",
      vanillaText = "Technology is incredible!",
    }, "Say a friendly hello to RED.", {})
    local channelName = "nim_live_test_result"
    local channel = love.thread.getChannel(channelName)
    channel:clear()
    local thread = love.thread.newThread("mods/nim_npc_chat/nim_worker.lua")
    thread:start(channelName, request, "nim_live_test")
    local envelope = channel:demand(90)
    local body, requestErr = Client.decodeEnvelope(envelope)
    if not body then error("NIM live request failed: " .. tostring(requestErr), 0) end
    local reply, parseErr = Client.parseCompletion(body)
    if not reply then error("NIM live response failed: " .. tostring(parseErr), 0) end
    print("NIM live response received (" .. tostring(#reply) .. " characters)")
  end
end
