-- Cargo transfers: what a transfer request is made of, checked once for every way in.
--
-- A transfer moves goods between a ship and another craft of the same player or of that
-- player's alliance, the way vanilla's transfer window (entity/transfercrewgoods.lua) does:
--
--   give   from the ship into the target's hold
--   take   from the target's hold into the ship
--
-- Goods are named, as a condition names them, and each entry either says how many or
-- takes all there are. `all` moves the whole hold instead. Stolen goods are a separate
-- item in the game's cargo bay; an entry matches both kinds unless it says `stolen`.
--
-- Pure Lua: POST /ships/{name}/transfer and a program's transfer step both normalize
-- through here, each with its own way of failing, so a program can never save a transfer
-- the endpoint would refuse.

local Json = include("automationapi/json")

local TransferRules = {}

TransferRules.MAX_GOODS = 50
TransferRules.DIRECTIONS = {give = true, take = true}

-- An explicit JSON null counts as left out.
local function given(value)
    if value == Json.null then return nil end
    return value
end

-- `fail(code, message)` raises; both callers hand in one that never returns.
local function goodsOf(value, fail, where)
    if type(value) ~= "table" or #value == 0 then
        fail("no_goods", where .. " is a non-empty list of goods, or set 'all'.")
    end
    if #value > TransferRules.MAX_GOODS then
        fail("bad_goods", string.format("%s names at most %d goods.", where, TransferRules.MAX_GOODS))
    end

    local goods = Json.array({})

    for index, spec in ipairs(value) do
        local what = string.format("%s entry %d", where, index)
        if type(spec) == "string" then spec = {name = spec} end
        if type(spec) ~= "table" then fail("bad_goods", what .. " must be an object or a good's name.") end

        local name = type(spec.name) == "string" and string.match(spec.name, "^%s*(.-)%s*$") or ""
        if name == "" then fail("bad_goods", what .. " needs the good's 'name'.") end

        local good = {name = name}

        -- null and a missing amount both mean everything of that good
        if given(spec.amount) ~= nil then
            local amount = spec.amount
            if type(amount) ~= "number" or amount ~= math.floor(amount) or amount < 1 then
                fail("bad_goods", what .. ": 'amount' is a whole number of at least 1, or left out for all of it.")
            end
            good.amount = amount
        end

        if given(spec.stolen) ~= nil then
            if type(spec.stolen) ~= "boolean" then fail("bad_goods", what .. ": 'stolen' must be true or false.") end
            good.stolen = spec.stolen
        end

        goods[index] = good
    end

    return goods
end

-- Returns {direction, all, goods, approach}. `goods` is nil when `all` is set.
function TransferRules.normalize(spec, fail, prefix)
    prefix = prefix or ""

    local direction = string.lower(tostring(given(spec.direction) or "give"))
    if not TransferRules.DIRECTIONS[direction] then
        fail("bad_direction", "'" .. prefix .. "direction' is give (ship to target) or take (target to ship).")
    end

    local all = given(spec.all)
    if all ~= nil and type(all) ~= "boolean" then fail("bad_goods", "'" .. prefix .. "all' must be true or false.") end
    all = all == true

    local goods
    if all then
        local listed = given(spec.goods)
        if listed ~= nil and not (type(listed) == "table" and #listed == 0) then
            fail("conflicting_goods", "'" .. prefix .. "all' moves the whole hold; leave '" .. prefix .. "goods' out.")
        end
    else
        goods = goodsOf(spec.goods, fail, "'" .. prefix .. "goods'")
    end

    local approach = given(spec.approach)
    if approach ~= nil and type(approach) ~= "boolean" then
        fail("bad_approach", "'" .. prefix .. "approach' must be true or false.")
    end

    return {direction = direction, all = all, goods = goods, approach = approach ~= false}
end

-- The craft on the other end: a name, and optionally which of the caller's two owners
-- holds it when both have a craft of that name.
function TransferRules.target(spec, fail, prefix)
    prefix = prefix or ""

    local name = type(spec.target) == "string" and string.match(spec.target, "^%s*(.-)%s*$") or ""
    if name == "" then fail("no_target", "'" .. prefix .. "target' is the name of the craft to transfer with.") end

    local owner = given(spec.targetOwner)
    if owner ~= nil then
        owner = string.lower(tostring(owner))
        if owner ~= "player" and owner ~= "alliance" then
            fail("bad_target_owner", "'" .. prefix .. "targetOwner' is player or alliance.")
        end
    else
        owner = nil
    end

    return name, owner
end

-- One line for logs and the console: "give 100 Iron, all Steel to Hub".
function TransferRules.describe(transfer, target)
    local what
    if transfer.all then
        what = "everything"
    else
        local parts = {}
        for _, good in ipairs(transfer.goods or {}) do
            parts[#parts + 1] = (good.amount and tostring(good.amount) or "all") .. " "
                                .. (good.stolen and "stolen " or "") .. good.name
        end
        what = table.concat(parts, ", ")
    end

    return string.format("%s %s %s %s", transfer.direction, what,
                         transfer.direction == "take" and "from" or "to", tostring(target))
end

return TransferRules
