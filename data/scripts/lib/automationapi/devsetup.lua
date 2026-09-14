-- Development helper: conjures a ready-to-fly test ship.
--
-- NOT loaded by the mod. It exists because testing captain missions otherwise means
-- playing for hours first: a mission needs a ship with a captain, a fit crew, cargo space
-- and mining turrets, and a fresh character starts in a drone.
--
-- Run it from the server console (or commands.txt):
--
--   /run include("automationapi/devsetup").spawn(1, "Ore Hound")
--
-- The player must be logged in and in a loaded sector.

package.path = package.path .. ";data/scripts/lib/?.lua"

local DevSetup = {}

-- Runs inside the player's sector, which is where entities can actually be created.
local SPAWN_CODE = [[
package.path = package.path .. ";data/scripts/lib/?.lua"

local ShipGenerator = include("shipgenerator")
local ShipUtility = include("shiputility")
local SectorGenerator = include("SectorGenerator")
local SectorTurretGenerator = include("sectorturretgenerator")
local CaptainGenerator = include("captaingenerator")
local CaptainUtility = include("captainutility")

function run(playerIndex, shipName, captainClass, volume, miningTurrets)
    local player = Player(playerIndex)
    if not player then eprint("devsetup: no player %s", tostring(playerIndex)) return end

    local x, y = Sector():getCoordinates()
    local generator = SectorGenerator(x, y)

    local ship = ShipGenerator.createShip(player, generator:getPositionInSector(), volume or 3000)
    ship.name = shipName
    ship.shieldDurability = ship.shieldMaxDurability

    -- Mining turrets, so a Mine mission has something to work with. Generated outright:
    -- ShipUtility.addUnarmedTurretsToCraft draws from the faction inventory, which is
    -- empty for a fresh character, and returns silently when it finds nothing.
    --
    -- Keep the count modest. Mine validation rejects a ship whose turrets exceed its
    -- turret slots with "Not enough turret slots for all turrets!".
    local turretGenerator = SectorTurretGenerator()
    local miner = turretGenerator:generate(x, y, 0, Rarity(RarityType.Rare),
                                           WeaponType.MiningLaser, Material(MaterialType.Iron))
    ShipUtility.addTurretsToCraft(ship, miner, miningTurrets or 2)

    -- Entity has no getCrew(); crew is a property, and reading it yields a copy, so the
    -- captain has to be set on that copy and the whole crew assigned back.
    local generatorForCaptain = CaptainGenerator()
    local captain = generatorForCaptain:generate(3, 3, captainClass or CaptainUtility.ClassType.Miner)

    local crew = ship.idealCrew
    crew:setCaptain(captain)
    ship.crew = crew

    print("devsetup: created " .. shipName .. " for " .. player.name
          .. " (" .. tostring(ship.numTurrets) .. " turrets, slots ok: "
          .. tostring(ship:getFreeArmedTurrets() ~= nil) .. ")")
end
]]

function DevSetup.spawn(playerIndex, shipName, captainClass, volume, miningTurrets)
    local player = Player(playerIndex)
    if not player then
        print("devsetup: player " .. tostring(playerIndex) .. " is not logged in")
        return
    end

    local x, y = player:getSectorCoordinates()

    if not Galaxy():sectorLoaded(x, y) then
        print("devsetup: sector " .. x .. ":" .. y .. " is not loaded")
        return
    end

    runSectorCode(x, y, true, SPAWN_CODE, "run", playerIndex, shipName or "Test Ship",
                  captainClass, volume, miningTurrets)

    print("devsetup: queued spawn of '" .. tostring(shipName) .. "' in " .. x .. ":" .. y)
end

