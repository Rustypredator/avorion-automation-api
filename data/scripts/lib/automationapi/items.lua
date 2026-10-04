-- Reading a faction's inventory: turrets, system upgrades, and the odds and ends.
--
-- The inventory is the one part of a faction the engine hands over whole, and it is the
-- part a player spends the most time sorting by hand. Everything here is a read; the one
-- write the API makes is setItemTags, at the bottom.
--
-- What the engine actually does, as opposed to what the documentation says (verified
-- against 2.5.13 on a real server, see docs/local-testing.md):
--
--   * Inventory:getItems() is documented as table<type, table<index, item>>. It is not.
--     It is a FLAT map, slot index -> {item = <InventoryItem>, amount = <n>}, exactly as
--     vanilla's scrapyard and research station iterate it.
--
--   * Slot indices are 0-based and sparse. Neither ipairs() nor the JSON encoder's array
--     detection can be used on them, which is why a listing here is always a rebuilt
--     1..n list carrying `index` as an ordinary field.
--
--   * Reading a property an item does not have does not return nil, it raises - and the
--     engine logs a full traceback and fires a crash report on the way out even though
--     the pcall catches it. An InventoryTurret has no `price`; a SystemUpgradeTemplate
--     has no `dps`. So nothing here probes: each item type has a fixed list of fields and
--     only those are read. Adding a field means knowing which types carry it.
--
--   * Stacks are one slot with one tag. Favouriting a stack of five favourites all five,
--     because there is one flag and it belongs to the slot.

local Json = include("automationapi/json")
local Serialize = include("automationapi/serialize")
local Enums = include("automationapi/enums")

local Items = {}

-- #### TYPES #### --

-- The API's names for InventoryItemType, which is an engine enum and therefore userdata
-- whose numbers are read from the game rather than written down here.
Items.TYPE_NAMES = {"turret", "template", "upgrade", "item", "usable"}

local TYPE_MEMBERS =
{
    turret = "Turret",
    template = "TurretTemplate",
    upgrade = "SystemUpgrade",
    item = "VanillaItem",
    usable = "UsableItem",
}

-- apiName -> engine value, and back. Built from the engine's own enum so a renumbering in
-- a future patch moves both halves together.
local typeValues, typeNames = {}, {}

for apiName, member in pairs(TYPE_MEMBERS) do
    local ok, value = pcall(function() return InventoryItemType[member] end)
    if ok and value ~= nil then
        typeValues[apiName] = value
        typeNames[value] = apiName
    end
end

function Items.typeValue(apiName) return typeValues[apiName] end
function Items.typeName(value) return typeNames[value] end

-- Turrets and loose turret templates share every weapon property, so everything that
-- reads a weapon stat accepts both.
Items.WEAPON_TYPES = {turret = true, template = true}

-- #### RARITY #### --

-- RarityType runs Petty(-1) .. Legendary(5) in the game; the numbers come from the engine
-- for the same reason the item types do. Ordered worst to best, which is what a threshold
-- means when a rule says "at most Rare".
Items.RARITY_NAMES = {"Petty", "Common", "Uncommon", "Rare", "Exceptional", "Exotic",
                      "Legendary"}

local rarityValues, rarityNames = {}, {}

for _, name in ipairs(Items.RARITY_NAMES) do
    local ok, value = pcall(function() return RarityType[name] end)
    if ok and value ~= nil then
        rarityValues[string.lower(name)] = value
        rarityNames[value] = name
    end
end

-- Accepts "rare", "Rare" or the raw number, so a client may send either.
function Items.rarityValue(given)
    if type(given) == "number" then
        return rarityNames[given] and given or nil
    end
    if type(given) ~= "string" then return nil end

    return rarityValues[string.lower(given)]
end

function Items.rarityName(value) return rarityNames[value] end

-- #### MATERIAL #### --

Items.MATERIAL_NAMES = {"Iron", "Titanium", "Naonite", "Trinium", "Xanion", "Ogonite",
                        "Avorion"}

local materialValues = {}

