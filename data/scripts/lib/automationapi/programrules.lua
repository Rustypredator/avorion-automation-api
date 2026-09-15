-- Order programs: what a program is made of, and when one of its steps is done.
--
-- A program is a list of steps a craft works through by itself. Each step does one thing -
-- fly a route, farm bosses, run an order chain, go out on a mission, change its standing
-- orders, move cargo to or from another craft, or wait - until its conditions are met, and then moves on: to the next step, to
-- a step named by number (which is how a program loops), or to its end.
--
--   farm bosses                 until cargo >= 80%          then next
--   route to the trade station  (until it arrives)          then next
--   mission, the craft's rule   until cargo <= 5%, repeat   then go to step 1
--
-- Pure Lua, so it is tested without the game. handlers/programs.lua gathers the facts a
-- condition is checked against and carries the steps out; this file owns the vocabulary,
-- its validation, and the arithmetic of "is this step done".

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local MissionRules = include("automationapi/missionrules")
local TransferRules = include("automationapi/transferrules")

local ProgramRules = {}

ProgramRules.MAX_STEPS = 20
ProgramRules.MAX_CONDITIONS = 8

local function fail(message, details)
    Router.fail(400, "bad_program", message, details)
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return setmetatable(out, getmetatable(value))
end

ProgramRules.copy = copy

local function integer(value, what)
    if type(value) ~= "number" or value ~= math.floor(value) then
        fail(what .. " must be a whole number.")
    end
    return value
end

local function number(value, what, min, max)
    if type(value) ~= "number" or value ~= value then fail(what .. " must be a number.") end
    if (min and value < min) or (max and value > max) then
        fail(string.format("%s must be between %s and %s.", what, tostring(min), tostring(max)))
    end
    return value
end

local function boolean(value, what)
    if value == nil then return nil end
    if type(value) ~= "boolean" then fail(what .. " must be true or false.") end
    return value
end

local function coordinates(value, what)
    if type(value) ~= "table" then fail(what .. " must be {x, y}.") end
    return {x = integer(value.x, what .. ".x"), y = integer(value.y, what .. ".y")}
end