-- Fits turrets to an existing ship. Needs the ship's sector in memory, so call
-- DevSetup.load first and give it a few seconds.
-- ShipUtility.addUnarmedTurretsToCraft/addArmedTurretsToCraft draw from the faction's
-- inventory and silently do nothing when it is empty, which it is for a fresh character.
-- Turrets are generated outright instead.
local REFIT_CODE = [[
package.path = package.path .. ";data/scripts/lib/?.lua"

local ShipUtility = include("shiputility")
local SectorTurretGenerator = include("sectorturretgenerator")
local CaptainGenerator = include("captaingenerator")
local CaptainUtility = include("captainutility")

function run(factionIndex, shipName, mining, armed, captainClass)
    local ship = Sector():getEntityByFactionAndName(factionIndex, shipName)
    if not ship then eprint("devsetup: %s is not in this sector", shipName) return end

    local x, y = Sector():getCoordinates()
    local generator = SectorTurretGenerator()

    -- addTurretsToCraft always places at least one, so zero means "leave alone"
    if (mining or 0) > 0 then
        local miner = generator:generate(x, y, 0, Rarity(RarityType.Rare),
                                         WeaponType.MiningLaser, Material(MaterialType.Iron))
        ShipUtility.addTurretsToCraft(ship, miner, mining)
    end

    if (armed or 0) > 0 then
        local gun = generator:generate(x, y, 0, Rarity(RarityType.Uncommon),
                                       WeaponType.ChainGun, Material(MaterialType.Iron))
        ShipUtility.addTurretsToCraft(ship, gun, armed)
    end

    -- More turrets means more required crew, so top up to ideal. The captain rides on
    -- the crew object, and reading ship.crew yields a copy, so it has to be carried
    -- across explicitly or it is dropped by the assignment.
    local captain = ship.crew:getCaptain()
    if not captain then
        captain = CaptainGenerator():generate(3, 3, captainClass or CaptainUtility.ClassType.Miner)
    end

    local crew = ship.idealCrew
    crew:setCaptain(captain)
    ship.crew = crew

    print("devsetup: refitted " .. shipName .. ", now " .. tostring(ship.numTurrets) .. " turrets")
end
]]

-- Brings a ship's sector into memory so it can be modified. Asynchronous: give it a
-- few seconds before calling refit.
function DevSetup.load(playerIndex, shipName)
    local entry = ShipDatabaseEntry(playerIndex, shipName)
    if not entry or not entry:exists() then
        print("devsetup: no ship '" .. tostring(shipName) .. "'")
        return
    end

    local x, y = entry:getCoordinates()
    Galaxy():loadSector(x, y)

    print("devsetup: loading sector " .. x .. ":" .. y)
end

function DevSetup.refit(playerIndex, shipName, mining, armed, captainClass)
    local entry = ShipDatabaseEntry(playerIndex, shipName)
    if not entry or not entry:exists() then
        print("devsetup: no ship '" .. tostring(shipName) .. "'")
        return
    end

    local x, y = entry:getCoordinates()

    if not Galaxy():sectorLoaded(x, y) then
        print("devsetup: sector " .. x .. ":" .. y .. " not loaded; call DevSetup.load first")
        return
    end

    runSectorCode(x, y, true, REFIT_CODE, "run", playerIndex, shipName, mining, armed, captainClass)

    print("devsetup: queued refit of " .. shipName)
end

-- Gives an existing ship a captain, for a craft built the normal way.
function DevSetup.giveCaptain(playerIndex, shipName, captainClass)
    local CaptainGenerator = include("captaingenerator")
    local CaptainUtility = include("captainutility")

    local entry = ShipDatabaseEntry(playerIndex, shipName)
    if not entry or not entry:exists() then
        print("devsetup: no ship '" .. tostring(shipName) .. "'")
        return
    end

    local generator = CaptainGenerator()
    local captain = generator:generate(3, 3, captainClass or CaptainUtility.ClassType.Miner)
    entry:setCaptain(captain)

    print("devsetup: gave " .. shipName .. " captain " .. tostring(captain.name))
end

-- #### BOSS LAB #### --

