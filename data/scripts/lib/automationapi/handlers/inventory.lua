-- The inventory endpoints, and the trash manager that runs behind them.
--
--   GET  /inventory                 the caller's items, filtered, sorted and paged
--   POST /inventory/search          the same, with the full condition vocabulary
--   GET  /inventory/stats           facet counts, for a console building its filters
--   GET  /inventory/vocabulary      every stat, operator and value name the API knows
--   POST /inventory/tags            set favourite/trash on named slots
--   GET  /inventory/trash           the trash rules and what the sweeper has been doing
--   POST /inventory/trash           save the rules
--   POST /inventory/trash/preview   what the rules would do, changing nothing
--   POST /inventory/trash/run       sweep now rather than at the next interval
--
-- Why the sweeper exists, and why it is built the way it is:
--
-- Marking an inventory's worth of junk as trash is a loop over a few hundred items with a
-- setItemTags per item, and done the obvious way it is also a loop that runs inside one
-- server tick. The server has nothing else to do for its duration, and on a late-game
-- inventory that is long enough for everyone in the galaxy to notice.
--
-- So this one never does the obvious thing. A pass is started at most every
-- Config.trashSweepInterval, and it only ever takes the list of occupied slot numbers in
-- the tick that starts it. Describing an item - which is where the cost is, around thirty
-- engine property reads each - and writing its tags happen afterwards, a few per tick,
-- bounded by Config.trashSweepItemsPerTick and Config.trashSweepWritesPerTick. A pass
-- over a thousand items takes a few seconds of wall clock and a sliver of each tick in
-- between. It is meant to be slow. Nothing is waiting for it.
--
-- Each slot is re-read at the moment it is written, so a pass that started before an item
-- was sold or moved does not mark whatever landed in its slot afterwards. See
-- Items.setTags.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Serialize = include("automationapi/serialize")
local Config = include("automationapi/config")
local Owner = include("automationapi/owner")
local Items = include("automationapi/items")
local ItemRules = include("automationapi/itemrules")

local InventoryHandler = {}

local function now()
    return Server().unpausedRuntime
end

local function sortedKeys(t)
    local keys = {}
    for key, _ in pairs(t) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

-- #### STORE #### --
--
-- One ruleset per owning faction, kept as a Server value for the reasons the mission
-- rules and programs are: the galaxy bridge reads them with nobody logged in, they
-- survive a restart, and an alliance's ruleset is one document every member shares.

-- factionIndex -> {raw, data}, keyed on the raw string so a value changed underneath is
-- noticed rather than served stale.
local cache = {}

local function valueKey(index)
    return Config.trashRulesValuePrefix .. tostring(index)
end

-- The index is read on every tick of the sweeper, so the decode is cached on the raw
-- string: the list changes only when somebody saves a ruleset, and parsing it five times
-- a second forever to learn that is work for nothing.
local indexCache = {raw = false, list = {}}

