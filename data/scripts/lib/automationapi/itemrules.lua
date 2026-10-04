-- The vocabulary for talking about inventory items: what can be compared, how, and what
-- the trash manager does with the answer.
--
-- One vocabulary serves two callers on purpose. A filter on the inventory listing and a
-- threshold in a trash rule are the same question asked twice - "which of my turrets are
-- below 400 dps" is how you decide to throw them away, and "throw away turrets below 400
-- dps" is the rule you then write. Sharing the grammar means the console can offer the
-- same builder for both, and a filter that found the right items is a rule that marks
-- exactly those and nothing else.
--
-- A condition is {stat, op, value}:
--
--   {stat = "dps",    op = "atMost",  value = 400}
--   {stat = "rarity", op = "atMost",  value = "Rare"}
--   {stat = "type",   op = "is",      value = "turret"}
--   {stat = "name",   op = "contains", value = "Chaingun"}
--
-- A rule is a list of conditions that all have to hold (AND) plus what to do with what
-- matches. Rules are tried in order and the first that matches decides, so a "keep" rule
-- above a "trash" rule is how an exception is written.
--
-- Pure Lua apart from the enum names it borrows from items.lua, so the tests drive it
-- without the game.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Items = include("automationapi/items")

local ItemRules = {}

ItemRules.MAX_RULES = 24
ItemRules.MAX_CONDITIONS = 10
ItemRules.MAX_NAME = 48

local function fail(message, details)
    Router.fail(400, "bad_rule", message, details)
end

local function sortedKeys(t)
    local keys = {}
    for key, _ in pairs(t) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

-- #### STATS #### --

-- Every stat a condition may name, how it compares, and where it is read from a record
-- produced by items.lua.
--
--   number  - ordered; atMost / atLeast / is / isNot
--   rank    - ordered by an engine enum the API spells out in words (rarity, material),
--             so "at most Rare" means something regardless of what number Rare is
--   choice  - unordered set of names; is / isNot / oneOf
--   text    - contains / is / isNot, case-insensitive
--   flag    - is true / is false
--
-- A stat an item does not carry (dps on a system upgrade) reads as nil, and a condition
-- on a nil never matches. That is deliberate: "dps at most 400" must not quietly sweep up
-- every upgrade in the inventory because they have no dps at all. Rules that mean to span
-- types say so with a `type` condition.
local STATS =
{
    type       = {kind = "choice", choices = Items.TYPE_NAMES,
                  get = function(r) return r.type end},
    rarity     = {kind = "rank", order = Items.RARITY_NAMES,
                  get = function(r) return r.rarity and r.rarity.name end},
    material   = {kind = "rank", order = Items.MATERIAL_NAMES,
                  get = function(r) return r.material and r.material.name end},
    category   = {kind = "choice", choices = {"Armed", "Mining", "Salvaging", "Heal", "None"},
                  get = function(r) return r.category end},
    slotType   = {kind = "choice", choices = {"Unspecified", "Armed", "Unarmed", "PointDefense"},
                  get = function(r) return r.slotType end},
    damageType = {kind = "choice",
                  choices = {"Physical", "Energy", "AntiMatter", "Electric", "Plasma",
                             "Fragments", "None"},
                  get = function(r) return r.damageType end},

    name       = {kind = "text", get = function(r) return r.name end},
    weaponName = {kind = "text", get = function(r) return r.weaponName end},

    dps        = {kind = "number", get = function(r) return r.dps end},
    hullDps    = {kind = "number", get = function(r) return r.hullDps end},
    shieldDps  = {kind = "number", get = function(r) return r.shieldDps end},
    damage     = {kind = "number", get = function(r) return r.damage end},
    fireRate   = {kind = "number", get = function(r) return r.fireRate end},
    reach      = {kind = "number", get = function(r) return r.reach end},
    accuracy   = {kind = "number", get = function(r) return r.accuracy end},
    efficiency = {kind = "number", get = function(r) return r.efficiency end},
    shieldPenetration = {kind = "number", get = function(r) return r.shieldPenetration end},
    tech       = {kind = "number", get = function(r) return r.tech end},
    slots      = {kind = "number", get = function(r) return r.slots end},
    size       = {kind = "number", get = function(r) return r.size end},
    numWeapons = {kind = "number", get = function(r) return r.numWeapons end},
    energyPerSecond = {kind = "number", get = function(r) return r.energyPerSecond end},
    crew       = {kind = "number", get = function(r) return r.crew end},
    price      = {kind = "number", get = function(r) return r.price end},
    energy     = {kind = "number", get = function(r) return r.energy end},
    amount     = {kind = "number", get = function(r) return r.amount end},

    armed      = {kind = "flag", get = function(r) return r.armed end},
    coaxial    = {kind = "flag", get = function(r) return r.coaxial end},
    seeker     = {kind = "flag", get = function(r) return r.seeker end},
    ancient    = {kind = "flag", get = function(r) return r.ancient end},
    favorite   = {kind = "flag", get = function(r) return r.favorite end},
    trash      = {kind = "flag", get = function(r) return r.trash end},
    missionRelevant = {kind = "flag", get = function(r) return r.missionRelevant end},
    stackable  = {kind = "flag", get = function(r) return r.stackable end},
}