-- Boss farming waits on ten jumps and a 4% roll, which makes the farm's in-sector half -
-- recognising the boss, reading the loot, ordering fighters - slow to try out for real.
-- These put a boss and a drop of every kind next to a carrier on demand, and print what the
-- engine answers to exactly the calls entity/orderchain.lua makes.
--
--   /run include("automationapi/devsetup").spawnBoss(1, "swoks")     -- beside the player
--
-- Or, with nobody logged in, in a sector of its own (each step a few seconds apart):
--
--   /run include("automationapi/devsetup").bossLab(1, 380, 0, "load")
--   /run include("automationapi/devsetup").bossLab(1, 380, 0, "setup")   -- carrier + Swoks
--   /run include("automationapi/devsetup").bossLab(1, 380, 0, "report")  -- what a farm sees
--   /run include("automationapi/devsetup").bossLab(1, 380, 0, "kill")    -- boss dies, drops
--   /run include("automationapi/devsetup").bossLab(1, 380, 0, "loot")    -- squads collect
--   /run include("automationapi/devsetup").bossLab(1, 380, 0, "recall")
--   /run include("automationapi/devsetup").bossLab(1, 380, 0, "plan", "farm")  -- orderchain
--   /run include("automationapi/devsetup").bossLab(1, 380, 0, "state")
--   /run include("automationapi/devsetup").bossLab(1, 380, 0, "clear")
--   /run include("automationapi/devsetup").bossLab(1, 380, 0, "forget")  -- after clear

local BOSS_CODE = [[
package.path = package.path .. ";data/scripts/lib/?.lua"

function run(playerIndex, boss)
    local x, y = Sector():getCoordinates()

    if boss == "ai" then
        include("story/ai").spawn(x, y)
    else
        include("story/swoks").spawn(Player(playerIndex), x, y)
    end

    print("bosslab: spawned " .. tostring(boss) .. " in " .. x .. ":" .. y)
end
]]

function DevSetup.spawnBoss(playerIndex, boss)
    local player = Player(playerIndex)
    if not player then
        print("devsetup: player " .. tostring(playerIndex) .. " is not logged in")
        return
    end

    -- An offline player still has a Player object here, in a sector nothing keeps loaded,
    -- and runSectorCode into an unloaded sector does nothing at all.
    local x, y = player:getSectorCoordinates()
    if not Galaxy():sectorLoaded(x, y) then
        print("devsetup: " .. player.name .. "'s sector " .. x .. ":" .. y
              .. " is not loaded - is the player logged in?")
        return
    end

    runSectorCode(x, y, true, BOSS_CODE, "run", playerIndex, boss or "swoks")
    print("devsetup: queued " .. tostring(boss or "swoks") .. " for " .. x .. ":" .. y)
end

local LAB_CARRIER = "Boss Lab Carrier"

local LAB_CODE = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
include("goods")

local CaptainGenerator = include("captaingenerator")

local CARRIER = "]] .. LAB_CARRIER .. [["

local LOOT_COMPONENTS = {"CargoLoot", "MoneyLoot", "ResourceLoot", "TurretLoot",
                         "SystemUpgradeLoot", "CrewLoot", "InventoryItemLoot"}

local function say(format, ...) print("bosslab: " .. string.format(format, ...)) end

-- Found by a value rather than its name: the ship database keeps a deleted craft's name
-- taken, so a second carrier comes out as "Boss Lab Carrier 2".
local function carrier(playerIndex)
    for _, ship in ipairs({Sector():getEntitiesByScriptValue("bosslab_carrier", true)}) do
        if ship.factionIndex == playerIndex then return ship end
    end
end

local function titleOf(entity)
    local title = entity.title or ""
    local args = entity:getTitleArguments() or {}
    return (string.gsub(title, "%${([%w_]+)}", function(key)
        return args[key] ~= nil and tostring(args[key]) or nil
    end))
end

local steps = {}