for _, name in ipairs(Items.MATERIAL_NAMES) do
    local ok, value = pcall(function() return MaterialType[name] end)
    if ok and value ~= nil then materialValues[string.lower(name)] = value end
end

function Items.materialValue(given)
    if type(given) == "number" then return given end
    if type(given) ~= "string" then return nil end

    return materialValues[string.lower(given)]
end

-- #### FIELD READERS #### --

-- Every read goes through here. An engine getter that raises would otherwise take the
-- whole listing down, and a single unreadable item is not worth failing a request over.
local function field(item, name, default)
    local ok, value = pcall(function() return item[name] end)
    if not ok then return default end

    return value
end

local function numberField(item, name)
    return Serialize.number(field(item, name), nil)
end

local function boolField(item, name)
    return Serialize.bool(field(item, name), false)
end

-- Rarity and Material are userdata carrying a name and a number. Both are reported: the
-- name is what a person reads, the number is what a threshold compares.
--
-- Their fields are not the same, and that matters more than it looks. Rarity has `type`
-- and `value`; Material has `value` alone. Asking a Material for its type does not return
-- nil - it raises, and the engine writes "Property not found: Material.type" and a full
-- traceback to the server log on the way out, once per item per read. So `withType` is
-- stated by the caller rather than discovered.
local function valueType(item, name, withType)
    local holder = field(item, name)
    if holder == nil then return nil end

    local okValue, value = pcall(function() return holder.value end)
    local okName, text = pcall(function() return holder.name end)

    local out =
    {
        value = okValue and Serialize.number(value, nil) or nil,
        name = okName and Serialize.displayName(text) or nil,
    }

    if withType then
        local ok, typeValue = pcall(function() return holder.type end)
        out.type = ok and Serialize.number(typeValue, nil) or nil
    end

    return out
end

-- A turret's `title` is a Format object, not a string: tostring() on one gives a bare
-- pointer that differs on every server run. Format exposes `text` as a property and
-- `translated`/`evaluate` as functions, so the generic argument reader in serialize.lua
-- is no use here - it probes `translated` as a property, finds a function, and falls
-- through to a field Format does not have, which the engine logs with a traceback.
local function formatText(value)
    if value == nil then return nil end
    if type(value) == "string" then return Serialize.displayName(value) end
    if type(value) ~= "userdata" and type(value) ~= "table" then return nil end

    -- evaluate() fills the template in; `text` is the template itself, which reads
    -- "%1%%2%%3%" and helps nobody.
    local okEval, evaluated = pcall(function() return value:evaluate() end)
    if okEval and type(evaluated) == "string" and evaluated ~= "" then
        return Serialize.displayName(evaluated)
    end

    local ok, text = pcall(function() return value.text end)
    if ok and type(text) == "string" and text ~= "" then return Serialize.displayName(text) end

    return nil
end

-- #### WEAPONS #### --

