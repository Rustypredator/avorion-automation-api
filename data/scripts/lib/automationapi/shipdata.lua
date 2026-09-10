-- Reads ships out of the ship database and turns them into plain tables.
--
-- Everything here goes through ShipDatabaseEntry rather than Entity, which is what makes
-- the ship endpoints work for craft in unloaded sectors and for players who are offline.
-- The database row is authoritative for a ship in background simulation; for one sitting
-- in a loaded sector it is a mirror the engine keeps up to date.

package.path = package.path .. ";data/scripts/player/background/simulation/?.lua"

local Json = include("automationapi/json")
local Serialize = include("automationapi/serialize")
local Enums = include("automationapi/enums")

local SimulationUtility = include("simulationutility")
-- captainclass returns its table rather than defining a global, unlike the engine enums
local CaptainClasses = include("captainclass")

local ShipData = {}

-- #### HELPERS #### --

local enumName = Enums.name

-- These two are genuine Lua tables rather than engine userdata, so they reverse by
-- iteration; built once here rather than per call.
local usableErrorNames = Enums.reverse(SimulationUtility.UsableError)
local captainClassNames = Enums.reverse(CaptainClasses)

-- Database getters can raise if a ship is in an odd state; one bad field should degrade
-- that field, not fail the whole request.
local function safe(fn, default)
    local ok, a, b, c, d, e = pcall(fn)
    if not ok then return default end

    return a, b, c, d, e
end

local usableErrorMessages =
{
    [SimulationUtility.UsableError.Unavailable] = "Ship is not available.",
    [SimulationUtility.UsableError.NotAShip]    = "This is not a ship.",
    [SimulationUtility.UsableError.NoCaptain]   = "Ship has no captain.",
    [SimulationUtility.UsableError.BadCrew]     = "Crew requirements are not fulfilled.",
    [SimulationUtility.UsableError.BadEnergy]   = "Energy requirements are not fulfilled.",
    [SimulationUtility.UsableError.Damaged]     = "Ship is damaged.",
    [SimulationUtility.UsableError.UnderAttack] = "Ship is under attack.",
}

-- The gate every captain mission checks first. Surfacing it on every ship lets a planner
-- filter to eligible ships without probing each one.
function ShipData.usable(ownerIndex, name, ignoredErrors)
    local err = safe(function()
        return SimulationUtility.isShipUsable(ownerIndex, name, ignoredErrors)
    end)

    if not err then return {ok = true} end

    return
    {
        ok = false,
        code = enumName(usableErrorNames, err),
        message = usableErrorMessages[err] or "Ship cannot be used.",
    }
end

-- #### COMPONENTS #### --

