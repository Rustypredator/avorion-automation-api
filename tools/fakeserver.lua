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

-- A fleet, so /ships answers with something. The bridge's history store is fed by that
-- answer, and a player with an empty fleet exercises none of it.
--
-- One craft is fully kitted out - captain, crew, cargo, turrets, subsystems, fighters -
-- because the console's detail tabs are all conditional on those being present, and an
-- empty fleet renders every one of them as an empty state that proves nothing.
local crew = {}
function crew:getMaxSize() return 220 end
function crew:getNumMembers() return 180 end
function crew:getWorkForce() return {[{value = 0}] = 3.5} end
function crew:getNumMembersByProfession()
    return {[{value = 0}] = 8, [{value = 5}] = 120, [{value = 3}] = 52}
end

local function good(name, price, size, flags)
    local g = {name = name, plural = name, price = price, size = size}
    for key, value in pairs(flags or {}) do g[key] = value end
    return g
end

Mock.addShip(1, "Ore Hound",
{
    x = 5, y = 5, statusText = "Idle",
    captain = {name = "Vex", nickName = "The Patient", displayName = "Vex the Patient",
               level = 12, tier = 2, experience = 5400, experiencePercentage = 0.62,
               salary = 2400, primaryClass = 4, secondaryClass = 6,
               getPerks = function() return 1, 5, 9 end},
    crew = crew, crewOk = true,
    cargo =
    {
        [good("Iron Ore", 10, 1)] = 2400,
        [good("Titanium Ore", 24, 1)] = 860,
        [good("Scrap Metal", 6, 2)] = 410,
        [good("Military Rations", 90, 1, {illegal = true})] = 60,
        [good("Explosive Charge", 320, 3, {dangerous = true})] = 18,
        [good("Stolen Goods", 140, 1, {stolen = true, suspicious = true})] = 7,
    },
    cargoCapacity = 6000, cargoFree = 1100,
    range = 9.5, canPassRifts = false, cooldown = 14,
    shields = 42000, shieldPct = 0.72, hp = 138000, hpPct = 0.91,
    -- Deliberately short, so the new energy bar has an over-budget case to draw.
    energyRequired = 5200, energyProduced = 4100,
    usableError = 5,
    turretDps = 4200, fighterDps = 1600,
    turrets =
    {
        [{weaponName = "R-Mining Laser", category = WeaponCategory.Mining,
          rarity = {name = "Exotic"}, material = {name = "Xanion"}, armed = false,
          dps = 0, reach = 1.4, slots = 1,
          stoneRawEfficiency = 0, stoneRefinedEfficiency = 0.42,
          metalRawEfficiency = 0, metalRefinedEfficiency = 0.61}] = 4,
        [{weaponName = "Railgun", category = WeaponCategory.Armed,
          rarity = {name = "Rare"}, material = {name = "Trinium"}, armed = true,
          dps = 1050, reach = 2.1, slots = 2}] = 4,
    },
    systems =
    {
        [{script = "data/scripts/systems/miningsystem.lua", name = "Mining System",
          rarity = {name = "Exotic"}}] = 1,
        [{script = "data/scripts/systems/cargoextension.lua", name = "Cargo Extension",
          rarity = {name = "Rare"}}] = 2,
    },
    hangar =
    {
        {name = "Alpha", getFighters = function() return 1, 2, 3, 4 end},
        {name = "Bravo", getFighters = function() return 1, 2 end},
    },
    blocks = 4820, planValue = 12500000, reconstructionValue = 940000, icon = "mining",
})

Mock.addShip(1, "Tug", {x = -3, y = 12, statusText = "Idle"})