-- The stats a turret is actually judged on. Deliberately a subset: an InventoryTurret
-- carries nearly ninety properties, most of them internal to the shooting simulation, and
-- a listing that serialized all of them would cost more to encode than to produce.
local function weaponFields(item, record)
    record.weaponName = Serialize.displayName(field(item, "weaponName"))
    record.title = formatText(field(item, "title"))
    record.prefix = Serialize.displayName(field(item, "weaponPrefix"))

    record.category = Enums.name(Enums.weaponCategory, field(item, "category"))
    record.slotType = Enums.name(Enums.turretSlotType, field(item, "slotType"))
    record.damageType = Enums.name(Enums.damageType, field(item, "damageType"))

    record.dps = numberField(item, "dps")
    record.damage = numberField(item, "damage")
    record.fireRate = numberField(item, "fireRate")
    record.reach = numberField(item, "reach")
    record.accuracy = numberField(item, "accuracy")
    record.shotSpeed = numberField(item, "shotSpeed")
    record.shieldPenetration = numberField(item, "shieldPenetration")

    -- The multipliers are what makes two turrets of the same dps unequal: an anti-matter
    -- gun that ignores shields and a chaingun that bounces off them read the same
    -- otherwise. Reported pre-multiplied as well, since that is the number a threshold
    -- wants to be set against.
    local hull = numberField(item, "hullDamageMultiplier")
    local shield = numberField(item, "shieldDamageMultiplier")

    record.hullMultiplier = hull
    record.shieldMultiplier = shield
    record.hullDps = record.dps and hull and record.dps * hull or record.dps
    record.shieldDps = record.dps and shield and record.dps * shield or record.dps

    -- Mining and salvaging turrets are not judged on dps at all, they are judged on how
    -- much of the material they recover.
    record.efficiency = numberField(item, "bestEfficiency")

    record.tech = numberField(item, "averageTech")
    record.maxTech = numberField(item, "maxTech")
    record.material = valueType(item, "material")

    record.slots = numberField(item, "slots")
    record.size = numberField(item, "size")
    record.numWeapons = numberField(item, "numWeapons")

    record.armed = boolField(item, "armed")
    record.coaxial = boolField(item, "coaxial")
    record.seeker = boolField(item, "seeker")
    record.ancient = boolField(item, "ancient")

    -- Energy and crew are the costs of carrying it, and the usual reason a turret that
    -- looks good on paper never gets fitted.
    record.energyPerSecond = numberField(item, "baseEnergyPerSecond")

    local crew = field(item, "crew")
    if crew ~= nil then
        local ok, total = pcall(function() return crew.size end)
        record.crew = ok and Serialize.number(total, nil) or nil
    end
end

-- #### RECORDS #### --

-- One inventory slot, flattened into something a client can sort a table by.
--
-- `index` is the engine's slot number and the only handle a tag write has, so it travels
-- with every record whether the caller asked for it or not.
function Items.describe(index, slot)
    local item = slot.item
    if item == nil then return nil end

    local typeValue = field(item, "itemType")

    local record =
    {
        index = Serialize.number(index, 0),
        amount = Serialize.number(slot.amount, 1),
        type = typeNames[typeValue] or "unknown",
        name = Serialize.displayName(field(item, "name")),
        rarity = valueType(item, "rarity", true),
        favorite = boolField(item, "favorite"),
        trash = boolField(item, "trash"),
        stackable = boolField(item, "stackable"),
        missionRelevant = boolField(item, "missionRelevant"),
    }

    local apiType = record.type

    if Items.WEAPON_TYPES[apiType] then
        weaponFields(item, record)
    else
        -- Everything that is not a weapon: upgrades, usable items, vanilla items. These
        -- share the plain item properties and have no stats of their own worth reporting
        -- beyond what the upgrade's own script decides at install time.
        record.price = numberField(item, "price")
        record.icon = Serialize.string(field(item, "icon"), nil)

        -- Only the two item types that are actually goods carry these. A
        -- SystemUpgradeTemplate has neither, and asking it raises.
        if apiType == "item" or apiType == "usable" then
            record.tradeable = boolField(item, "tradeable")
            record.droppable = boolField(item, "droppable")
        end

        if apiType == "upgrade" or apiType == "usable" then
            record.script = Serialize.string(field(item, "script"), nil)
        end

        -- An upgrade's energy draw is a function, not a property, and the permanent and
        -- socketed answers differ. The socketed one is what a ship pays to run it.
        if apiType == "upgrade" then
            local ok, energy = pcall(function() return item:getEnergy(false) end)
            if ok then record.energy = Serialize.number(energy, nil) end
        end
    end

    return record
end

-- #### READING AN INVENTORY #### --

-- Describing one slot costs roughly thirty engine property reads, so a thousand-slot
-- inventory is thirty thousand of them. That is affordable once inside a request and not
-- affordable every time a background sweep comes round, which is why the inventory is
-- opened, walked and described in three separate steps rather than one: the sweeper takes
-- the list of indices in one tick and describes a handful of them per tick after that.

function Items.open(faction)
    return faction:getInventory()
end