local function captainOf(entry)
    local captain = safe(function() return entry:getCaptain() end)
    if not captain then return nil end

    local classes = Json.array({})
    for _, class in ipairs({captain.primaryClass, captain.secondaryClass}) do
        if class and class ~= 0 then
            classes[#classes + 1] = {value = class, name = enumName(captainClassNames, class)}
        end
    end

    local perks = Json.array({})
    for _, perk in ipairs({safe(function() return captain:getPerks() end)}) do
        perks[#perks + 1] = perk
    end

    return
    {
        name = Serialize.string(captain.name),
        nickName = Serialize.string(captain.nickName),
        displayName = Serialize.string(captain.displayName),
        level = Serialize.number(captain.level, 0),
        tier = Serialize.number(captain.tier, 0),
        experience = Serialize.number(captain.experience, 0),
        experiencePercentage = Serialize.number(captain.experiencePercentage, 0),
        salary = Serialize.number(captain.salary, 0),
        classes = classes,
        perks = perks,
    }
end

local function crewBreakdown(crew)
    local result = Json.array({})
    if not crew then return result end

    -- Both getters key by CrewProfession userdata, but each call hands back fresh
    -- instances, so the two tables can only be joined on the profession's value.
    local workforce = {}
    for profession, amount in pairs(safe(function() return crew:getWorkforce() end, {}) or {}) do
        workforce[profession.value] = amount
    end

    local counts = safe(function() return crew:getNumMembersByProfession() end, {}) or {}
    for profession, count in pairs(counts) do
        result[#result + 1] =
        {
            profession = enumName(Enums.crewProfession, profession.value) or tostring(profession.value),
            value = profession.value,
            count = Serialize.number(count, 0),
            workforce = Serialize.number(workforce[profession.value], 0),
        }
    end

    table.sort(result, function(a, b) return (a.value or 0) < (b.value or 0) end)

    return result
end

local function crewOf(entry)
    local crew = safe(function() return entry:getCrew() end)
    local ideal = safe(function() return entry:buildIdealCrew() end)

    return
    {
        size = crew and Serialize.number(crew.size, 0) or 0,
        maxSize = crew and Serialize.number(crew.maxSize, 0) or 0,
        requirementsFulfilled = safe(function()
            return entry:getCrewRequirementsFulfilled()
        end, false) == true,
        byProfession = crewBreakdown(crew),
        ideal = crewBreakdown(ideal),
    }
end

local function cargoOf(entry)
    local cargos, capacity = safe(function() return entry:getCargo() end)
    local free = Serialize.number(safe(function() return entry:getFreeCargoSpace() end), 0)
    capacity = Serialize.number(capacity, 0)

    return
    {
        capacity = capacity,
        free = free,
        used = capacity - free,
        goods = Serialize.cargoList(cargos),
    }
end

local function hyperspaceOf(entry)
    local reach, canPassRifts, cooldown, impaired = safe(function()
        return entry:getHyperspaceProperties()
    end)

    return
    {
        range = Serialize.number(reach, 0),
        canPassRifts = canPassRifts == true,
        cooldown = Serialize.number(cooldown, 0),
        impaired = impaired == true,
    }
end

local function durabilityOf(entry)
    local maxHp, percentage, malusFactor, malusReason, damaged = safe(function()
        return entry:getDurabilityProperties()
    end)

    return
    {
        max = Serialize.number(maxHp, 0),
        percentage = Serialize.number(percentage, 0),
        malusFactor = Serialize.number(malusFactor, 1),
        malusReason = enumName(Enums.malusReason, malusReason),
        damaged = damaged == true,
    }
end

local function energyOf(entry)
    local required, produced = safe(function() return entry:getEnergyProperties() end)
    required = Serialize.number(required, 0)
    produced = Serialize.number(produced, 0)

    return {required = required, produced = produced, sufficient = required <= produced}
end

-- Ships carry many copies of the same turret and getTurrets() keys by design instance,
-- so two identical turrets arrive as two separate entries. They are grouped here by
-- their visible characteristics, which is what a planner actually cares about.
local function turretsOf(entry)
    local turrets = safe(function() return entry:getTurrets() end, {}) or {}

    local grouped = {}
    local order = {}

    for turret, count in pairs(turrets) do
        local ok, described = pcall(function()
            return
            {
                name = Serialize.displayName(turret.weaponName or turret.name),
                category = enumName(Enums.weaponCategory, turret.category),
                rarity = turret.rarity and Serialize.string(turret.rarity.name) or nil,
                material = turret.material and Serialize.string(turret.material.name) or nil,
                armed = turret.armed == true,
                dps = Serialize.number(turret.dps, 0),
                reach = Serialize.number(turret.reach, 0),
                slots = Serialize.number(turret.slots, 1),
                mining =
                {
                    stoneRaw = Serialize.number(turret.stoneRawEfficiency, 0),
                    stoneRefined = Serialize.number(turret.stoneRefinedEfficiency, 0),
                    metalRaw = Serialize.number(turret.metalRawEfficiency, 0),
                    metalRefined = Serialize.number(turret.metalRefinedEfficiency, 0),
                },
                count = Serialize.number(count, 1),
            }
        end)

        if ok then
            local signature = table.concat({described.name or "", described.category or "",
                                            described.rarity or "", described.material or "",
                                            string.format("%.3f", described.dps or 0)}, "|")

            if grouped[signature] then
                grouped[signature].count = grouped[signature].count + described.count
            else
                grouped[signature] = described
                order[#order + 1] = signature
            end
        end
    end

    local result = Json.array({})
    for _, signature in ipairs(order) do result[#result + 1] = grouped[signature] end

    table.sort(result, function(a, b) return (a.dps or 0) > (b.dps or 0) end)

    return result
end

local function systemsOf(entry)
    local systems = safe(function() return entry:getSystems() end, {}) or {}

    local result = Json.array({})
    for system, count in pairs(systems) do
        local ok, described = pcall(function()
            return
            {
                script = Serialize.string(system.script),
                name = Serialize.displayName(system.name),
                rarity = system.rarity and Serialize.string(system.rarity.name) or nil,
                count = Serialize.number(count, 1),
            }
        end)

        if ok then result[#result + 1] = described end
    end

    table.sort(result, function(a, b) return (a.script or "") < (b.script or "") end)

    return result
end

local function hangarOf(entry)
    local squads = safe(function() return entry:getLightweightHangar() end, {}) or {}

    local result = Json.array({})
    local total = 0

    for _, squad in pairs(squads) do
        local ok, described = pcall(function()
            local fighters = {squad:getFighters()}
            return {name = Serialize.string(squad.name), fighters = #fighters}
        end)

        if ok then
            total = total + described.fighters
            result[#result + 1] = described
        end
    end

    return {squads = result, fighters = total}
end

-- #### PUBLIC #### --

-- Cheap enough to call for every craft a player owns.
function ShipData.summary(owner, name)
    local faction = owner.faction

    local x, y = safe(function() return faction:getShipPosition(name) end)
    local entityType = safe(function() return faction:getShipType(name) end)
    local availability = safe(function() return faction:getShipAvailability(name) end)

    return
    {
        name = name,
        owner = {kind = owner.kind, index = owner.index, name = owner.name},
        type = enumName(Enums.entityType, entityType),
        position = Serialize.vec2(x, y),
        availability = enumName(Enums.shipAvailability, availability),
        status = Serialize.string(safe(function() return faction:getShipStatus(name) end)),
        usable = ShipData.usable(owner.index, name),
    }
end

-- Everything the database knows. One row read, no sector loading, works offline.
function ShipData.detail(owner, name)
    local entry = ShipDatabaseEntry(owner.index, name)
    if not entry or not safe(function() return entry:exists() end, false) then
        return nil
    end

    local result = ShipData.summary(owner, name)

    result.statusMessage = Serialize.format(safe(function() return entry:getStatusMessage() end))
    result.title = Serialize.format(safe(function() return entry:getTitle() end))
    result.icon = Serialize.string(safe(function() return entry:getIcon() end))
    result.orderInfo = Serialize.string(safe(function() return entry:getOrderInfo() end))

    result.blocks = Serialize.number(safe(function() return entry.numBlocks end), 0)
    result.planValue = Serialize.number(safe(function() return entry:getPlanValue() end), 0)
    result.reconstructionValue =
        Serialize.number(safe(function() return entry:getReconstructionValue() end), 0)

    result.captain = captainOf(entry)
    result.crew = crewOf(entry)
    result.cargo = cargoOf(entry)
    result.hyperspace = hyperspaceOf(entry)
    result.durability = durabilityOf(entry)
    result.energy = energyOf(entry)

    local shieldMax, shieldPercentage = safe(function() return entry:getShields() end)
    result.shields =
    {
        max = Serialize.number(shieldMax, 0),
        percentage = Serialize.number(shieldPercentage, 0),
    }

    local turretDps, fighterDps = safe(function() return entry:getDPSValues() end)
    result.dps =
    {
        turrets = Serialize.number(turretDps, 0),
        fighters = Serialize.number(fighterDps, 0),
        total = Serialize.number(turretDps, 0) + Serialize.number(fighterDps, 0),
    }

    result.turrets = turretsOf(entry)
    result.systems = systemsOf(entry)
    result.hangar = hangarOf(entry)

    result.requirements =
    {
        crew = safe(function() return entry:getCrewRequirementsFulfilled() end, false) == true,
        turretSlots = safe(function() return entry:getTurretSlotRequirementsFulfilled() end, false) == true,
        fighterStarts = safe(function() return entry:getFighterStartRequirementsFulfilled() end, false) == true,
        fighterSquads = safe(function() return entry:getFighterSquadRequirementsFulfilled() end, false) == true,
    }

    return result
end

return ShipData