-- A station with books, so /stations and /economy answer with something and the bridge's
-- economy series has samples to difference. The secured values below are the shape the
-- game writes into a craft's database row: one table per script index, with factory.lua
-- nesting its trading data under `tradingData`.
local refinery = Mock.addShip(1, "Home Base",
{
    type = EntityType.Station, x = 0, y = 0, usableError = 2,
    -- Read off the plan for the line's cycle time; see rateOf() in economy.lua.
    productionCapacity = 250,
    cargoCapacity = 12000, cargoFree = 5000,
    cargo =
    {
        [good("Oil", 320, 2)] = 900,
        [good("Raw Oil", 66, 2)] = 400,
        [good("Energy Cell", 61, 1)] = 1200,
    },
    scripts = {[1] = "data/scripts/entity/merchants/factory.lua"},
    secured =
    {
        [1] =
        {
            maxNumProductions = 3,
            shuttleVolume = 20,
            production =
            {
                factory = "${good} Refinery ${size}",
                factoryStyle = "Factory",
                ingredients = {{name = "Energy Cell", amount = 5, optional = 0},
                               {name = "Raw Oil", amount = 10, optional = 0}},
                results = {{name = "Oil", amount = 5}},
                garbages = {},
            },
            currentProductions = {[1] = {progress = 0.25}},
            tradingData =
            {
                buyPriceFactor = 0.9, sellPriceFactor = 1.1,
                buyFromOthers = true, sellToOthers = true,
                activelyRequest = false, activelySell = true,
                policies = {},
                stats = {moneyGainedFromGoods = 4000000, moneySpentOnGoods = 1500000,
                         moneyGainedFromTax = 25000},
                boughtGoods = {good("Energy Cell", 61, 1), good("Raw Oil", 66, 2)},
                soldGoods = {good("Oil", 320, 2)},
            },
        },
    },
})

Mock.player(1).money = 12500000
Mock.player(1).resources = {[0] = 40000, [1] = 9000}

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

-- One craft wanders, so anything watching movement - the bridge's history store, the
-- console's tracks and heatmap - has something other than a parked fleet to show. A fleet
-- that never moves exercises the dedupe path and nothing else.
local WANDER_EVERY = tonumber(os.getenv("MOCK_WANDER") or "4")
local wanderer = Mock.getShip(1, "Tug")
local sinceWander = 0

math.randomseed(os.time())

local function wander()
    if not wanderer then return end

    wanderer.x = wanderer.x + math.random(-2, 2)
    wanderer.y = wanderer.y + math.random(-2, 2)
    wanderer.statusText = string.format("Flying to (%d:%d)", wanderer.x, wanderer.y)

    Bridge.pushShipEvent(1, "Tug", "status", {text = wanderer.statusText})
end

-- And the refinery trades, so two economy samples are never identical. The counters only
-- ever rise while a station stands, which is what the game does and what the bridge's
-- differencing assumes; stock moves both ways.
local trading = refinery.secured[1].tradingData.stats

local function trade()
    local sold = math.random(20, 60)

    trading.moneyGainedFromGoods = trading.moneyGainedFromGoods + sold * 352
    trading.moneySpentOnGoods = trading.moneySpentOnGoods + sold * 2 * 55
    trading.moneyGainedFromTax = trading.moneyGainedFromTax + sold

    for goodTable, amount in pairs(refinery.cargo) do
        if goodTable.name == "Oil" then
            refinery.cargo[goodTable] = math.max(0, amount - sold + math.random(0, 70))
        elseif goodTable.name == "Raw Oil" then
            refinery.cargo[goodTable] = math.max(0, amount - sold)
        end
    end

    Mock.player(1).money = Mock.player(1).money + sold * 352

    -- What the station hooks would have pushed from inside the refinery for the same trade,
    -- so the stations' activity feed and the bridge's collector of it have something to move.
    Bridge.pushStationEvent(1, "Home Base", "trade",
    {
        direction = "sold", channel = "docked", good = "Oil", units = sold,
        price = sold * 352, ownerAmount = sold * 352, tax = sold, internal = false,
        counterparty = {index = 900, name = "The Xsotan Traders", kind = "ai"},
        ship = "Oil Barge", x = 0, y = 0,
    })

    Bridge.pushStationEvent(1, "Home Base", "production",
    {
        seconds = WANDER_EVERY, slotSeconds = 3 * WANDER_EVERY,
        busySlotSeconds = 2 * WANDER_EVERY, starvedSeconds = WANDER_EVERY,
        blockedSeconds = 0, idleSeconds = 0, cycles = 1, boosted = 0, slots = 3,
        cycleSeconds = 30, x = 0, y = 0,
        results = {{name = "Oil", amount = 5}},
        ingredients = {{name = "Energy Cell", amount = 5}, {name = "Raw Oil", amount = 10}},
        garbage = {},
    })
end

while true do
    os.execute("sleep " .. step)
    Mock.advanceClock(step)

    if WANDER_EVERY > 0 then
        sinceWander = sinceWander + step
        if sinceWander >= WANDER_EVERY then
            sinceWander = 0
            pcall(wander)
            pcall(trade)
        end
    end

    local ok, err = pcall(Bridge.update, step)
    if not ok then
        print("fakeserver: update failed: " .. tostring(err))
        io.stdout:flush()
    end
end