-- The occupied slot numbers, in the order the player sees them. Sparse and 0-based in the
-- engine, so this is a rebuilt 1..n list of the numbers themselves.
function Items.indices(inventory)
    local indices = {}

    local ok, items = pcall(function() return inventory:getItems() end)
    if not ok or type(items) ~= "table" then return indices end

    for index, slot in pairs(items) do
        if type(index) == "number" and type(slot) == "table" and slot.item ~= nil then
            indices[#indices + 1] = index
        end
    end

    table.sort(indices)

    return indices
end

-- One slot, looked up fresh. Returns nil if the slot is empty, which is the normal answer
-- for an index that came from a listing taken a few seconds ago.
function Items.at(inventory, index)
    local okFind, item = pcall(function() return inventory:find(index) end)
    if not okFind or item == nil then return nil end

    local okAmount, amount = pcall(function() return inventory:amount(index) end)

    return Items.describe(index, {item = item, amount = okAmount and amount or 1})
end

-- Every slot as records, plus what the inventory itself reports. `limit` caps how many
-- slots are described; the summary still counts the whole inventory, so a caller can tell
-- that it was cut short.
function Items.read(faction, limit)
    local inventory = Items.open(faction)
    local indices = Items.indices(inventory)

    local records = {}

    for _, index in ipairs(indices) do
        if limit and #records >= limit then break end

        local record = Items.at(inventory, index)
        if record then records[#records + 1] = record end
    end

    return records,
    {
        occupied = Serialize.number(field(inventory, "occupiedSlots"), #indices),
        maxSlots = Serialize.number(field(inventory, "maxSlots"), 0),
        slots = #indices,
        described = #records,
        truncated = limit ~= nil and #indices > #records,
    }
end

-- #### WRITING TAGS #### --

-- setItemTags takes both flags at once, so "mark as trash" means reading the other flag
-- and writing it back unchanged. The engine has no partial setter.
--
-- An item is identified again before it is written: the caller's index came from a read
-- that may be seconds old, and in that time the slot can hold something else entirely -
-- an item was sold, a stack ran out, a turret came back from a ship. Marking the wrong
-- turret as trash is the one way this feature can cost somebody something, so a write
-- that no longer matches what was read is refused rather than guessed at.
--
-- Returns true, or false and a reason.
function Items.setTags(inventory, index, favorite, trash, expect)
    local okFind, item = pcall(function() return inventory:find(index) end)
    if not okFind or item == nil then return false, "gone" end

    if expect then
        local name = Serialize.displayName(field(item, "name"))
        if expect.name and name ~= expect.name then return false, "changed" end

        local rarity = valueType(item, "rarity", true)
        if expect.rarity and rarity and expect.rarity ~= rarity.type then
            return false, "changed"
        end
    end

    -- Nothing to do is a success. The sweeper relies on this: most of what it looks at on
    -- its second pass is already marked, and a write per pass per item would be the thing
    -- that makes it expensive.
    if boolField(item, "favorite") == favorite and boolField(item, "trash") == trash then
        return true, "unchanged"
    end

    local ok, err = pcall(function() inventory:setItemTags(index, favorite, trash) end)
    if not ok then return false, tostring(err) end

    return true, "written"
end

-- #### SUMMARY #### --

-- Facet counts over a list of records, for a console that wants to offer the filters that
-- would actually narrow anything down.
function Items.summarize(records)
    local byType, byRarity, byCategory = {}, {}, {}
    local favorites, trashed, stacks = 0, 0, 0

    for _, record in ipairs(records) do
        byType[record.type] = (byType[record.type] or 0) + 1

        local rarity = record.rarity and record.rarity.name or "Unknown"
        byRarity[rarity] = (byRarity[rarity] or 0) + 1

        if record.category then
            byCategory[record.category] = (byCategory[record.category] or 0) + 1
        end

        if record.favorite then favorites = favorites + 1 end
        if record.trash then trashed = trashed + 1 end

        stacks = stacks + (record.amount or 1)
    end

    return
    {
        slots = #records,
        items = stacks,
        favorites = favorites,
        trashed = trashed,
        byType = byType,
        byRarity = byRarity,
        byCategory = byCategory,
    }
end

return Items