ItemRules.STATS = STATS

local OPS_BY_KIND =
{
    number = {atMost = true, atLeast = true, is = true, isNot = true},
    rank   = {atMost = true, atLeast = true, is = true, isNot = true, oneOf = true},
    choice = {is = true, isNot = true, oneOf = true},
    text   = {contains = true, is = true, isNot = true},
    flag   = {is = true},
}

-- Rank order lookups, built once: "Rare" -> 4 within its own list.
local ranks = {}

for statName, stat in pairs(STATS) do
    if stat.kind == "rank" then
        local order = {}
        for position, name in ipairs(stat.order) do order[string.lower(name)] = position end
        ranks[statName] = order
    end
end

-- The whole vocabulary, for a console that builds its own filter UI and for the catalog
-- endpoint. Anything the API understands is in here; nothing else is.
function ItemRules.vocabulary()
    local stats = Json.array({})

    for _, name in ipairs(sortedKeys(STATS)) do
        local stat = STATS[name]
        local ops = Json.array({})
        for _, op in ipairs(sortedKeys(OPS_BY_KIND[stat.kind])) do ops[#ops + 1] = op end

        local entry = {stat = name, kind = stat.kind, ops = ops}

        if stat.choices then entry.values = Json.array(stat.choices) end
        if stat.order then entry.values = Json.array(stat.order) end

        stats[#stats + 1] = entry
    end

    return stats
end

-- #### VALIDATION #### --

local function cleanName(value)
    if type(value) ~= "string" then return nil end
    local name = string.match(value, "^%s*(.-)%s*$")
    if name == "" or #name > ItemRules.MAX_NAME then return nil end
    return name
end

ItemRules.cleanName = cleanName

-- One condition, checked against the vocabulary and normalised. Names of ranks and
-- choices are stored in their canonical spelling, so "rare" saved today still reads
-- "Rare" in the console tomorrow.
local function condition(spec, where)
    if type(spec) ~= "table" then fail(where .. " must be {stat, op, value}.") end

    local statName = type(spec.stat) == "string" and spec.stat or nil
    local stat = statName and STATS[statName]

    if not stat then
        fail(string.format("%s names no stat this API knows: '%s'.", where,
                           tostring(spec.stat)),
             {stats = Json.array(sortedKeys(STATS))})
    end

    local op = type(spec.op) == "string" and spec.op or "is"
    if not OPS_BY_KIND[stat.kind][op] then
        fail(string.format("%s: '%s' cannot be compared with '%s'.", where, statName, op),
             {ops = Json.array(sortedKeys(OPS_BY_KIND[stat.kind]))})
    end

    local out = {stat = statName, op = op}

    if stat.kind == "number" then
        if type(spec.value) ~= "number" or spec.value ~= spec.value then
            fail(string.format("%s: '%s' compares against a number.", where, statName))
        end
        out.value = spec.value

    elseif stat.kind == "flag" then
        if type(spec.value) ~= "boolean" then
            fail(string.format("%s: '%s' is true or false.", where, statName))
        end
        out.value = spec.value

    elseif stat.kind == "text" then
        local text = type(spec.value) == "string" and spec.value or nil
        if not text or text == "" or #text > 120 then
            fail(string.format("%s: '%s' compares against a piece of text.", where, statName))
        end
        out.value = text

    else
        -- rank and choice: one name, or a list of them for oneOf
        local allowed = {}
        for _, name in ipairs(stat.order or stat.choices) do
            allowed[string.lower(name)] = name
        end

        local given = spec.value
        if op == "oneOf" then
            if type(given) ~= "table" or #given == 0 then
                fail(string.format("%s: 'oneOf' takes a list of names.", where),
                     {values = Json.array(stat.order or stat.choices)})
            end

            local names = Json.array({})
            for _, entry in ipairs(given) do
                local canonical = type(entry) == "string" and allowed[string.lower(entry)]
                if not canonical then
                    fail(string.format("%s: '%s' is not a %s.", where, tostring(entry), statName),
                         {values = Json.array(stat.order or stat.choices)})
                end
                names[#names + 1] = canonical
            end

            out.value = names
        else
            local canonical = type(given) == "string" and allowed[string.lower(given)]
            if not canonical then
                fail(string.format("%s: '%s' is not a %s.", where, tostring(given), statName),
                     {values = Json.array(stat.order or stat.choices)})
            end
            out.value = canonical
        end
    end

    return out
end

ItemRules.condition = condition

-- A list of conditions, all of which must hold.
function ItemRules.conditions(spec, where)
    where = where or "'conditions'"

    if spec == nil then return Json.array({}) end
    if type(spec) ~= "table" then fail(where .. " is a list of conditions.") end

    if #spec > ItemRules.MAX_CONDITIONS then
        fail(string.format("%s holds at most %d conditions.", where, ItemRules.MAX_CONDITIONS))
    end

    local out = Json.array({})
    for position, entry in ipairs(spec) do
        out[#out + 1] = condition(entry, string.format("%s[%d]", where, position))
    end

    return out
end

-- #### MATCHING #### --

local function compareNumber(value, op, target)
    if type(value) ~= "number" then return false end

    if op == "atMost" then return value <= target end
    if op == "atLeast" then return value >= target end
    if op == "is" then return value == target end
    if op == "isNot" then return value ~= target end

    return false
end

local function compareRank(statName, value, op, target)
    local order = ranks[statName]
    if not order or type(value) ~= "string" then return false end

    local have = order[string.lower(value)]
    if not have then return false end

    if op == "oneOf" then
        for _, name in ipairs(target) do
            if string.lower(name) == string.lower(value) then return true end
        end
        return false
    end

    local want = order[string.lower(target)]
    if not want then return false end

    if op == "atMost" then return have <= want end
    if op == "atLeast" then return have >= want end
    if op == "is" then return have == want end
    if op == "isNot" then return have ~= want end

    return false
end

local function compareChoice(value, op, target)
    if type(value) ~= "string" then return false end

    if op == "oneOf" then
        for _, name in ipairs(target) do
            if string.lower(name) == string.lower(value) then return true end
        end
        return false
    end

    local same = string.lower(value) == string.lower(target)
    if op == "is" then return same end
    if op == "isNot" then return not same end

    return false
end

local function compareText(value, op, target)
    if type(value) ~= "string" then return false end

    local haystack, needle = string.lower(value), string.lower(target)

    -- plain find: a weapon name is full of punctuation a pattern would read as syntax
    if op == "contains" then return string.find(haystack, needle, 1, true) ~= nil end
    if op == "is" then return haystack == needle end
    if op == "isNot" then return haystack ~= needle end

    return false
end

-- Whether one condition holds for one record.
function ItemRules.holds(record, cond)
    local stat = STATS[cond.stat]
    if not stat then return false end

    local value = stat.get(record)

    if stat.kind == "number" then return compareNumber(value, cond.op, cond.value) end
    if stat.kind == "rank" then return compareRank(cond.stat, value, cond.op, cond.value) end
    if stat.kind == "choice" then return compareChoice(value, cond.op, cond.value) end
    if stat.kind == "text" then return compareText(value, cond.op, cond.value) end
    if stat.kind == "flag" then return (value == true) == (cond.value == true) end

    return false
end

-- Whether every condition holds. An empty list matches everything, which is what a filter
-- with nothing filled in should do - and why a rule with no conditions is refused below
-- rather than being allowed to mark an entire inventory as trash.
function ItemRules.matches(record, conditions)
    for _, cond in ipairs(conditions or {}) do
        if not ItemRules.holds(record, cond) then return false end
    end

    return true
end

-- #### RULES #### --

ItemRules.MARKS = {trash = true, favorite = true, keep = true}

-- One rule of the trash manager.
local function rule(spec, position)
    local where = string.format("'rules[%d]'", position)

    if type(spec) ~= "table" then fail(where .. " must be an object.") end

    local name = cleanName(spec.name)
    if not name then
        fail(string.format("%s needs a 'name' of 1 to %d characters.", where,
                           ItemRules.MAX_NAME))
    end

    local mark = type(spec.mark) == "string" and string.lower(spec.mark) or nil
    if not mark or not ItemRules.MARKS[mark] then
        fail(string.format("%s: 'mark' is trash, favorite or keep.", where))
    end

    local conditions = ItemRules.conditions(spec.conditions, where .. ".conditions")

    -- A rule that matches everything is almost certainly a mistake, and the one mistake
    -- whose consequences are an inventory of several hundred items all marked at once.
    -- "keep" is exempt: a catch-all keep rule at the bottom is a reasonable way to say
    -- "and nothing else".
    if #conditions == 0 and mark ~= "keep" then
        fail(string.format("%s has no conditions, so it would mark every item in the "
                           .. "inventory. Give it at least one.", where))
    end

    return
    {
        name = name,
        mark = mark,
        enabled = spec.enabled ~= false,
        conditions = conditions,
    }
end

-- The whole stored ruleset, validated and normalised.
function ItemRules.ruleset(spec)
    if type(spec) ~= "table" then fail("A ruleset is an object with 'rules'.") end

    local rules = spec.rules
    if rules == nil then rules = {} end
    if type(rules) ~= "table" then fail("'rules' is a list.") end

    if #rules > ItemRules.MAX_RULES then
        fail(string.format("A ruleset holds at most %d rules.", ItemRules.MAX_RULES))
    end

    local out = Json.array({})
    local seen = {}

    for position, entry in ipairs(rules) do
        local parsed = rule(entry, position)

        if seen[string.lower(parsed.name)] then
            fail(string.format("Two rules are called '%s'.", parsed.name))
        end
        seen[string.lower(parsed.name)] = true

        out[#out + 1] = parsed
    end

    return
    {
        enabled = spec.enabled == true,
        -- Whether the sweeper is allowed to take a mark back off an item that no longer
        -- matches any rule. Off by default: a player who marked something by hand did so
        -- on purpose, and a sweeper that quietly undoes it is worse than one that does
        -- too little.
        restore = spec.restore == true,
        -- Items the player favourited are never touched, which is not configurable. This
        -- is the weaker sibling: skip anything already marked by hand at all, so the
        -- sweeper only ever decides about items nobody has had an opinion on.
        skipTagged = spec.skipTagged == true,
        rules = out,
    }
end

-- The ruleset an owner has before they save one.
function ItemRules.emptyRuleset()
    return {enabled = false, restore = false, skipTagged = false, rules = Json.array({}),
            revision = 0}
end

-- #### DECIDING #### --

-- What the trash manager wants done with one item: "trash", "favorite", "keep", or nil
-- for "no rule had an opinion". Also returns the rule that decided, for the log.
--
-- Two things are never decided here, whatever the rules say:
--
--   * a favourited item is left alone. Favourite is the player saying "not this one", and
--     a rule that overrode it would make the flag useless.
--   * a mission-relevant item is left alone. Those are quest items; the game hides them
--     from selling for a reason, and marking one trash points the research station and
--     the scrapyard straight at it.
function ItemRules.decide(record, ruleset)
    if record.favorite then return nil, nil, "favorite" end
    if record.missionRelevant then return nil, nil, "missionRelevant" end

    if ruleset.skipTagged and record.trash then return nil, nil, "alreadyTagged" end

    for _, entry in ipairs(ruleset.rules or {}) do
        if entry.enabled ~= false and ItemRules.matches(record, entry.conditions) then
            return entry.mark, entry.name
        end
    end

    return nil, nil, "noMatch"
end

-- The tag pair an item should end up with, or nil if it should be left exactly as it is.
--
-- This is where `restore` lives: without it a decision only ever adds a mark, so loosening
-- a threshold leaves yesterday's marks in place and a rule can never un-trash anything.
function ItemRules.target(record, ruleset)
    local mark, ruleName, reason = ItemRules.decide(record, ruleset)

    if mark == "trash" then
        if record.trash then return nil, ruleName, "already trash" end
        return {favorite = false, trash = true}, ruleName, "marked trash"
    end

    if mark == "favorite" then
        if record.favorite then return nil, ruleName, "already favorite" end
        return {favorite = true, trash = false}, ruleName, "marked favorite"
    end

    -- "keep" is an explicit exception and a no-match is simply silence. Both only do
    -- something when the sweeper is allowed to take marks back off.
    if ruleset.restore and record.trash and reason ~= "favorite"
       and reason ~= "missionRelevant" then
        return {favorite = false, trash = false}, ruleName, "mark removed"
    end

    return nil, ruleName, reason
end

return ItemRules