local function factionIndices()
    local raw = Server():getValue(Config.trashRulesIndexValue)
    if indexCache.raw == raw then return indexCache.list end

    local list = type(raw) == "string" and Json.decode(raw) or nil

    local result = {}
    for _, index in ipairs(type(list) == "table" and list or {}) do
        if type(index) == "number" then result[#result + 1] = index end
    end

    indexCache = {raw = raw, list = result}

    return result
end

local function loadRules(index)
    local raw = Server():getValue(valueKey(index))

    local cached = cache[index]
    if cached and cached.raw == raw then return cached.data end

    local data
    if type(raw) == "string" and raw ~= "" then
        local decoded = Json.decode(raw)
        if type(decoded) == "table" and type(decoded.rules) == "table" then data = decoded end
    end

    data = data or ItemRules.emptyRuleset()
    data.rules = data.rules or Json.array({})
    data.revision = data.revision or 0

    cache[index] = {raw = raw, data = data}

    return data
end

local function saveRules(index, data)
    -- A ruleset with nothing in it and nothing turned on is the same as never having had
    -- one, and removing it keeps the sweeper's index down to the factions it has work for.
    local empty = #data.rules == 0 and not data.enabled

    local raw
    if not empty then
        local encoded, err = Json.encode(data)
        if not encoded then
            Router.fail(500, "encoding_failed", "Could not store the rules: " .. tostring(err))
        end
        raw = encoded
    end

    Server():setValue(valueKey(index), raw)
    cache[index] = {raw = raw, data = data}

    local indices = factionIndices()
    local present, kept = false, Json.array({})

    for _, existing in ipairs(indices) do
        if existing == index then
            present = true
            if not empty then kept[#kept + 1] = existing end
        else
            kept[#kept + 1] = existing
        end
    end

    if not present and not empty then kept[#kept + 1] = index end

    if #kept ~= #indices or not present then
        Server():setValue(Config.trashRulesIndexValue,
                          #kept > 0 and Json.encode(kept) or nil)
    end
end

-- #### OWNERS #### --

-- The sweeper has an index and nothing else. findFaction says which kind it is; the
-- Player or Alliance by that number is what actually carries getInventory().
local function ownerOf(index)
    local function attempt(fn)
        local ok, found = pcall(fn)
        return ok and found or nil
    end

    local found = attempt(function() return Galaxy():findFaction(index) end)
    if not found then return nil end

    local isAlliance = found.isAlliance == true
    local faction = isAlliance and attempt(function() return Alliance(index) end)
                    or not isAlliance and attempt(function() return Player(index) end)
                    or found

    if not faction then return nil end

    return
    {
        faction = faction,
        index = index,
        kind = isAlliance and "alliance" or "player",
        name = Serialize.string(faction.name, ""),
    }
end

-- #### SWEEP STATE #### --

-- factionIndex -> what the sweeper is doing and what it last did. In memory only: a pass
-- interrupted by a restart is simply started again, and the log is a debugging aid rather
-- than a record anyone should be able to rely on.
local sweeps = {}

-- Round-robin position in the faction index, so one faction partway through a long pass
-- does not keep the others waiting forever.
local rotation = 0

local function sweepOf(index)
    local state = sweeps[index]

    if not state then
        state =
        {
            phase = "idle",
            since = now(),
            nextAt = 0,
            cursor = 0,
            pending = {},
            counts = {scanned = 0, marked = 0, restored = 0, skipped = 0, failed = 0},
            passes = 0,
            log = {},
        }
        sweeps[index] = state
    end

    return state
end

local function note(state, message, detail)
    state.log[#state.log + 1] = {at = now(), message = message, detail = detail}

    local overflow = #state.log - Config.trashSweepLogSize
    if overflow > 0 then
        local trimmed = {}
        for i = overflow + 1, #state.log do trimmed[#trimmed + 1] = state.log[i] end
        state.log = trimmed
    end
end

-- #### APPLYING A DECISION #### --

-- Carries out whatever the ruleset decided for one record, if anything. Returns "marked",
-- "restored", "skipped" or "failed", plus a line for the log when something happened.
local function apply(inventory, record, ruleset)
    local target, ruleName, reason = ItemRules.target(record, ruleset)

    if not target then return "skipped", nil, reason end

    local ok, outcome = Items.setTags(inventory, record.index, target.favorite, target.trash,
                                      {name = record.name,
                                       rarity = record.rarity and record.rarity.type})

    if not ok then
        return "failed", string.format("%s: could not be tagged (%s)",
                                       record.name or "?", tostring(outcome)), reason
    end

    if outcome == "unchanged" then return "skipped", nil, reason end

    -- Neither flag set is the sweeper taking a mark back off, which is the only thing
    -- `restore` ever does and is counted apart from marking so a pass that undoes
    -- yesterday's rules is readable as that.
    local marking = target.trash or target.favorite
    local what = target.trash and "trash" or (target.favorite and "favorite" or "untagged")

    return marking and "marked" or "restored",
           string.format("%s -> %s%s", record.name or "?", what,
                         ruleName and (" (" .. ruleName .. ")") or ""),
           reason
end

-- #### THE PASS #### --

-- Begins a pass: one getItems() and nothing else. The slot numbers are kept and every
-- item is looked up again as its turn comes, so the engine objects are never held across
-- a tick boundary.
local function startPass(index, ruleset)
    local state = sweepOf(index)
    local owner = ownerOf(index)

    if not owner then
        state.nextAt = now() + Config.trashSweepInterval
        state.message = "The faction this ruleset belongs to no longer exists."
        return
    end

    local ok, inventory = pcall(Items.open, owner.faction)
    if not ok or not inventory then
        state.nextAt = now() + Config.trashSweepInterval
        state.message = "The inventory could not be read."
        note(state, state.message)
        return
    end

    local okIndices, indices = pcall(Items.indices, inventory)
    if not okIndices then
        state.nextAt = now() + Config.trashSweepInterval
        state.message = "The inventory could not be listed."
        note(state, state.message)
        return
    end

    state.phase = "running"
    state.since = now()
    state.startedAt = now()
    state.cursor = 0
    state.pending = indices
    state.counts = {scanned = 0, marked = 0, restored = 0, skipped = 0, failed = 0}
    state.ownerName = owner.name
    state.message = string.format("Looking over %d items.", #indices)
end

-- One tick's worth of a running pass. Stops on either budget, and leaves the rest for the
-- next tick; nothing here loops until it is done.
local function stepPass(index, ruleset)
    local state = sweepOf(index)
    local owner = ownerOf(index)

    if not owner then
        state.phase = "idle"
        state.nextAt = now() + Config.trashSweepInterval
        return
    end

    local ok, inventory = pcall(Items.open, owner.faction)
    if not ok or not inventory then
        state.phase = "idle"
        state.nextAt = now() + Config.trashSweepInterval
        state.message = "The inventory could not be read."
        return
    end

    local scanned, written = 0, 0

    while state.cursor < #state.pending do
        if scanned >= Config.trashSweepItemsPerTick then break end
        if written >= Config.trashSweepWritesPerTick then break end

        state.cursor = state.cursor + 1
        scanned = scanned + 1

        local slot = state.pending[state.cursor]
        local record = Items.at(inventory, slot)

        state.counts.scanned = state.counts.scanned + 1

        if record then
            local outcome, line = apply(inventory, record, ruleset)

            if outcome == "marked" then
                state.counts.marked = state.counts.marked + 1
                written = written + 1
            elseif outcome == "restored" then
                state.counts.restored = state.counts.restored + 1
                written = written + 1
            elseif outcome == "failed" then
                state.counts.failed = state.counts.failed + 1
            else
                state.counts.skipped = state.counts.skipped + 1
            end

            if line then note(state, line) end
        else
            -- The slot emptied between the listing and now. Normal, not worth a log line.
            state.counts.skipped = state.counts.skipped + 1
        end
    end

    if state.cursor >= #state.pending then
        state.phase = "idle"
        state.since = now()
        state.nextAt = now() + Config.trashSweepInterval
        state.passes = state.passes + 1
        state.pending = {}
        state.finishedAt = now()
        state.lastPass =
        {
            at = now(),
            duration = state.startedAt and (now() - state.startedAt) or 0,
            scanned = state.counts.scanned,
            marked = state.counts.marked,
            restored = state.counts.restored,
            failed = state.counts.failed,
        }

        state.message = string.format("%d items looked at, %d marked, %d unmarked.",
                                      state.counts.scanned, state.counts.marked,
                                      state.counts.restored)

        if state.counts.marked > 0 or state.counts.restored > 0 or state.counts.failed > 0 then
            note(state, state.message)
        end
    else
        state.message = string.format("%d of %d items looked at.", state.cursor,
                                      #state.pending)
    end
end

-- Called from the bridge's update loop. Everything it does is bounded by the budgets in
-- Config; a tick in which nothing is due costs one Server value read per faction with
-- rules, and factions with none are not in the index at all.
function InventoryHandler.tick()
    local indices = factionIndices()
    if #indices == 0 then return end

    local handled = 0

    -- Passes already under way come first, and are found by looking rather than waiting
    -- for a turn: a faction partway through a sweep must not advance once per lap of a
    -- rotation that could be fifty factions long. Finding them is a table lookup each;
    -- nothing here reads a Server value for a faction that is not working.
    for _, index in ipairs(indices) do
        if handled >= Config.trashSweepFactionsPerTick then break end

        local state = sweeps[index]

        if state and state.phase == "running" then
            local ruleset = loadRules(index)

            -- A ruleset turned off mid-pass stops it where it stands rather than
            -- finishing a sweep nobody wants any more.
            if not ruleset.enabled then
                state.phase = "idle"
                state.pending = {}
                state.message = "Turned off partway through a pass."
            else
                stepPass(index, ruleset)
            end

            handled = handled + 1
        end
    end

    if handled >= Config.trashSweepFactionsPerTick then return end

    -- Then one idle faction per tick, in rotation, to see whether its next pass is due.
    -- Asking costs a Server value read, and asking every faction on every tick is exactly
    -- the per-tick cost that grows with how popular the feature is.
    rotation = rotation % #indices + 1

    local index = indices[rotation]
    local state = sweeps[index]

    if state and state.phase == "running" then return end

    local ruleset = loadRules(index)
    if ruleset.enabled and now() >= ((state and state.nextAt) or 0) then
        startPass(index, ruleset)
    end
end

-- #### REQUEST HELPERS #### --

local function queryNumber(ctx, name)
    local raw = ctx.query[name]
    if raw == nil then return nil end

    local value = tonumber(raw)
    if value == nil then
        Router.fail(400, "bad_query", "'" .. name .. "' must be a number.")
    end

    return value
end

local function queryInteger(ctx, name, default, min, max)
    local value = queryNumber(ctx, name)
    if value == nil then return default end

    value = math.floor(value)
    if min and value < min then value = min end
    if max and value > max then value = max end

    return value
end

-- The simple query-string filters of GET /inventory, expressed in the same vocabulary the
-- full condition list uses. There is nothing here POST /inventory/search cannot say; this
-- is the shape that fits in a URL.
local function queryConditions(ctx)
    local conditions = Json.array({})

    local function add(stat, op, value)
        conditions[#conditions + 1] = ItemRules.condition({stat = stat, op = op, value = value},
                                                          "'" .. stat .. "'")
    end

    if ctx.query.type then add("type", "is", ctx.query.type) end
    if ctx.query.category then add("category", "is", ctx.query.category) end
    if ctx.query.slotType then add("slotType", "is", ctx.query.slotType) end
    if ctx.query.damageType then add("damageType", "is", ctx.query.damageType) end
    if ctx.query.material then add("material", "atLeast", ctx.query.material) end
    if ctx.query.rarityMin then add("rarity", "atLeast", ctx.query.rarityMin) end
    if ctx.query.rarityMax then add("rarity", "atMost", ctx.query.rarityMax) end
    if ctx.query.search then add("name", "contains", ctx.query.search) end

    local dpsMin = queryNumber(ctx, "dpsMin")
    local dpsMax = queryNumber(ctx, "dpsMax")
    if dpsMin then add("dps", "atLeast", dpsMin) end
    if dpsMax then add("dps", "atMost", dpsMax) end

    local techMin = queryNumber(ctx, "techMin")
    if techMin then add("tech", "atLeast", techMin) end

    -- One switch for the three states a player actually sorts by, since "favorite=false"
    -- and "untagged" are different questions and both get asked.
    local tag = ctx.query.tag
    if tag == "favorite" then
        add("favorite", "is", true)
    elseif tag == "trash" then
        add("trash", "is", true)
    elseif tag == "untagged" then
        add("favorite", "is", false)
        add("trash", "is", false)
    elseif tag ~= nil then
        Router.fail(400, "bad_query", "'tag' is favorite, trash or untagged.")
    end

    return conditions
end

-- Sorting is over the same stats a condition names, so anything that can be filtered on
-- can be ordered by. A record missing the stat sorts last whichever way the order runs:
-- a system upgrade has no dps, and it does not belong at the top of a list sorted by it.
local function sortRecords(records, statName, descending)
    if not statName then return end

    local stat = ItemRules.STATS[statName]
    if not stat then
        Router.fail(400, "bad_sort", "Nothing can be sorted by '" .. tostring(statName) .. "'.",
                    {stats = Json.array(sortedKeys(ItemRules.STATS))})
    end

    -- Decorated, because stat.get is a function call per comparison otherwise and
    -- table.sort makes a great many comparisons.
    local keyed = {}
    for position, record in ipairs(records) do
        local value = stat.get(record)
        if type(value) == "boolean" then value = value and 1 or 0 end
        keyed[position] = {record = record, key = value, position = position}
    end

    table.sort(keyed, function(a, b)
        if a.key == nil and b.key == nil then return a.position < b.position end
        if a.key == nil then return false end
        if b.key == nil then return true end

        if a.key == b.key then return a.position < b.position end
        if descending then return a.key > b.key end
        return a.key < b.key
    end)

    for position, entry in ipairs(keyed) do records[position] = entry.record end
end

local function page(records, ctx)
    local pageSize = queryInteger(ctx, "pageSize", Config.defaultPageSize, 1, Config.maxPageSize)
    local pageNumber = queryInteger(ctx, "page", 1, 1)

    local first = (pageNumber - 1) * pageSize + 1
    local out = Json.array({})

    for position = first, math.min(first + pageSize - 1, #records) do
        out[#out + 1] = records[position]
    end

    return out, pageNumber, pageSize
end

-- Reads an owner's inventory and narrows it. Shared by the listing, the search and the
-- facet counts, so all three agree about what "the caller's items" means.
local function gather(ctx, owner, conditions)
    local records, summary = Items.read(owner.faction, Config.maxInventorySlots)

    if #conditions == 0 then return records, summary, records end

    local matching = {}
    for _, record in ipairs(records) do
        if ItemRules.matches(record, conditions) then matching[#matching + 1] = record end
    end

    return matching, summary, records
end

local function respond(ctx, owner, matching, summary)
    sortRecords(matching, ctx.query.sort, ctx.query.order == "desc")

    local items, pageNumber, pageSize = page(matching, ctx)

    return
    {
        owner = Owner.describe(owner),
        inventory = summary,
        matched = #matching,
        page = pageNumber,
        pageSize = pageSize,
        items = Json.array(items),
    }
end

-- #### TAGS #### --

-- Writing tags on alliance property is spending the alliance's things, which is the
-- privilege vanilla's own shop checks before it cycles an item's tags.
local TAG_PRIVILEGE = "SpendItems"

local function tagPrivilege()
    local ok, value = pcall(function() return AlliancePrivilege[TAG_PRIVILEGE] end)
    return ok and value or nil
end

-- #### ENDPOINTS #### --

function InventoryHandler.register(router)

    router:get("/inventory", function(ctx)
        local owner = Owner.resolve(ctx)
        local matching, summary = gather(ctx, owner, queryConditions(ctx))

        return respond(ctx, owner, matching, summary)
    end)

    -- The same listing, with conditions that do not fit in a query string. Everything
    -- else - sort, order, page - stays in the query, so one of these can be paged through
    -- without resending the filter.
    router:post("/inventory/search", function(ctx)
        local owner = Owner.resolve(ctx)
        local conditions = ItemRules.conditions(ctx.body.conditions)
        local matching, summary = gather(ctx, owner, conditions)

        local response = respond(ctx, owner, matching, summary)
        response.conditions = conditions

        return response
    end)

    -- What is in there, counted by the things a filter can narrow on. Cheaper for a
    -- console to ask for than a full listing it would have to count itself, and it is
    -- what tells it which filters are worth offering at all.
    router:get("/inventory/stats", function(ctx)
        local owner = Owner.resolve(ctx)
        local records, summary = Items.read(owner.faction, Config.maxInventorySlots)

        local facets = Items.summarize(records)
        facets.inventory = summary
        facets.owner = Owner.describe(owner)

        return facets
    end)

    -- The vocabulary itself. A client that reads this can build a filter or a rule
    -- builder without a list of stat names compiled into it, and will not offer a
    -- comparison the server would reject.
    router:get("/inventory/vocabulary", function(ctx)
        return
        {
            stats = ItemRules.vocabulary(),
            marks = Json.array({"trash", "favorite", "keep"}),
            types = Json.array(Items.TYPE_NAMES),
            rarities = Json.array(Items.RARITY_NAMES),
            materials = Json.array(Items.MATERIAL_NAMES),
            maxRules = ItemRules.MAX_RULES,
            maxConditions = ItemRules.MAX_CONDITIONS,
        }
    end)

    -- Setting tags by hand, in a batch. Every slot answers for itself: an item that moved
    -- since the caller listed it is reported as such rather than failing the request, so
    -- a console marking thirty items does not lose the other twenty-nine to one stale row.
    router:post("/inventory/tags", function(ctx)
        local owner = Owner.resolve(ctx, {privilege = tagPrivilege()})

        local requested = ctx.body.items
        local mark = ctx.body.mark

        -- Two shapes, because the two things a client does are different: "mark these
        -- thirty as trash" and "this one is a favourite now".
        if requested == nil and type(ctx.body.indices) == "table" then
            if type(mark) ~= "string" or
               (mark ~= "trash" and mark ~= "favorite" and mark ~= "none") then
                Router.fail(400, "bad_mark", "'mark' is trash, favorite or none.")
            end

            requested = {}
            for _, index in ipairs(ctx.body.indices) do
                requested[#requested + 1] =
                {
                    index = index,
                    trash = mark == "trash",
                    favorite = mark == "favorite",
                }
            end
        end

        if type(requested) ~= "table" or #requested == 0 then
            Router.fail(400, "no_items",
                        "Send 'items' as a list of {index, favorite, trash}, or 'indices' "
                        .. "plus a 'mark'.")
        end

        if #requested > Config.maxPageSize then
            Router.fail(400, "too_many_items",
                        string.format("At most %d slots in one call.", Config.maxPageSize))
        end

        local inventory = Items.open(owner.faction)

        local results = Json.array({})
        local changed = 0

        for _, entry in ipairs(requested) do
            local index = type(entry) == "table" and tonumber(entry.index) or nil

            if index == nil or index ~= math.floor(index) then
                results[#results + 1] = {index = Json.null, ok = false, reason = "bad_index"}
            else
                local record = Items.at(inventory, index)

                if not record then
                    results[#results + 1] = {index = index, ok = false, reason = "gone"}
                else
                    -- An unstated flag keeps whatever the item already had: a client that
                    -- only wants to favourite something should not have to know, and
                    -- resend, its trash flag.
                    local favorite = entry.favorite
                    local trash = entry.trash

                    if type(favorite) ~= "boolean" then favorite = record.favorite end
                    if type(trash) ~= "boolean" then trash = record.trash end

                    -- The engine stores both flags but the game only ever shows one. Two
                    -- at once is a state nothing in the UI can represent, so the one the
                    -- caller just asked for wins.
                    if favorite and trash then
                        if entry.trash == true then favorite = false else trash = false end
                    end

                    local ok, outcome = Items.setTags(inventory, index, favorite, trash,
                                                      ctx.body.strict ~= false
                                                      and {name = record.name} or nil)

                    if ok and outcome ~= "unchanged" then changed = changed + 1 end

                    results[#results + 1] =
                    {
                        index = index,
                        ok = ok,
                        name = record.name,
                        favorite = favorite,
                        trash = trash,
                        reason = ok and outcome or tostring(outcome),
                    }
                end
            end
        end

        return {owner = Owner.describe(owner), changed = changed, results = results}
    end)

    -- #### THE TRASH MANAGER #### --

    local function describeSweep(index)
        local state = sweeps[index]
        if not state then return {phase = "idle", message = "Nothing has run yet."} end

        local log = Json.array({})
        for _, entry in ipairs(state.log) do log[#log + 1] = entry end

        return
        {
            phase = state.phase,
            message = state.message,
            since = state.since,
            passes = state.passes,
            -- Seconds until the next pass, which is what a console wants to show. Negative
            -- would mean "overdue", and overdue by a tick is not news.
            nextIn = state.phase == "running" and 0
                     or math.max(0, (state.nextAt or 0) - now()),
            progress = state.phase == "running"
                       and {done = state.cursor, total = #state.pending} or nil,
            counts = state.counts,
            lastPass = state.lastPass,
            log = log,
        }
    end

    router:get("/inventory/trash", function(ctx)
        local owner = Owner.resolve(ctx)
        local ruleset = loadRules(owner.index)

        return
        {
            owner = Owner.describe(owner),
            enabled = ruleset.enabled == true,
            restore = ruleset.restore == true,
            skipTagged = ruleset.skipTagged == true,
            rules = Json.array(ruleset.rules),
            revision = ruleset.revision or 0,
            updatedBy = ruleset.updatedBy,
            updatedAt = ruleset.updatedAt,
            interval = Config.trashSweepInterval,
            -- The sweep log is stamped with the server's own runtime clock, which means
            -- nothing to a client until it knows what that clock reads now.
            now = now(),
            sweep = describeSweep(owner.index),
        }
    end)

    -- Saves the whole ruleset at once. Rules are ordered and the order is what decides,
    -- so there is no sensible way to change one of them in isolation.
    router:post("/inventory/trash", function(ctx)
        local owner = Owner.resolve(ctx, {privilege = tagPrivilege()})
        local previous = loadRules(owner.index)

        if ctx.body.ifRevision ~= nil then
            local current = previous.revision or 0
            if ctx.body.ifRevision ~= current then
                Router.fail(409, "rules_changed",
                            "Someone changed these rules since you loaded them. Reload and "
                            .. "apply your change again.",
                            {revision = current})
            end
        end

        local ruleset = ItemRules.ruleset(ctx.body)

        ruleset.revision = (previous.revision or 0) + 1
        ruleset.updatedBy = {index = ctx.playerIndex, name = Serialize.string(ctx.player.name, "")}
        ruleset.updatedAt = os.time()

        saveRules(owner.index, ruleset)

        -- Turning the manager on should do something now rather than in two minutes. A
        -- pass already running keeps going; it is reading the new rules either way.
        local state = sweepOf(owner.index)
        if ruleset.enabled and state.phase ~= "running" then state.nextAt = 0 end

        return
        {
            owner = Owner.describe(owner),
            enabled = ruleset.enabled,
            restore = ruleset.restore,
            skipTagged = ruleset.skipTagged,
            rules = Json.array(ruleset.rules),
            revision = ruleset.revision,
            sweep = describeSweep(owner.index),
        }
    end)

    -- What the rules would do to the inventory as it stands, without touching anything.
    -- The one endpoint a player should use before turning the manager on, so it reports
    -- each item's verdict and the rule that reached it rather than a count.
    router:post("/inventory/trash/preview", function(ctx)
        local owner = Owner.resolve(ctx)

        -- Preview the rules in the body if there are any, otherwise the stored ones. The
        -- first is what a console does while someone is still editing a threshold.
        local ruleset
        if ctx.body.rules ~= nil then
            ruleset = ItemRules.ruleset(ctx.body)
        else
            ruleset = loadRules(owner.index)
        end

        local records, summary = Items.read(owner.faction, Config.maxInventorySlots)

        local changes = Json.array({})
        local counts = {trash = 0, favorite = 0, restore = 0, unchanged = 0}

        for _, record in ipairs(records) do
            local target, ruleName = ItemRules.target(record, ruleset)

            if target then
                local what = target.trash and "trash"
                             or (target.favorite and "favorite" or "restore")
                counts[what] = counts[what] + 1

                changes[#changes + 1] =
                {
                    index = record.index,
                    name = record.name,
                    type = record.type,
                    rarity = record.rarity and record.rarity.name,
                    dps = record.dps,
                    amount = record.amount,
                    was = {favorite = record.favorite, trash = record.trash},
                    becomes = what,
                    rule = ruleName,
                }
            else
                counts.unchanged = counts.unchanged + 1
            end
        end

        local shown, pageNumber, pageSize = page(changes, ctx)

        return
        {
            owner = Owner.describe(owner),
            inventory = summary,
            enabled = ruleset.enabled == true,
            counts = counts,
            changes = Json.array(shown),
            total = #changes,
            page = pageNumber,
            pageSize = pageSize,
        }
    end)

    -- Brings the next pass forward. It still runs in the background at the same pace; the
    -- answer is what the sweeper is doing, not what it did.
    router:post("/inventory/trash/run", function(ctx)
        local owner = Owner.resolve(ctx, {privilege = tagPrivilege()})
        local ruleset = loadRules(owner.index)

        if not ruleset.enabled then
            Router.fail(409, "trash_disabled",
                        "The trash manager is turned off for this faction. Save the rules "
                        .. "with 'enabled' set first.")
        end

        local state = sweepOf(owner.index)
        if state.phase ~= "running" then state.nextAt = 0 end

        return 202, {owner = Owner.describe(owner), sweep = describeSweep(owner.index)}
    end)
end

-- Test seam: the sweeper's state is in memory, and a test that drives two passes has to
-- be able to put it back the way it found it.
function InventoryHandler.reset()
    sweeps = {}
    cache = {}
    indexCache = {raw = false, list = {}}
    rotation = 0
end

return InventoryHandler