local function sortedNames(t)
    local names = {}
    for name, _ in pairs(t) do names[#names + 1] = name end
    table.sort(names)
    return names
end

-- #### ACTIONS #### --
--
-- Each action says how it is checked when saved, and what its natural end is: the moment
-- the thing it started is over by itself. A step without conditions ends there; one with
-- conditions waits for them, and with `repeat` starts the action again each time it ends.
--
--   route     the plan it sent ends (arrived, or stopped by something else)
--   farm      never by itself: a farm loops until told otherwise, so it needs conditions
--   orders    the chain runs out
--   mission   the craft is back from the mission
--   travel    the craft is back from the Travel mission: at its destination, available again
--   standing  at once - the ship keeps the orders after the step
--   transfer  the ship reports the transfer over: moved, refused, or given up on the way
--   wait      never: it needs an elapsed condition, or another that ends it

local ON_ENEMIES = {fight = true, hold = true, continue = true}
local BOSSES = {auto = true, ai = true, swoks = true}

ProgramRules.actions =
{
    route =
    {
        naturalEnd = "plan",
        normalize = function(spec)
            local action = {type = "route", to = coordinates(spec.to, "'action.to'")}
            if spec.onEnemies ~= nil then
                action.onEnemies = string.lower(tostring(spec.onEnemies))
                if not ON_ENEMIES[action.onEnemies] then
                    fail("'action.onEnemies' is one of fight, hold or continue.")
                end
            end
            for _, name in ipairs({"attackCivilians", "preferGates", "avoidRifts", "preferUncontrolled"}) do
                action[name] = boolean(spec[name], "'action." .. name .. "'")
            end
            return action
        end,
    },
    farm =
    {
        naturalEnd = nil,
        normalize = function(spec)
            local action = {type = "farm", boss = string.lower(tostring(spec.boss or "auto"))}
            if not BOSSES[action.boss] then fail("'action.boss' is one of auto, ai or swoks.") end
            if spec.onEnemies ~= nil then
                action.onEnemies = string.lower(tostring(spec.onEnemies))
                if not ON_ENEMIES[action.onEnemies] then
                    fail("'action.onEnemies' is one of fight, hold or continue.")
                end
            end
            action.attackCivilians = boolean(spec.attackCivilians, "'action.attackCivilians'")
            action.collectLoot = boolean(spec.collectLoot, "'action.collectLoot'")
            if spec.bossCooldown ~= nil then
                action.bossCooldown = math.floor(number(spec.bossCooldown, "'action.bossCooldown'", 0, 4 * 3600))
            end
            return action
        end,
    },
    orders =
    {
        naturalEnd = "idle",
        normalize = function(spec)
            if type(spec.orders) ~= "table" or #spec.orders == 0 then
                fail("'action.orders' is a non-empty list of orders, as POST /ships/{name}/orders takes.")
            end
            -- The order types themselves are checked by the orders endpoint when the step
            -- runs; here only the shape, so a program can never hold a non-list.
            local orders = Json.array({})
            for index, order in ipairs(spec.orders) do
                if type(order) ~= "table" and type(order) ~= "string" then
                    fail("'action.orders' entry " .. index .. " must be an object or a type name.")
                end
                orders[index] = copy(order)
            end
            return {type = "orders", orders = orders, clear = boolean(spec.clear, "'action.clear'")}
        end,
    },
    mission =
    {
        naturalEnd = "returned",
        normalize = function(spec)
            local action = {type = "mission"}
            -- Without a rule of its own or a library mission's name, the step flies the
            -- craft's mission automation rule, whatever it is when the step runs. A library
            -- mission is looked up when the step starts, so an edit to it applies from the
            -- next start; whether the name exists is the handler's check, at save.
            if spec.library ~= nil then
                if spec.rule ~= nil then fail("A mission step takes 'library' or 'rule', not both.") end
                local name = type(spec.library) == "string" and string.match(spec.library, "^%s*(.-)%s*$") or ""
                if name == "" then fail("'action.library' must be the name of a library mission.") end
                action.library = name
            end
            if spec.rule ~= nil then
                local rule = MissionRules.normalize(spec.rule)
                rule.enabled = nil
                action.rule = rule
            end
            return action
        end,
    },
    -- A Travel captain mission, as POST /ships/{name}/travel starts it: galaxy-wide, with no
    -- sector loaded, which is what makes it the way to cross long distances between steps.
    travel =
    {
        naturalEnd = "returned",
        normalize = function(spec)
            local action = {type = "travel", to = coordinates(spec.to, "'action.to'")}
            if spec.swiftness ~= nil then
                action.swiftness = integer(spec.swiftness, "'action.swiftness'")
                if action.swiftness < 0 or action.swiftness > 3 then
                    fail("'action.swiftness' is 0 (careful) to 3 (reckless).")
                end
            end
            return action
        end,
    },
    standing =
    {
        naturalEnd = "immediate",
        normalize = function(spec)
            local action = {type = "standing"}
            if spec.standing ~= nil then
                if type(spec.standing) ~= "table" then fail("'action.standing' must be an object.") end
                action.standing = copy(spec.standing)
            end
            action.attackCivilians = boolean(spec.attackCivilians, "'action.attackCivilians'")
            if action.standing == nil and action.attackCivilians == nil then
                fail("A standing step sets 'action.standing' and/or 'action.attackCivilians'.")
            end
            return action
        end,
    },
    -- POST /ships/{name}/transfer: goods into or out of another craft in the ship's sector.
    -- The target is named, as a craft is everywhere else; whether it is in the sector is
    -- the endpoint's check when the step runs, so a program can fly the ship there first.
    transfer =
    {
        naturalEnd = "transfer",
        normalize = function(spec)
            local function transferFail(_, message) fail(message) end
            local target, targetOwner = TransferRules.target(spec, transferFail, "action.")
            local transfer = TransferRules.normalize(spec, transferFail, "action.")
            return
            {
                type = "transfer",
                target = target,
                targetOwner = targetOwner,
                direction = transfer.direction,
                all = transfer.all or nil,
                goods = transfer.goods,
                approach = transfer.approach,
            }
        end,
    },
    wait =
    {
        naturalEnd = nil,
        normalize = function() return {type = "wait"} end,
    },
}

-- #### CONDITIONS #### --

local OPS = {[">="] = true, ["<="] = true}

local function compare(value, op, target)
    if op == ">=" then return value >= target end
    return value <= target
end

local function op(spec)
    local value = spec.op or ">="
    if not OPS[value] then fail("A condition's 'op' is >= or <=.") end
    return value
end

-- normalize(spec) checks a condition when it is saved. check(condition, facts) answers
-- true or false, or nil when the facts to decide it are missing - which counts as not met.
-- describe(condition) is the line the console and the log show.
ProgramRules.conditions =
{
    cargo =
    {
        normalize = function(spec)
            return {type = "cargo", op = op(spec), percent = number(spec.percent, "'percent'", 0, 100)}
        end,
        check = function(c, facts)
            local cargo = facts.cargo
            if not cargo or (cargo.capacity or 0) <= 0 then return nil end
            return compare(cargo.used / cargo.capacity * 100, c.op, c.percent)
        end,
        describe = function(c) return string.format("cargo %s %s%%", c.op, tostring(c.percent)) end,
    },
    good =
    {
        normalize = function(spec)
            if type(spec.name) ~= "string" or spec.name == "" then fail("A good condition names its 'name'.") end
            return {type = "good", name = spec.name, op = op(spec), amount = number(spec.amount, "'amount'", 0)}
        end,
        check = function(c, facts)
            local cargo = facts.cargo
            if not cargo then return nil end
            local held = 0
            for _, good in ipairs(cargo.goods or {}) do
                if good.name == c.name then held = held + (good.amount or 0) end
            end
            return compare(held, c.op, c.amount)
        end,
        describe = function(c) return string.format("%s %s %s", c.name, c.op, tostring(c.amount)) end,
    },
    bossKills =
    {
        normalize = function(spec)
            return {type = "bossKills", count = math.floor(number(spec.count, "'count'", 1))}
        end,
        check = function(c, facts) return (facts.bossKills or 0) >= c.count end,
        describe = function(c) return string.format("%d boss kill%s", c.count, c.count == 1 and "" or "s") end,
    },
    arrived =
    {
        normalize = function() return {type = "arrived"} end,
        check = function(_, facts) return facts.arrived == true end,
        describe = function() return "arrived" end,
    },
    planEnded =
    {
        normalize = function() return {type = "planEnded"} end,
        check = function(_, facts) return facts.planEnded == true end,
        describe = function() return "the plan ended" end,
    },
    missionReturned =
    {
        normalize = function() return {type = "missionReturned"} end,
        check = function(_, facts) return facts.returned == true end,
        describe = function() return "back from the mission" end,
    },
    elapsed =
    {
        normalize = function(spec)
            return {type = "elapsed", seconds = math.floor(number(spec.seconds, "'seconds'", 1))}
        end,
        check = function(c, facts) return (facts.elapsed or 0) >= c.seconds end,
        describe = function(c) return string.format("%ds in this step", c.seconds) end,
    },
    enemies =
    {
        normalize = function(spec)
            local present = spec.present
            if present == nil then present = true end
            return {type = "enemies", present = boolean(present, "'present'")}
        end,
        check = function(c, facts)
            if facts.enemies == nil then return nil end
            return facts.enemies == c.present
        end,
        describe = function(c) return c.present and "enemies in sector" or "no enemies in sector" end,
    },
    idle =
    {
        normalize = function() return {type = "idle"} end,
        check = function(_, facts) return facts.idle end,
        describe = function() return "the ship is idle" end,
    },
    at =
    {
        normalize = function(spec)
            local at = coordinates(spec, "An 'at' condition")
            return {type = "at", x = at.x, y = at.y}
        end,
        check = function(c, facts)
            if not facts.position then return nil end
            return facts.position.x == c.x and facts.position.y == c.y
        end,
        describe = function(c) return string.format("in (%d:%d)", c.x, c.y) end,
    },
}

ProgramRules.actionNames = sortedNames(ProgramRules.actions)
ProgramRules.conditionNames = sortedNames(ProgramRules.conditions)

local THEN = {next = true, stop = true, start = true, ["goto"] = true}

local function normalizeCondition(spec, index)
    if type(spec) ~= "table" then fail("Condition " .. index .. " must be an object.") end
    local kind = ProgramRules.conditions[spec.type]
    if not kind then
        fail("Unknown condition '" .. tostring(spec.type) .. "'.",
             {known = Json.array(copy(ProgramRules.conditionNames))})
    end
    return kind.normalize(spec)
end

local function normalizeStep(spec, index)
    local where = "Step " .. index
    if type(spec) ~= "table" then fail(where .. " must be an object.") end
    if type(spec.action) ~= "table" then fail(where .. " needs an 'action'.") end

    local kind = ProgramRules.actions[spec.action.type]
    if not kind then
        fail(where .. ": unknown action '" .. tostring(spec.action.type) .. "'.",
             {known = Json.array(copy(ProgramRules.actionNames))})
    end

    local step = {action = kind.normalize(spec.action)}

    if spec.name ~= nil then step.name = tostring(spec.name) end

    local untilSpec = spec["until"] or {}
    if type(untilSpec) ~= "table" then fail(where .. ": 'until' must be an object.") end

    local match = string.lower(tostring(untilSpec.match or "any"))
    if match ~= "any" and match ~= "all" then fail(where .. ": 'until.match' is any or all.") end

    local conditions = Json.array({})
    for i, condition in ipairs(untilSpec.conditions or {}) do
        conditions[i] = normalizeCondition(condition, i)
    end
    if #conditions > ProgramRules.MAX_CONDITIONS then
        fail(string.format("%s has more than %d conditions.", where, ProgramRules.MAX_CONDITIONS))
    end

    step["until"] = {match = match, conditions = conditions}
    step["repeat"] = boolean(spec["repeat"], where .. ": 'repeat'") == true

    if #conditions == 0 then
        if not kind.naturalEnd then
            fail(where .. ": a " .. step.action.type .. " step never ends by itself, so it needs "
                 .. "at least one condition in 'until'.")
        end
        if step["repeat"] then
            fail(where .. ": 'repeat' runs the action again until the conditions are met, so it "
                 .. "needs conditions.")
        end
    end

    if step["repeat"] and kind.naturalEnd == "immediate" then
        fail(where .. ": a standing step cannot repeat; it is over as soon as it is sent.")
    end

    local thenValue = spec["then"] or "next"
    local gotoStep
    if type(thenValue) == "table" then
        gotoStep = thenValue["goto"]
        thenValue = "goto"
    elseif thenValue == "goto" then
        gotoStep = spec["goto"]
    end
    thenValue = tostring(thenValue)
    if not THEN[thenValue] then fail(where .. ": 'then' is next, start, stop or {\"goto\": n}.") end

    step["then"] = thenValue
    if thenValue == "goto" then
        if gotoStep == nil then fail(where .. ": 'then' is goto but no 'goto' step is given.") end
        step["goto"] = integer(gotoStep, where .. ": 'goto'")
    end

    return step
end

-- Checks a program body, merged over the stored one: fields left out keep their values, and
-- `steps`, when given, replaces the steps whole.
function ProgramRules.normalize(body, previous)
    if type(body) ~= "table" then fail("The program must be a JSON object.") end

    local program = copy(previous or {})

    if body.name ~= nil then program.name = tostring(body.name) end
    program.name = program.name or "Program"

    if body.enabled ~= nil then program.enabled = boolean(body.enabled, "'enabled'") end
    if program.enabled == nil then program.enabled = true end

    if body.steps ~= nil then
        if type(body.steps) ~= "table" or #body.steps == 0 then
            fail("'steps' is a non-empty list.")
        end
        if #body.steps > ProgramRules.MAX_STEPS then
            fail(string.format("A program has at most %d steps.", ProgramRules.MAX_STEPS))
        end

        local steps = Json.array({})
        for index, step in ipairs(body.steps) do steps[index] = normalizeStep(step, index) end

        for index, step in ipairs(steps) do
            if step["goto"] and (step["goto"] < 1 or step["goto"] > #steps) then
                fail(string.format("Step %d goes to step %d, which does not exist.", index, step["goto"]))
            end
        end

        program.steps = steps
    end

    if type(program.steps) ~= "table" or #program.steps == 0 then
        fail("'steps' is required.")
    end

    return program
end

-- #### EVALUATION #### --

-- Where a step's conditions stand: {done, met = {bool per condition}}. A step with no
-- conditions is done at its action's natural end.
function ProgramRules.evaluate(step, facts)
    local conditions = step["until"].conditions
    local met = {}

    if #conditions == 0 then
        return {done = facts.naturalEnd == true, met = met}
    end

    local all, any = true, false
    for index, condition in ipairs(conditions) do
        local result = ProgramRules.conditions[condition.type].check(condition, facts) == true
        met[index] = result
        all = all and result
        any = any or result
    end

    return {done = step["until"].match == "all" and all or step["until"].match ~= "all" and any, met = met}
end

function ProgramRules.describeCondition(condition)
    local kind = ProgramRules.conditions[condition.type]
    return kind and kind.describe(condition) or tostring(condition.type)
end

function ProgramRules.naturalEndOf(step)
    return ProgramRules.actions[step.action.type].naturalEnd
end

-- Where a finished step goes: a step index, or nil for the end of the program.
function ProgramRules.nextStep(program, index)
    local step = program.steps[index]
    if step["then"] == "stop" then return nil end
    if step["then"] == "start" then return 1 end
    if step["then"] == "goto" then return step["goto"] end
    if index < #program.steps then return index + 1 end
    return nil
end

return ProgramRules