function steps.setup(playerIndex, kind)
    local faction = Faction(playerIndex)
    local ship = carrier(playerIndex)

    if not ship then
        -- Not ShipGenerator.createCarrier: that sizes the plan to the sector's balancing
        -- volume, which out here leaves no hangar space at all.
        local plan = include("plangenerator").makeCarrierPlan(faction, 40000)

        -- And even at that size the player's carrier style can come out without a hangar.
        -- A hangar and crew quarters for the pilots are bolted on above the hull, the way
        -- shipyard.lua builds plans. Ugly, and exactly enough for fighters to launch.
        local top = 50
        pcall(function() top = plan:getBoundingBox().upper.y + 10 end)
        local material = Material(MaterialType.Titanium)
        local grey = ColorRGB(0.5, 0.5, 0.5)
        plan:addBlock(vec3(0, top, 0), vec3(20, 10, 20), plan.rootIndex, -1, grey, material,
                      Matrix(), BlockType.Hangar, ColorNone())
        plan:addBlock(vec3(0, top + 10, 0), vec3(20, 10, 20), plan.rootIndex, -1, grey, material,
                      Matrix(), BlockType.Quarters, ColorNone())
        -- somewhere for cargo drops to go
        plan:addBlock(vec3(0, top + 20, 0), vec3(20, 10, 20), plan.rootIndex, -1, grey, material,
                      Matrix(), BlockType.CargoBay, ColorNone())
        if kind == "transporter" then
            plan:addBlock(vec3(0, top + 30, 0), vec3(5, 5, 5), plan.rootIndex, -1, grey, material,
                          Matrix(), BlockType.Transporter, ColorNone())
        end

        ship = Sector():createShip(faction, CARRIER, plan, Matrix())
        ship.shieldDurability = ship.shieldMaxDurability
        ship:setValue("bosslab_carrier", true)
    end

    -- crew last: fighters want pilots, and a captain is what lets it take orders unpiloted
    local crew = ship.idealCrew
    crew:setCaptain(CaptainGenerator():generate(3, 3))
    ship.crew = crew

    local x, y = Sector():getCoordinates()
    include("story/swoks").spawn(Player(playerIndex), x, y)

    say("carrier %s, Swoks spawned - run the fighters step next", ship.name)
end

-- A frame after setup: a freshly created craft's hangar may not have its space yet.
function steps.fighters(playerIndex)
    local ship = carrier(playerIndex)
    if not ship then say("no carrier, run setup") return end

    local hangar = Hangar(ship)
    say("hangar before: space %s, free %s, squads %s of %s (supported %s)",
        tostring(hangar.space), tostring(hangar.freeSpace), tostring(hangar.numSquads),
        tostring(hangar.maxSquads), tostring(hangar.numSupportedSquads))

    while hangar.numSquads < math.min(3, hangar.maxSquads) do
        hangar:addSquad("Lab " .. hangar.numSquads)
    end

    -- The vanilla generator draws fighters for the faction's home sector, which a fresh or
    -- offline player may not give it. Fighters of this sector instead.
    local generator = include("sectorfightergenerator")()
    generator.factionIndex = playerIndex
    local x, y = Sector():getCoordinates()
    local fighter = generator:generateArmed(x, y)

    for _, squad in ipairs({hangar:getSquads()}) do
        for _ = 1, 4 do
            local ok, err = pcall(function() hangar:addFighter(squad, fighter) end)
            if not ok then say("addFighter(%s): %s", tostring(squad), tostring(err)) break end
        end
    end

    local crew = ship.idealCrew
    crew:setCaptain(ship.crew:getCaptain() or include("captaingenerator")():generate(3, 3))
    ship.crew = crew

    say("hangar after: %d fighters in %d squads (fighter volume %.2f), pilots in crew: %s",
        hangar.numFighters, hangar.numSquads, fighter.volume, tostring(ship.crew.pilots))
end

