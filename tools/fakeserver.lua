-- A stand-in for the game half of the transport, for testing a bridge without Avorion.
--
-- It runs the REAL data/scripts/galaxy/automationapi/bridge.lua against a directory of
-- your choosing, on a real-time clock, under tests/mock_avorion.lua. Everything the HTTP
-- bridge touches - the directory layout, the request filter, the response envelope, the
-- delete-on-pickup behaviour - is therefore the actual mod code rather than a fake of it.
--
-- What it cannot tell you about is Avorion's io.open sandbox: plain Lua opens any path it
-- is given. Use it to test the bridge, the mounts and the permissions, not path security.
--
--   MOCK_ROOT=/tmp/galaxy lua tools/fakeserver.lua
--
-- It prints an API key on startup. Ctrl-C to stop.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local Mock = require("mock_avorion")
Mock.install()
Mock.reset()

local Config = require("automationapi.config")
local Auth = require("automationapi.auth")

dofile("data/scripts/galaxy/automationapi/bridge.lua")
local Bridge = AutomationApiBridge

Mock.addPlayer(1, os.getenv("MOCK_PLAYER") or "TestPilot")
Bridge.initialize()

local key = Auth.createKey(1, "fakeserver")

print("fakeserver: transport directory: " .. Config.getRoot())
print("fakeserver: API key: " .. key)
print("fakeserver: polling, Ctrl-C to stop")
io.stdout:flush()

-- The bridge reads its clock from Server().unpausedRuntime, which the mock holds still.
-- Advance it by the same amount we actually sleep, so timeouts and the response TTL
-- expire in real time rather than never.
local step = Config.pollInterval

while true do
    os.execute("sleep " .. step)
    Mock.advanceClock(step)

    local ok, err = pcall(Bridge.update, step)
    if not ok then
        print("fakeserver: update failed: " .. tostring(err))
        io.stdout:flush()
    end
end
