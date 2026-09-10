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

return DevSetup