function steps.report(playerIndex)
    local ship = carrier(playerIndex)
    if not ship then say("no carrier, run setup") return end

    for _, script in ipairs({"entity/story/swoks.lua", "entity/story/aibehaviour.lua"}) do
        local found = {Sector():getEntitiesByScript(script)}
        local titles = {}
        for _, entity in ipairs(found) do titles[#titles + 1] = titleOf(entity) end
        say("getEntitiesByScript(%s): %d [%s]", script, #found, table.concat(titles, ", "))
    end

    say("isEnemyPresent: %s", tostring(ShipAI(ship):isEnemyPresent(false)))
    say("FighterCargoPickup: %s, transporterRange: %s",
        tostring(ship:getBoostedValue(StatsBonuses.FighterCargoPickup, 0)),
        tostring(ship.transporterRange))

    -- per kind of drop: how many, and how many of those this ship may collect
    local loots = {Sector():getEntitiesByType(EntityType.Loot)}
    local kinds, order = {}, {}
    for _, loot in ipairs(loots) do
        local kind = "none"
        for _, name in ipairs(LOOT_COMPONENTS) do
            if loot:hasComponent(ComponentType[name]) then kind = name break end
        end
        if not kinds[kind] then kinds[kind] = {total = 0, collectable = 0}; order[#order + 1] = kind end
        kinds[kind].total = kinds[kind].total + 1
        if loot:isCollectable(ship) then kinds[kind].collectable = kinds[kind].collectable + 1 end
    end
    local parts = {}
    for _, kind in ipairs(order) do
        parts[#parts + 1] = string.format("%s %d/%d", kind, kinds[kind].collectable, kinds[kind].total)
    end
    say("loot (collectable/total): %s", #parts > 0 and table.concat(parts, ", ") or "none")
    say("cargo space free %s of %s", tostring(ship.freeCargoSpace), tostring(ship.maxCargoSpace))
    say("transporter blocks %s, Transporter component %s",
        tostring(Plan(ship):getNumBlocks(BlockType.Transporter)),
        tostring(ship:hasComponent(ComponentType.Transporter)))

    local hangar = Hangar(ship)
    local squads = {hangar:getSquads()}
    local counts = {}
    for _, squad in ipairs(squads) do
        counts[#counts + 1] = squad .. ":" .. tostring(hangar:getSquadFighters(squad))
    end
    say("squads [%s], numFighters %d, deployed %d, collectAllFighters is a %s",
        table.concat(counts, " "), hangar.numFighters,
        #{FighterController(ship):getDeployedFighters()}, type(hangar.collectAllFighters))
end

function steps.kill(playerIndex)
    local ship = carrier(playerIndex)
    local position = ship and ship.translationf or vec3()

    for _, boss in ipairs({Sector():getEntitiesByScript("entity/story/swoks.lua")}) do
        boss:destroy(Uuid())
    end

    -- one drop of each kind next to the carrier, so the fighters have a short trip
    local sector = Sector()
    local faction = Faction(playerIndex)
    local near = function() return position + random():getDirection() * 300 end
    sector:dropMoney(near(), faction, nil, 5000)
    sector:dropResources(near(), faction, nil, Material(MaterialType.Titanium), 500)
    sector:dropCargo(near(), faction, nil, goods["Scrap Metal"]:good(), 0, 20)
    sector:dropUpgrade(near(), faction, nil,
                       SystemUpgradeTemplate("data/scripts/systems/arbitrarytcs.lua", Rarity(RarityType.Rare), Seed(1)))
    local okTorpedo = pcall(function()
        local TorpedoGenerator = include("torpedogenerator")
        local x, y = sector:getCoordinates()
        sector:dropTorpedo(near(), faction, nil, TorpedoGenerator():generate(x, y))
    end)

    say("boss destroyed, drops placed (torpedo: %s)", tostring(okTorpedo))
end

local function orderSquads(playerIndex, orders)
    local ship = carrier(playerIndex)
    if not ship then say("no carrier") return end

    local controller = FighterController(ship)
    for _, squad in ipairs({Hangar(ship):getSquads()}) do
        controller:setSquadOrders(squad, orders, Uuid())
    end
    say("squads ordered: %s", tostring(orders))
end

-- What Rare Transporter Software adds when installed permanently, without the software.
function steps.pickup(playerIndex)
    local ship = carrier(playerIndex)
    if not ship then say("no carrier") return end
    ship:addAbsoluteBias(StatsBonuses.FighterCargoPickup, 1)
    say("FighterCargoPickup now %s", tostring(ship:getBoostedValue(StatsBonuses.FighterCargoPickup, 0)))
end

function steps.loot(playerIndex) orderSquads(playerIndex, FighterOrders.CollectLoot) end
function steps.recall(playerIndex) orderSquads(playerIndex, FighterOrders.Return) end

function steps.collect(playerIndex)
    local ship = carrier(playerIndex)
    if not ship then say("no carrier") return end
    Hangar(ship):collectAllFighters()
    say("collectAllFighters called, deployed now %d", #{FighterController(ship):getDeployedFighters()})
end

-- Everything the lab put here: loot, the carrier and every ship not the player's - the
-- bosses and their escorts. Only meant for a sector of the lab's own.
function steps.clear(playerIndex)
    local sector = Sector()
    local removed = 0
    for _, entityType in ipairs({EntityType.Loot, EntityType.Ship, EntityType.Fighter}) do
        for _, entity in ipairs({sector:getEntitiesByType(entityType)}) do
            if entityType ~= EntityType.Ship or entity.factionIndex ~= playerIndex
               or entity:getValue("bosslab_carrier") then
                sector:deleteEntity(entity)
                removed = removed + 1
            end
        end
    end
    say("cleared %d entities", removed)
end

-- Hands the carrier a plan through the mod's callable, then prints what the appended
-- orderchain publishes back. A farm is ended at once for want of a pilot, which is itself
-- worth seeing happen in the engine.
function steps.plan(playerIndex, kind)
    local ship = carrier(playerIndex)
    if not ship then say("no carrier") return end

    local Json = include("automationapi/json")
    local x, y = Sector():getCoordinates()
    local spec = {id = "lab", kind = kind or "route", boss = "swoks", loopFrom = 1,
                  onEnemies = "fight",
                  hops = {{x = x + 1, y = y, kind = "jump"}, {x = x, y = y, kind = "jump"}}}

    local script = "data/scripts/entity/orderchain.lua"
    local status = ship:invokeFunction(script, "automationApiRunPlan", Json.encode(spec))
    local ok, info = ship:invokeFunction(script, "getOrderInfo")

    say("automationApiRunPlan -> %s, getOrderInfo -> %s %s", tostring(status), tostring(ok),
        type(info) == "table" and Json.encode(info.automationApi) or tostring(info))
end

function steps.state(playerIndex)
    local ship = carrier(playerIndex)
    if not ship then say("no carrier") return end

    local ok, info = ship:invokeFunction("data/scripts/entity/orderchain.lua", "getOrderInfo")
    say("getOrderInfo -> %s %s", tostring(ok),
        type(info) == "table" and include("automationapi/json").encode(info.automationApi) or tostring(info))
end

function run(playerIndex, step, kind)
    local fn = steps[step]
    if not fn then say("unknown step %s", tostring(step)) return end
    fn(playerIndex, kind)
end
]]

-- Deleting a craft leaves its row in the owner's ship database, so every lab carrier would
-- stay in the fleet list - and in the API's /ships - long after `clear`. Run after clear.
-- Offline players have no Player object here; the faction answers the same calls.
function DevSetup.forgetLabCarriers(playerIndex)
    local owner = Player(playerIndex) or Faction(playerIndex)
    if not owner then print("bosslab: no faction " .. tostring(playerIndex)) return end

    local forgotten = 0
    for _, name in ipairs({owner:getShipNames()}) do
        if string.sub(name, 1, #LAB_CARRIER) == LAB_CARRIER then
            owner:setShipDestroyed(name, true)
            owner:removeDestroyedShipInfo(name)
            forgotten = forgotten + 1
        end
    end

    print("bosslab: forgot " .. forgotten .. " lab carrier(s)")
end

function DevSetup.bossLab(playerIndex, x, y, step, kind)
    -- Nobody is in the lab sector to keep it loaded, and an idle sector is unloaded after a
    -- few minutes. Every step asks for another quarter hour, loading it first if need be.
    Galaxy():keepOrGetSector(x, y, 900)

    if not Galaxy():sectorLoaded(x, y) then
        print("bosslab: loading " .. x .. ":" .. y .. ", run the step again in a few seconds")
        return
    end

    if step == "load" then
        print("bosslab: " .. x .. ":" .. y .. " is loaded")
        return
    end

    if step == "forget" then
        DevSetup.forgetLabCarriers(playerIndex)
        return
    end

    runSectorCode(x, y, true, LAB_CODE, "run", playerIndex, step, kind)
end

return DevSetup
