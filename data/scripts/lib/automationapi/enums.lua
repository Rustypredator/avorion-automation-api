-- Turns engine enum values into names.
--
-- The engine's enums (EntityType, ShipAvailability, ...) are userdata, not Lua tables:
-- indexing them works but pairs() yields nothing, so a reverse map cannot be built by
-- iteration. The member names below come from the generated API documentation and are
-- stable; the *values* are still read from the game, so nothing here hardcodes an int
-- that a future version might renumber.
--
-- Enums that really are Lua tables - CaptainClasses, SimulationUtility.UsableError - are
-- handled by the same helper without a name list.

local Enums = {}

local function reverse(enum, memberNames)
    local byValue = {}
    if enum == nil then return byValue end

    if memberNames then
        for _, name in ipairs(memberNames) do
            local ok, value = pcall(function() return enum[name] end)
            if ok and value ~= nil then byValue[value] = name end
        end

        return byValue
    end

    -- plain Lua table: iteration is enough
    for name, value in pairs(enum) do byValue[value] = name end

    return byValue
end

Enums.reverse = reverse

Enums.entityType = reverse(EntityType,
    {"None", "Ship", "Drone", "Station", "Turret", "Asteroid", "Wreckage", "Anomaly",
     "Loot", "WormHole", "Torpedo", "Fighter", "Container", "Unknown", "Other"})

Enums.shipAvailability = reverse(ShipAvailability,
    {"Available", "Destroyed", "InBackground"})

Enums.crewProfession = reverse(CrewProfessionType,
    {"None", "Engine", "Gunner", "Miner", "Repair", "Pilot", "Security", "Attacker", "Number"})

Enums.malusReason = reverse(MalusReason,
    {"None", "Reconstruction", "Boarding", "RiftTeleport"})

Enums.weaponCategory = reverse(WeaponCategory,
    {"Armed", "Mining", "Salvaging", "Heal"})

function Enums.name(map, value)
    if value == nil then return nil end

    return map[value]
end

return Enums
