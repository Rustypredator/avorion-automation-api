-- Mission automation rules: which ways of sending a ship out are worth trying, what each
-- would cost, earn and risk, and whether it stays inside the limits the owner set.
--
-- Pure Lua with no game dependencies. The handler feeds it the game's own predictions, so
-- everything here is arithmetic over numbers the order window would show - which keeps it
-- testable outside the game and keeps the rules honest: a limit is checked against exactly
-- the figure a player would have read before clicking start.
--
-- The vanilla facts these rules lean on, all read out of data/scripts/player/background/
-- simulation/*command.lua (2.5.x):
--
--   * attack chance is a fraction, rounded to 0.01, and a table {value} on most commands
--     but a bare number on refine, supply and maintenance
--   * mine and salvage take their duration in hours, expedition in minutes; everything
--     else predicts its own duration in seconds
--   * trade's "the customer gets impatient" is not a mood, it is a dice roll: once a
--     contract has flown three flights, each further flight ends it early with a 35% chance
--     (TradeCommand:update). The captain's warnings are pinned to flights > 3, > 5 and > 10.
--   * a bigger trade deposit means fewer flights, but past a richness-scaled threshold it
--     lengthens the attack window from one hour towards three, so flights and ambush chance
--     pull against each other - that is the search the trade candidates exist for
--   * a trade area analysis offers at most four routes (TradeCommand:onAreaAnalysisFinished
--     picks the best by profit, profit per volume and margin), and a route a contract just
--     flew is hidden for two hours. Which stations fall inside the area decides the four, so
--     one area around the ship often has nothing left worth flying - that is what a sweep,
--     the same area laid around the ship nine ways at every shape, is for

local Router = include("automationapi/router")
local Json = include("automationapi/json")

local MissionRules = {}

-- #### VOCABULARY #### --

-- What a rule can rank by. `priorities` orders any of these, each breaking the ties of the
-- one before it; `objective` is the first of them, and a rule that only names an objective
-- ranks by that alone.
MissionRules.criteria =
{
    hourly = true,          -- value per hour away
    total = true,           -- the biggest value
    safest = true,          -- the lowest ambush chance
    shortest = true,        -- the least time away
    fewestFlights = true,   -- trade: the fewest flights, the least chance the customer walks
    cheapest = true,        -- the smallest deposit or budget
}

MissionRules.objectives = MissionRules.criteria

MissionRules.criteriaList = {}
for name, _ in pairs(MissionRules.criteria) do MissionRules.criteriaList[#MissionRules.criteriaList + 1] = name end
table.sort(MissionRules.criteriaList)

-- Where a sweep lays the ship inside the area, as fractions of each side: 0 is the low
-- edge, 1 the high one. The console's trade scan tries the same nine.
MissionRules.placements =
{
    {fx = 0.5, fy = 0.5},
    {fx = 0, fy = 1}, {fx = 1, fy = 1}, {fx = 0, fy = 0}, {fx = 1, fy = 0},
    {fx = 0.5, fy = 1}, {fx = 0.5, fy = 0}, {fx = 0, fy = 0.5}, {fx = 1, fy = 0.5},
}

-- Missions a rule may repeat. The rest cannot be automated in any meaningful sense.
MissionRules.supported =
{
    mine = true, salvage = true, trade = true, expedition = true, scout = true,
    refine = true, sell = true, procure = true, maintenance = true,
}

local unsupportedReasons =
{
    travel = "A travel mission ends somewhere else, so there is nothing to repeat.",
    supply = "A supply loop never finishes on its own, so there is nothing to repeat.",
    escort = "Escort is attached by the game to ships escorting another mission.",
}

-- Every limit a rule understands. Durations are seconds and chances are fractions, for
-- every mission alike; the per-mission units are translated in metrics() below.
local limitSpecs =
{
    maxAttackChance = {min = 0, max = 1},
    maxDuration     = {min = 0},
    minDuration     = {min = 0},
    maxFlights      = {min = 1, integer = true},
    maxDeposit      = {min = 0},
    minCreditsLeft  = {min = 0},
    minValue        = {min = 0},
}

MissionRules.limitNames = {}
for name, _ in pairs(limitSpecs) do MissionRules.limitNames[#MissionRules.limitNames + 1] = name end
table.sort(MissionRules.limitNames)

-- What happens after flight three: the contract survives each further flight with this
-- chance. TradeCommand:update rolls random():test(0.35) to end it.
MissionRules.TRADE_CONTINUE_CHANCE = 0.65
MissionRules.TRADE_SAFE_FLIGHTS = 3

-- Candidate caps. A candidate costs one prediction; a trade route is one open prediction
-- plus one per flight count tried.
local MAX_TRADE_FLIGHT_STEPS = 12
local MAX_TRADE_FLIGHTS = 40

-- #### HELPERS #### --

local function copy(value)
    if type(value) ~= "table" or value == Json.null then return value end

    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end

    return setmetatable(result, getmetatable(value))
end

MissionRules.copy = copy

local function shallow(t)
    local result = {}
    for k, v in pairs(t or {}) do result[k] = v end
    return result
end

-- {value = n}, {from, to} or a bare number, as the game hands predictions over.
local function scalar(field)
    if type(field) == "number" then return field end
    if type(field) ~= "table" then return nil end
    if type(field.value) == "number" then return field.value end
    if type(field.to) == "number" then return field.to end
    return nil
end

local function isNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function stringList(value, field)
    if value == nil or value == Json.null then return nil end

    if type(value) ~= "table" then
        Router.fail(400, "bad_rule", "'" .. field .. "' must be an array of names.")
    end

    local result = Json.array({})
    for _, entry in ipairs(value) do
        if type(entry) ~= "string" then
            Router.fail(400, "bad_rule", "'" .. field .. "' must be an array of names.")
        end
        result[#result + 1] = entry
    end

    return result
end

-- #### VALIDATION #### --

local function normalizeSize(size, field)
    if type(size) ~= "table" or not isNumber(size.x) or not isNumber(size.y) then
        Router.fail(400, "bad_rule", "'" .. field .. "' must be {x, y}.")
    end
    return {x = math.floor(size.x), y = math.floor(size.y)}
end

local function normalizeArea(area, mission)
    if area == nil or area == Json.null then
        -- A trade rule is only as good as the routes it gets to see, so it sweeps unless
        -- told otherwise.
        return {mode = mission == "trade" and "sweep" or "ship"}
    end

    if type(area) ~= "table" then
        Router.fail(400, "bad_rule", "'area' must be an object.")
    end

    local mode = area.mode or ((area.lower and area.upper) and "fixed" or "ship")

    if mode == "fixed" then
        local lower, upper = area.lower, area.upper
        if type(lower) ~= "table" or type(upper) ~= "table"
           or not isNumber(lower.x) or not isNumber(lower.y)
           or not isNumber(upper.x) or not isNumber(upper.y) then
            Router.fail(400, "bad_rule",
                        "A fixed area needs 'lower' and 'upper' as {x, y}.")
        end

        return
        {
            mode = "fixed",
            lower = {x = math.floor(lower.x), y = math.floor(lower.y)},
            upper = {x = math.floor(upper.x), y = math.floor(upper.y)},
        }
    end

    -- Every placement at every shape the captain allows, or at the shapes in `sizes`.
    if mode == "sweep" then
        local result = {mode = "sweep"}

        if area.sizes ~= nil and area.sizes ~= Json.null then
            if type(area.sizes) ~= "table" then
                Router.fail(400, "bad_rule", "'area.sizes' must be an array of {x, y}.")
            end
            result.sizes = Json.array({})
            for _, size in ipairs(area.sizes) do
                result.sizes[#result.sizes + 1] = normalizeSize(size, "area.sizes[]")
            end
            if #result.sizes == 0 then result.sizes = nil end
        end

        return result
    end

    if mode ~= "ship" then
        Router.fail(400, "bad_rule", "'area.mode' is 'ship', 'sweep' or 'fixed'.")
    end

    local result = {mode = "ship"}

    if area.size ~= nil and area.size ~= Json.null then
        result.size = normalizeSize(area.size, "area.size")
    end

    -- Where the ship sits inside the area, as a fraction of each side: 0 is the low edge,
    -- 1 the high one. The same placements the console's trade scan tries.
    if area.placement ~= nil and area.placement ~= Json.null then
        local p = area.placement
        if type(p) ~= "table" or not isNumber(p.fx) or not isNumber(p.fy)
           or p.fx < 0 or p.fx > 1 or p.fy < 0 or p.fy > 1 then
            Router.fail(400, "bad_rule", "'area.placement' must be {fx, fy}, each 0 to 1.")
        end
        result.placement = {fx = p.fx, fy = p.fy}
    end

    return result
end

local function normalizeLimits(limits)
    local result = {}
    if limits == nil or limits == Json.null then return result end

    if type(limits) ~= "table" then
        Router.fail(400, "bad_rule", "'limits' must be an object.")
    end

    for name, value in pairs(limits) do
        local spec = limitSpecs[name]
        if not spec then
            Router.fail(400, "bad_rule", "Unknown limit '" .. tostring(name) .. "'.",
                        {known = Json.array(shallow(MissionRules.limitNames))})
        end

        if value ~= Json.null then
            if not isNumber(value) then
                Router.fail(400, "bad_rule", "Limit '" .. name .. "' must be a number or null.")
            end
            if (spec.min and value < spec.min) or (spec.max and value > spec.max) then
                Router.fail(400, "bad_rule", string.format("Limit '%s' must be between %s and %s.",
                            name, tostring(spec.min or "-inf"), tostring(spec.max or "inf")))
            end
            if spec.integer then value = math.floor(value) end

            result[name] = value
        end
    end

    if result.minDuration and result.maxDuration and result.minDuration > result.maxDuration then
        Router.fail(400, "bad_rule", "'minDuration' is longer than 'maxDuration'.")
    end

    return result
end

local function normalizePriorities(value)
    if type(value) ~= "table" then
        Router.fail(400, "bad_rule", "'priorities' must be an array of criteria.",
                    {known = Json.array(shallow(MissionRules.criteriaList))})
    end

    local result, seen = Json.array({}), {}
    for _, name in ipairs(value) do
        if type(name) ~= "string" or not MissionRules.criteria[name] then
            Router.fail(400, "bad_rule", "Unknown priority '" .. tostring(name) .. "'.",
                        {known = Json.array(shallow(MissionRules.criteriaList))})
        end
        if seen[name] then
            Router.fail(400, "bad_rule", "Priority '" .. name .. "' is listed twice.")
        end
        seen[name] = true
        result[#result + 1] = name
    end

    if #result == 0 then
        Router.fail(400, "bad_rule", "'priorities' needs at least one criterion.")
    end

    return result
end

-- {prefer, avoid}: goods names, checked against the goods table by the handler, which has it.
local function normalizeGoods(value)
    if value == nil or value == Json.null then return nil end
    if type(value) ~= "table" then
        Router.fail(400, "bad_rule", "'goods' must be {prefer: [...], avoid: [...]}.")
    end

    local prefer = stringList(value.prefer, "goods.prefer") or Json.array({})
    local avoid = stringList(value.avoid, "goods.avoid") or Json.array({})

    local avoided = {}
    for _, name in ipairs(avoid) do avoided[string.lower(name)] = true end
    for _, name in ipairs(prefer) do
        if avoided[string.lower(name)] then
            Router.fail(400, "bad_rule", "'" .. name .. "' is both preferred and avoided.")
        end
    end

    if #prefer == 0 and #avoid == 0 then return nil end
    return {prefer = prefer, avoid = avoid}
end

-- Merges a request body over the rule already stored, and validates the result. Fields
-- left out of the body keep their stored value, so {"enabled": false} is a whole toggle.
-- Raises an API error on anything it cannot accept.
function MissionRules.normalize(body, previous)
    if type(body) ~= "table" then
        Router.fail(400, "bad_rule", "The rule must be a JSON object.")
    end

    local rule = copy(previous or {})

    local function given(name) return body[name] ~= nil end

    if given("mission") then rule.mission = string.lower(tostring(body.mission)) end

    if not rule.mission then
        Router.fail(400, "bad_rule", "'mission' is required.")
    end

    if not MissionRules.supported[rule.mission] then
        Router.fail(422, "not_automatable", unsupportedReasons[rule.mission]
                    or ("'" .. rule.mission .. "' is not a mission automation can run."),
                    {supported = Json.array(MissionRules.supportedList())})
    end

    if given("enabled") then
        if type(body.enabled) ~= "boolean" then
            Router.fail(400, "bad_rule", "'enabled' must be true or false.")
        end
        rule.enabled = body.enabled
    end
    if rule.enabled == nil then rule.enabled = true end

    if given("collectYields") then
        if type(body.collectYields) ~= "boolean" then
            Router.fail(400, "bad_rule", "'collectYields' must be true or false.")
        end
        rule.collectYields = body.collectYields
    end
    if rule.collectYields == nil then rule.collectYields = false end

    -- priorities wins over objective; an objective on its own replaces the priorities with
    -- itself, so a client that only knows `objective` still gets what it asked for
    if given("priorities") and body.priorities ~= Json.null then
        rule.priorities = normalizePriorities(body.priorities)
        rule.objective = rule.priorities[1]
    elseif given("objective") then
        rule.objective = tostring(body.objective)
        rule.priorities = nil
    elseif given("priorities") then
        rule.priorities = nil
    end
    rule.objective = rule.objective or "hourly"

    if not MissionRules.criteria[rule.objective] then
        Router.fail(400, "bad_rule", "'objective' is one of " .. table.concat(MissionRules.criteriaList, ", ") .. ".")
    end

    if given("area") or rule.area == nil then rule.area = normalizeArea(body.area, rule.mission) end
    if given("limits") or rule.limits == nil then rule.limits = normalizeLimits(body.limits) end

    if given("config") or rule.config == nil then
        local config = body.config
        if config == nil or config == Json.null then config = {} end
        if type(config) ~= "table" then
            Router.fail(400, "bad_rule", "'config' must be an object.")
        end

        -- The automation picks these itself; storing them would only make a stale value
        -- look like a decision.
        config = copy(config)
        if rule.mission == "trade" then config.goodName, config.deposit = nil, nil end

        rule.config = config
    end

    if given("goods") then rule.goods = normalizeGoods(body.goods) end
    if rule.goods and rule.mission ~= "trade" then
        Router.fail(400, "bad_rule", "'goods' only applies to trade.")
    end

    if given("materials") then rule.materials = stringList(body.materials, "materials") end
    if given("escorts") then rule.escorts = stringList(body.escorts, "escorts") end
    rule.escorts = rule.escorts or Json.array({})

    -- Escorts the craft may leave behind when they are not ready. Every other escort is
    -- required: the craft waits for it.
    if given("optionalEscorts") then
        rule.optionalEscorts = stringList(body.optionalEscorts, "optionalEscorts")
    end

    local named, seen = {}, {}
    for _, name in ipairs(rule.escorts) do
        if seen[name] then Router.fail(400, "bad_rule", "Escort '" .. name .. "' is listed twice.") end
        seen[name] = true
        named[name] = true
    end

    if rule.optionalEscorts then
        -- an escort taken off the list takes its optional flag with it
        local kept = Json.array({})
        for _, name in ipairs(rule.optionalEscorts) do
            if named[name] then kept[#kept + 1] = name
            elseif given("optionalEscorts") then
                Router.fail(400, "bad_rule", "'" .. name .. "' is in 'optionalEscorts' but not in 'escorts'.")
            end
        end
        rule.optionalEscorts = #kept > 0 and kept or nil
    end

    return rule
end

-- The order a rule ranks by.
function MissionRules.priorityList(rule)
    if type(rule.priorities) == "table" and #rule.priorities > 0 then return rule.priorities end
    return {rule.objective or "hourly"}
end

-- Every escort as {name, required}.
function MissionRules.escortList(rule)
    local optional = {}
    for _, name in ipairs(rule.optionalEscorts or {}) do optional[name] = true end

    local result = {}
    for _, name in ipairs(rule.escorts or {}) do
        result[#result + 1] = {name = name, required = not optional[name]}
    end
    return result
end

function MissionRules.supportedList()
    local result = {}
    for key, _ in pairs(MissionRules.supported) do result[#result + 1] = key end
    table.sort(result)
    return result
end

-- #### CANDIDATES #### --

local function steps(from, to, step)
    local values = {}
    if not isNumber(from) or not isNumber(to) or to < from then return values end

    local value = from
    while value < to - 1e-9 do
        values[#values + 1] = value
        value = value + step
    end
    values[#values + 1] = to

    return values
end

local function withField(base, field, value)
    local config = shallow(base)
    config[field] = value
    return config
end

-- The duration a rule is searching over, filtered to what its limits could ever accept.
-- A value outside the limits would only be rejected; one of them is kept anyway so the
-- evaluation can say how close the nearest miss was.
local function durationCandidates(base, spec, stepSize, secondsPer, limits)
    local all = steps(spec and spec.from, spec and spec.to, stepSize)
    if #all == 0 then return {shallow(base)} end

    local kept = {}
    for _, value in ipairs(all) do
        local seconds = value * secondsPer
        local tooLong = limits.maxDuration and seconds > limits.maxDuration + 1e-6
        local tooShort = limits.minDuration and seconds < limits.minDuration - 1e-6
        if not tooLong and not tooShort then kept[#kept + 1] = value end
    end

    if #kept == 0 then
        -- the closest miss: the shortest if everything is too long, else the longest
        kept[1] = limits.maxDuration and all[1] or all[#all]
    end

    local result = {}
    for _, value in ipairs(kept) do result[#result + 1] = withField(base, "duration", value) end
    return result
end

-- One trade route, tried at every flight count from as few as the cargo bay allows
-- upwards. For each count the deposit is the smallest that achieves it, which is also the
-- lowest attack chance that flight count can have.
local function tradeCandidates(base, route, env, limits)
    local good = env.goods and env.goods[route.name or ""]
    if not good or not isNumber(good.price) or not isNumber(good.size) or good.size <= 0 then
        return {}
    end

    local open = env.probe(withField(withField(base, "goodName", route.name), "deposit", 1e15))
    local available = type(open) == "table" and scalar(open.maxAvailable) or nil
    if not available or available <= 0 then return {} end

    local carriable = math.min(available, math.floor((env.freeCargo or 0) / good.size))
    if carriable <= 0 then return {} end

    local unitPrice = math.ceil(good.price * (1 + (route.lowest or 0)))
    local fewest = math.ceil(available / carriable)

    -- Past the patience limit nothing passes, but one count beyond it is still worth
    -- reporting as the nearest miss.
    local most = fewest + MAX_TRADE_FLIGHT_STEPS - 1
    if limits.maxFlights then most = math.min(most, math.max(fewest, limits.maxFlights) + 1) end
    most = math.min(most, MAX_TRADE_FLIGHTS)

    local result = {}
    local lastUnits

    for flights = fewest, most do
        local units = math.ceil(available / flights)

        if units ~= lastUnits then
            lastUnits = units

            local config = withField(base, "goodName", route.name)
            config.deposit = units * unitPrice
            result[#result + 1] = config
        end
    end

    return result
end

-- Every config worth predicting for this rule. env carries what only the game knows:
--
--   configurable  getConfigurableValues() for this ship and captain
--   routes        the trade routes the area analysis found
--   goods         the goods table, for trade prices and sizes
--   freeCargo     the ship's free cargo space
--   probe(config) runs calculatePrediction on the analysed area
function MissionRules.candidates(key, rule, base, env)
    local limits = rule.limits or {}
    local configurable = env.configurable or {}

    if key == "mine" or key == "salvage" then
        return durationCandidates(base, configurable.duration, 0.5, 3600, limits)
    end

    if key == "expedition" then
        return durationCandidates(base, configurable.duration, 30, 60, limits)
    end

    if key == "trade" then
        local avoided = {}
        for _, name in ipairs(rule.goods and rule.goods.avoid or {}) do avoided[string.lower(name)] = true end

        local result = {}
        for _, route in ipairs(env.routes or {}) do
            if not avoided[string.lower(tostring(route.name))] then
                for _, config in ipairs(tradeCandidates(base, route, env, limits)) do
                    result[#result + 1] = config
                end
            end
        end
        return result
    end

    return {shallow(base)}
end

-- #### METRICS #### --

-- Flights a trade contract is expected to fly before it completes or the customer walks.
function MissionRules.expectedTradeFlights(flights)
    if not isNumber(flights) or flights <= 0 then return 0 end

    local safe = MissionRules.TRADE_SAFE_FLIGHTS
    if flights <= safe then return flights end

    local expected = safe
    local survive = 1
    for _ = safe + 1, flights do
        survive = survive * MissionRules.TRADE_CONTINUE_CHANCE
        expected = expected + survive
    end

    return expected
end

function MissionRules.tradeCompletionChance(flights)
    if not isNumber(flights) or flights <= MissionRules.TRADE_SAFE_FLIGHTS then return 1 end
    return MissionRules.TRADE_CONTINUE_CHANCE ^ (flights - MissionRules.TRADE_SAFE_FLIGHTS)
end

-- How the captain words it, keyed on the same thresholds tradecommand.lua uses.
function MissionRules.tradePatience(flights)
    if not isNumber(flights) then return nil end
    if flights > 10 then return "likely lost" end
    if flights > 5 then return "real risk" end
    if flights > 3 then return "small risk" end
    return "safe"
end

local function sumYields(yields)
    if type(yields) ~= "table" then return nil end

    local total, seen = 0, false
    for _, yield in pairs(yields) do
        if type(yield) == "number" then
            total, seen = total + yield, true
        elseif type(yield) == "table" and (isNumber(yield.from) or isNumber(yield.to)) then
            local from = isNumber(yield.from) and yield.from or yield.to
            local to = isNumber(yield.to) and yield.to or yield.from
            total, seen = total + (from + to) / 2, true
        end
    end

    return seen and total or nil
end

-- The figures every limit and objective is written against, in one set of units whatever
-- the mission: seconds, fractions, credits.
function MissionRules.metrics(key, config, prediction)
    prediction = prediction or {}
    config = config or {}

    local m = {attackChance = scalar(prediction.attackChance) or 0}

    if key == "mine" or key == "salvage" then
        m.duration = isNumber(config.duration) and config.duration * 3600 or nil
        m.value = sumYields(prediction.yields)
        m.valueUnit = "resources"

    elseif key == "expedition" then
        m.duration = isNumber(config.duration) and config.duration * 60 or nil

    elseif key == "trade" then
        local flightTime = scalar(prediction.flightTime)
        local flights = type(prediction.flights) == "table" and prediction.flights.to or nil
        local perFlight = prediction.profitPerFlight

        m.flights = isNumber(flights) and flights or nil
        m.cost = isNumber(config.deposit) and config.deposit or nil
        m.valueUnit = "credits"

        if m.flights and isNumber(flightTime) then
            m.expectedFlights = MissionRules.expectedTradeFlights(m.flights)
            m.completionChance = MissionRules.tradeCompletionChance(m.flights)
            m.patience = MissionRules.tradePatience(m.flights)

            -- the whole contract, as the order window states it; the expected figure is
            -- what the hourly objective uses, since a lost contract also ends early
            m.duration = flightTime * m.flights
            m.expectedDuration = flightTime * m.expectedFlights

            if type(perFlight) == "table" and isNumber(perFlight.to) then
                local from = isNumber(perFlight.from) and perFlight.from or perFlight.to
                local average = (from + perFlight.to) / 2
                m.contractValue = average * m.flights
                m.value = average * m.expectedFlights
            end
        end

    elseif key == "sell" then
        m.duration = scalar(prediction.duration)
        m.value = scalar(prediction.yield)
        m.valueUnit = "credits"

    elseif key == "refine" then
        m.duration = scalar(prediction.duration)
        m.value = sumYields(prediction.yields)
        m.valueUnit = "resources"

    elseif key == "procure" then
        m.duration = scalar(prediction.duration)
        m.cost = scalar(prediction.totalBudget)

    elseif key == "maintenance" then
        m.duration = scalar(prediction.duration)
        m.cost = scalar(prediction.moneyNeeded)

    else
        m.duration = scalar(prediction.duration)
    end

    local seconds = m.expectedDuration or m.duration
    if m.value and isNumber(seconds) and seconds > 0 then
        m.hourly = m.value / seconds * 3600
    end

    return m
end

-- #### LIMITS #### --

local function pct(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end

local function hours(seconds)
    if seconds >= 3600 then return string.format("%.1fh", seconds / 3600) end
    return string.format("%dmin", math.floor(seconds / 60 + 0.5))
end

local function credits(v) return string.format("%d¢", math.floor(v + 0.5)) end

-- Returns a list of {limit, message}. Empty means the candidate may go.
--
-- facts.money        the owner's credits, for minCreditsLeft
-- facts.canStart     whether the game itself would start it
-- facts.gameError    the first reason it would not
function MissionRules.check(limits, m, facts)
    limits = limits or {}
    facts = facts or {}

    local violations = {}
    local function fail(limit, message)
        violations[#violations + 1] = {limit = limit, message = message}
    end

    if facts.canStart == false then
        fail("game", facts.gameError or "The game would not start this mission.")
    end

    -- Attack chance is rounded to hundredths by the game; the slack keeps a limit of
    -- exactly 0.2 from rejecting a chance the game itself reports as 20%.
    if limits.maxAttackChance and m.attackChance > limits.maxAttackChance + 1e-6 then
        fail("maxAttackChance", string.format("ambush chance %s is above %s",
             pct(m.attackChance), pct(limits.maxAttackChance)))
    end

    if limits.maxDuration and m.duration and m.duration > limits.maxDuration + 1e-6 then
        fail("maxDuration", string.format("takes %s, longer than %s",
             hours(m.duration), hours(limits.maxDuration)))
    end

    if limits.minDuration and m.duration and m.duration < limits.minDuration - 1e-6 then
        fail("minDuration", string.format("takes %s, shorter than %s",
             hours(m.duration), hours(limits.minDuration)))
    end

    if limits.maxFlights and m.flights and m.flights > limits.maxFlights then
        fail("maxFlights", string.format("%d flights, more than %d - the customer may walk",
             m.flights, limits.maxFlights))
    end

    if limits.maxDeposit and m.cost and m.cost > limits.maxDeposit + 1e-6 then
        fail("maxDeposit", string.format("needs %s up front, more than %s",
             credits(m.cost), credits(limits.maxDeposit)))
    end

    if limits.minCreditsLeft and isNumber(facts.money) then
        local left = facts.money - (m.cost or 0)
        if left < limits.minCreditsLeft then
            fail("minCreditsLeft", string.format("would leave %s, less than the %s reserve",
                 credits(left), credits(limits.minCreditsLeft)))
        end
    end

    if limits.minValue then
        if not m.value then
            fail("minValue", "this mission predicts no yield to compare against")
        elseif m.value < limits.minValue then
            fail("minValue", string.format("expected yield %d, below %d",
                 math.floor(m.value + 0.5), math.floor(limits.minValue + 0.5)))
        end
    end

    return violations
end

-- #### RANKING #### --

local function orNegative(v) return isNumber(v) and v or -math.huge end
local function orHuge(v) return isNumber(v) and v or math.huge end

local function lowerFirst(field)
    return function(a, b)
        local va, vb = orHuge(a.metrics[field]), orHuge(b.metrics[field])
        if va ~= vb then return va < vb end
        return nil
    end
end

local comparators =
{
    hourly = function(a, b)
        local ha, hb = orNegative(a.metrics.hourly), orNegative(b.metrics.hourly)
        if ha ~= hb then return ha > hb end
        return nil
    end,
    total = function(a, b)
        local va, vb = orNegative(a.metrics.value), orNegative(b.metrics.value)
        if va ~= vb then return va > vb end
        local da, db = orNegative(a.metrics.duration), orNegative(b.metrics.duration)
        if da ~= db then return da > db end
        return nil
    end,
    safest = function(a, b)
        if a.metrics.attackChance ~= b.metrics.attackChance then
            return a.metrics.attackChance < b.metrics.attackChance
        end
        return nil
    end,
    shortest = function(a, b)
        local da = orHuge(a.metrics.expectedDuration or a.metrics.duration)
        local db = orHuge(b.metrics.expectedDuration or b.metrics.duration)
        if da ~= db then return da < db end
        return nil
    end,
    fewestFlights = lowerFirst("flights"),
    cheapest = lowerFirst("cost"),
}

-- Sorts evaluated candidates in place, best first: everything that passes ahead of
-- everything that does not, then preferred goods ahead of the rest, then each priority in
-- turn, then the safer, then the better per hour. Among failures the fewest violations
-- lead, so the head of a blocked list is the nearest miss.
--
-- `priorities` is a list of criteria, or a single objective's name. opts.prefer lists goods
-- to take first when they pass.
function MissionRules.rank(evaluated, priorities, opts)
    if type(priorities) ~= "table" then priorities = {priorities or "hourly"} end

    local chain = {}
    for _, name in ipairs(priorities) do
        if comparators[name] then chain[#chain + 1] = comparators[name] end
    end
    chain[#chain + 1] = comparators.safest
    chain[#chain + 1] = comparators.hourly

    local preferred = {}
    for _, name in ipairs(opts and opts.prefer or {}) do preferred[string.lower(name)] = true end
    local function isPreferred(entry)
        local good = entry.config and entry.config.goodName
        return good ~= nil and preferred[string.lower(tostring(good))] == true
    end

    for index, entry in ipairs(evaluated) do
        entry.order = index
        entry.preferred = isPreferred(entry)
    end

    table.sort(evaluated, function(a, b)
        local pa, pb = #a.violations == 0, #b.violations == 0
        if pa ~= pb then return pa end
        if not pa and #a.violations ~= #b.violations then
            return #a.violations < #b.violations
        end

        if pa and a.preferred ~= b.preferred then return a.preferred end

        for _, compare in ipairs(chain) do
            local decided = compare(a, b)
            if decided ~= nil then return decided end
        end

        return a.order < b.order
    end)

    return evaluated
end

return MissionRules
