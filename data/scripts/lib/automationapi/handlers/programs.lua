-- Order programs: a craft working through a list of steps by itself, each until its
-- conditions are met. See programrules.lua for what a program is made of.
--
-- Where things live, and why:
--
--   * Programs are Server values, one JSON document per owning faction with a revision,
--     exactly as mission automation rules are and for the same reasons: the galaxy bridge
--     reads them with nobody logged in, they survive restarts, and an alliance's programs
--     are one document every member reads and edits.
--
--   * The runner is here in the galaxy bridge, so a program keeps going with no console
--     open. Every step that gives the ship an order still needs the owner online, because
--     the order is carried out by the owner's agent, as any write is.
--
--   * A step's action is carried out by the endpoint a client would call - a route is
--     POST /ships/{name}/route, standing orders are POST /ships/{name}/automation, a cargo
--     transfer is POST /ships/{name}/transfer - issued
--     as an internal request through the router, with the owner, or for alliance craft the
--     member who last saved the program, as the caller. So a program can never do anything
--     a request could not, it is validated and confirmed the same way, and a new endpoint
--     is a new action without a second implementation. Mission steps are the exception:
--     they run the mission automation's own analysis and start, once
--     (MissionAutomation.startOnce), so the limits a rule sets apply to them too.
--
--   * Conditions are checked against what the bridge already knows without asking the
--     ship anything: its database row (cargo, position, availability), and the automation
--     state and chain it last reported through the agent (plans, boss kills, enemies).
--
--   * Where a program has got to is kept in memory and, on every step change, in a cursor
--     value of its own. After a restart the current step starts over.
--
--   * A station's program holds only steps that leave it where it is: standing orders,
--     orders, cargo transfers and waits. A station's transfer never flies anywhere first.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Serialize = include("automationapi/serialize")
local Config = include("automationapi/config")
local Owner = include("automationapi/owner")
local ShipEvents = include("automationapi/shipevents")
local ProgramRules = include("automationapi/programrules")
local MissionAutomation = include("automationapi/handlers/missionautomation")
local MissionLibrary = include("automationapi/handlers/missionlibrary")
local TransferRules = include("automationapi/transferrules")
local ShipData = include("automationapi/shipdata")
local Locations = include("automationapi/locations")

local Programs = {}

-- the router the internal requests go through, set by register()
local router

-- #### HELPERS #### --

local function now()
    local ok, runtime = pcall(function() return Server().unpausedRuntime end)
    return ok and type(runtime) == "number" and runtime or 0
end

local function sortedKeys(t)
    local keys = {}
    for key, _ in pairs(t) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

-- Ship names go into a path, and the router decodes each segment.
local function encodeSegment(name)
    return (string.gsub(name, "[^%w%-_%.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- #### STORE #### --

local cache = {}

local function valueKey(index) return Config.programValuePrefix .. tostring(index) end

local function factionIndices()
    local raw = Server():getValue(Config.programIndexValue)
    local list = type(raw) == "string" and Json.decode(raw) or nil

    local result = {}
    for _, index in ipairs(type(list) == "table" and list or {}) do
        if type(index) == "number" then result[#result + 1] = index end
    end

    return result
end

local function loadFaction(index)
    local raw = Server():getValue(valueKey(index))

    local cached = cache[index]
    if cached and cached.raw == raw then return cached.data end

    local data
    if type(raw) == "string" and raw ~= "" then
        local decoded = Json.decode(raw)
        if type(decoded) == "table" and type(decoded.ships) == "table" then data = decoded end
    end

    data = data or {ships = {}}
    cache[index] = {raw = raw, data = data}

    return data
end

local function saveFaction(index, data)
    local empty = next(data.ships) == nil

    local raw
    if not empty then
        local encoded, err = Json.encode({version = 1, ships = data.ships})
        if not encoded then
            Router.fail(500, "encoding_failed", "Could not store the program: " .. tostring(err))
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
        Server():setValue(Config.programIndexValue, #kept > 0 and Json.encode(kept) or nil)
    end
end

-- #### CURSORS #### --

local function loadCursors(index)
    local raw = Server():getValue(Config.programCursorPrefix .. tostring(index))
    local decoded = type(raw) == "string" and Json.decode(raw) or nil
    return type(decoded) == "table" and decoded or {}
end

local function saveCursor(index, shipName, run)
    local cursors = loadCursors(index)

    if run then
        cursors[shipName] = {step = run.step, revision = run.revision,
                             finished = run.status == "finished" or nil}
    else
        cursors[shipName] = nil
    end

    Server():setValue(Config.programCursorPrefix .. tostring(index),
                      next(cursors) and Json.encode(cursors) or nil)
end

-- #### RUNS #### --

-- "<factionIndex>/<shipName>" -> where that program has got to
local runs = {}

local function runKey(index, shipName) return tostring(index) .. "/" .. shipName end

local function note(run, status, message, detail)
    local changed = run.status ~= status or run.message ~= message

    run.status = status
    run.message = message
    if changed then run.since = now() end

    if changed or detail then
        run.log[#run.log + 1] = {at = now(), status = status, step = run.step,
                                 message = message, detail = detail}

        local overflow = #run.log - Config.programLogSize
        if overflow > 0 then
            local trimmed = {}
            for i = overflow + 1, #run.log do trimmed[#trimmed + 1] = run.log[i] end
            run.log = trimmed
        end
    end
end

-- Forgets what the previous action left behind, so its plan or mission is not taken for
-- this one's.
local function resetTracking(run)
    run.token = (run.token or 0) + 1
    run.planId = nil
    run.planEnded = false
    run.arrived = false
    run.planKills = 0
    run.sawBackground = false
    run.returned = false
    run.dispatchedAt = nil
    run.transferId = nil
    run.transferShip = nil
    run.transferEnded = false
    run.transferOutcome = nil
    run.leg = nil
end

local function enterStep(index, shipName, run, stepIndex)
    resetTracking(run)
    run.step = stepIndex
    run.stepSince = now()
    run.phase = "start"
    run.killsBefore = 0
    run.attempts = 0
    run.nextAt = 0
    run.busy = false
    run.conditions = nil
    saveCursor(index, shipName, run)
end

local function runOf(index, shipName, program)
    local key = runKey(index, shipName)
    local run = runs[key]

    if run and run.revision == program.revision then return run end

    run = {log = {}, revision = program.revision, status = "waiting", message = "Not started yet.",
           since = now()}
    runs[key] = run

    -- A restart keeps the step a program had got to, as long as the program is unchanged.
    local cursor = loadCursors(index)[shipName]
    local start = 1
    if type(cursor) == "table" and cursor.revision == program.revision
       and type(cursor.step) == "number" and program.steps[cursor.step] then
        start = cursor.step
    end

    enterStep(index, shipName, run, start)

    if type(cursor) == "table" and cursor.revision == program.revision and cursor.finished then
        run.status = "finished"
        run.phase = "finished"
        run.message = "The program has run to its end."
    end

    return run
end

-- #### INTERNAL REQUESTS #### --

-- Runs an endpoint as the program's authority. onDone(status, body) is called once, now or
-- when a deferred request completes.
local function internalRequest(owner, authority, method, path, body, onDone, ownerQuery)
    local player = owner.kind == "player" and owner.faction
                   or {index = authority.index, name = authority.name, alliance = owner.faction}

    local done = false

    local ctx =
    {
        requestId = "program",
        method = method,
        path = path,
        query = {owner = ownerQuery or owner.kind},
        body = body,
        playerIndex = authority.index,
        player = player,
        now = now(),
    }

    ctx.complete = function(status, responseBody)
        if done then return end
        done = true
        onDone(status, responseBody)
    end

    local status, responseBody = router:dispatch(method, path, ctx)
    if status ~= Router.DEFERRED then ctx.complete(status, responseBody) end
end

local function requestFor(shipName, action)
    local base = "/ships/" .. encodeSegment(shipName)
    local body = ProgramRules.copy(action)
    body.type = nil

    if action.type == "route" then return base .. "/route", body end
    if action.type == "farm" then return base .. "/farm", body end
    if action.type == "orders" then return base .. "/orders", body end
    if action.type == "standing" then return base .. "/automation", body end
    if action.type == "travel" then return base .. "/travel", body end
    if action.type == "transfer" then
        body.travelToTarget = nil
        return base .. "/transfer", body
    end

    return nil
end

-- #### FACTS #### --

local function gatherFacts(owner, shipName, run, step)
    local t = now()
    local facts = {elapsed = t - (run.stepSince or t)}

    local entry = ShipDatabaseEntry(owner.index, shipName)
    if entry then
        local okCargo, cargos, capacity = pcall(function() return entry:getCargo() end)
        local okFree, free = pcall(function() return entry:getFreeCargoSpace() end)
        if okCargo and okFree then
            capacity = Serialize.number(capacity, 0)
            facts.cargo =
            {
                capacity = capacity,
                used = capacity - Serialize.number(free, 0),
                goods = Serialize.cargoList(cargos),
            }
        end
    end

    local okPosition, x, y = pcall(function() return owner.faction:getShipPosition(shipName) end)
    if okPosition and type(x) == "number" then facts.position = {x = x, y = y} end

    local availability = owner.faction:getShipAvailability(shipName)

    local automation = ShipEvents.latestAutomation(owner.index, shipName)
    if automation then facts.enemies = automation.enemies == true end

    -- The plan this step sent: running while the ship reports it, over once it reports how
    -- it ended.
    if run.planId and automation then
        local plan = automation.plan
        if type(plan) == "table" and plan.id == run.planId then
            run.planKills = Serialize.number(plan.bossKills, run.planKills or 0)
        end

        local last = automation.last
        if type(last) == "table" and last.id == run.planId then
            run.planEnded = true
            run.arrived = last.outcome == "arrived"
        end
    end

    -- The transfer this step sent: over once the ship reports how it went. One that is
    -- neither reported over nor on its way after the grace period was lost - another
    -- transfer overwrote the report, or the ship never got it - and counts as over too.
    -- A station's transfer is carried out by the ship at the other end, and reported there.
    local transferFeed = automation
    if run.transferShip then
        transferFeed = ShipEvents.latestAutomation(run.transferShip.index, run.transferShip.name)
    end

    if run.transferId and not run.transferEnded and transferFeed then
        local last = transferFeed.lastTransfer
        local current = transferFeed.transfer
        if type(last) == "table" and last.id == run.transferId then
            run.transferEnded = true
            run.transferOutcome = last.outcome
        elseif not (type(current) == "table" and current.id == run.transferId)
               and run.dispatchedAt and t - run.dispatchedAt >= Config.programOrdersGrace then
            run.transferEnded = true
            run.transferOutcome = "unknown"
        end
    end

    facts.planEnded = run.planEnded
    facts.arrived = run.arrived
    facts.bossKills = (run.killsBefore or 0) + (run.planKills or 0)

    local order = ShipEvents.latestOrder(owner.index, shipName)
    if order and availability == ShipAvailability.Available then
        local chainEmpty = type(order.chain) ~= "table" or #order.chain == 0 or order.finished == true
        facts.idle = chainEmpty
                     and not (automation and (automation.plan or automation.reaction)) or false
    elseif availability == ShipAvailability.InBackground then
        facts.idle = false
    end

    -- A mission is back once the craft has been seen out and is available again.
    if availability == ShipAvailability.InBackground then run.sawBackground = true end
    if run.sawBackground and availability == ShipAvailability.Available then run.returned = true end
    facts.returned = run.returned

    local natural = ProgramRules.naturalEndOf(step)
    if natural == "plan" then
        facts.naturalEnd = run.planEnded
    elseif natural == "idle" then
        facts.naturalEnd = facts.idle == true and run.dispatchedAt ~= nil
                           and t - run.dispatchedAt >= Config.programOrdersGrace
    elseif natural == "returned" then
        facts.naturalEnd = run.returned
    elseif natural == "immediate" then
        facts.naturalEnd = true
    elseif natural == "transfer" then
        facts.naturalEnd = run.transferEnded
    end

    return facts
end

-- #### THE RUNNER #### --

local function authorityOf(owner, program)
    if owner.kind ~= "alliance" then
        return {index = owner.index, name = owner.name}
    end

    local by = type(program.updatedBy) == "table" and program.updatedBy or nil
    return by and {index = by.index, name = by.name} or nil
end

local function stepLabel(program, index)
    local step = program.steps[index]
    if not step then return "step " .. tostring(index) end
    return string.format("step %d (%s)", index, step.name or step.action.type)
end

local function conditionsText(step)
    local parts = {}
    for _, condition in ipairs(step["until"].conditions) do
        parts[#parts + 1] = ProgramRules.describeCondition(condition)
    end
    if #parts == 0 then return nil end
    return table.concat(parts, step["until"].match == "all" and " and " or " or ")
end

-- The error a refused request answered with. A mission start the game would refuse answers
-- with its assessment's `errors` instead of an `error`, and the first of those is the reason.
local function errorOf(status, response)
    local e = type(response.error) == "table" and response.error or nil
    if e then return e.code or ("http_" .. tostring(status)), e.message end

    if type(response.errors) == "table" then
        for _, field in ipairs({"usable", "start", "command", "config", "prediction"}) do
            local reason = response.errors[field]
            if type(reason) == "table" then
                return field == "usable" and (reason.code or "not_usable") or "cannot_start",
                       reason.message or reason.text
            end
        end
    end

    return "http_" .. tostring(status), nil
end

local function dispatchFailed(run, token, code, message)
    if run.token ~= token then return end

    run.busy = false
    run.phase = "start"
    run.attempts = (run.attempts or 0) + 1
    run.nextAt = now() + Config.programRetry
    note(run, "retrying", string.format("The step could not start (%s): %s", tostring(code),
                                        tostring(message or "no reason given")))
end

local function dispatched(run, token, program, message)
    if run.token ~= token then return end

    run.busy = false
    run.phase = "active"
    run.dispatchedAt = now()
    run.attempts = 0

    local waiting = conditionsText(program.steps[run.step])
    note(run, "running", message, waiting and ("until " .. waiting) or nil)
end

-- Sends a step's action through its endpoint, and settles the step's tracking with the answer.
local function dispatchAction(owner, shipName, program, run, authority, token, action)
    local path, body = requestFor(shipName, action)
    internalRequest(owner, authority, "POST", path, body, function(status, response)
        response = type(response) == "table" and response or {}

        if type(status) ~= "number" or status >= 300 then
            local code, message = errorOf(status, response)

            -- A ship sent where it already is has arrived: the step's action is over before
            -- it began, and retrying it would be refused the same way for ever.
            if code == "already_there" and (action.type == "route" or action.type == "travel") then
                if run.token ~= token then return end
                run.planEnded = true
                run.arrived = true
                run.returned = true
                dispatched(run, token, program, "Already at " .. ProgramRules.describeDestination(action)
                           .. ", so there is nowhere to fly.")
                return
            end

            dispatchFailed(run, token, code, message)
            return
        end

        if run.token ~= token then return end
        run.planId = response.planId
        run.transferId = response.transferId
        local by = type(response.carriedOutBy) == "table" and response.carriedOutBy or nil
        if by and by.name ~= shipName and type(by.owner) == "table" then
            run.transferShip = {index = by.owner.index, name = by.name}
        end

        -- a target in reach is served inside the confirmation window
        if action.type == "transfer" and type(response.result) == "table" then
            run.transferEnded = true
            run.transferOutcome = response.result.outcome
        end

        -- where a named destination led, as the endpoint resolved it
        local where = ProgramRules.describeDestination(action)
        local resolved = type(response.to) == "table" and response.to
                         or type(response.destination) == "table" and response.destination or nil
        if not action.to and resolved and type(resolved.x) == "number" then
            where = string.format("%s at (%d:%d)", where, resolved.x, resolved.y)
        end

        local what = action.type == "route" and "Flying to " .. where .. "."
                     or action.type == "farm" and "Farming bosses."
                     or action.type == "orders" and "Orders dispatched."
                     or action.type == "travel" and "Travelling to " .. where .. "."
                     or action.type == "transfer" and (function()
                            local text = "Cargo: " .. TransferRules.describe(action, action.target) .. "."
                            local result = response.result
                            if type(result) == "table" then
                                text = text .. string.format(" %s, %d units moved.", tostring(result.outcome),
                                                             Serialize.number(result.total, 0))
                            elseif response.phase then
                                text = text .. " The target is out of reach; the ship is "
                                       .. tostring(response.phase) .. "."
                            end
                            return text
                        end)()
                     or "Standing orders set."
        if status == 202 then what = what .. " The ship did not confirm it yet." end

        dispatched(run, token, program, what)
    end)
end

-- #### TRAVEL LEGS #### --
--
-- A transfer step whose target is in another sector flies there first. The leg is a Travel
-- mission to the target, as a travel step starts one, and when the game refuses those for a
-- target within a jump or behind a gate, a planned route instead. Either request finds the
-- target where it is now, and answers already_there when it is in the ship's sector - which
-- is how a leg that is not needed costs nothing but that answer.
--
-- Once the leg is over the step starts from the top again. A target that moved meanwhile is
-- flown after again; one found in the sector gets its cargo moved.

local function legStarted(run, token, program, kind, action, response)
    if run.token ~= token then return end

    run.leg = {kind = kind}
    if kind == "route" then run.planId = response.planId end

    local where = action.target
    local resolved = type(response.destination) == "table" and response.destination or nil
    if resolved and type(resolved.x) == "number" then
        where = string.format("%s, in (%d:%d)", where, resolved.x, resolved.y)
    end

    dispatched(run, token, program, string.format("Going to %s before the transfer: %s.", where,
               kind == "travel" and "a Travel mission" or "a planned route, as it is too close for a Travel mission"))
end

local function startLeg(owner, shipName, program, run, authority, token, action)
    local base = "/ships/" .. encodeSegment(shipName)
    local destination = {target = action.target, targetOwner = action.targetOwner}

    local function answered(kind, status, response, onRefused)
        if run.token ~= token then return end
        response = type(response) == "table" and response or {}

        if type(status) == "number" and status < 300 then
            legStarted(run, token, program, kind, action, response)
            return
        end

        local code, message = errorOf(status, response)
        if code == "already_there" then
            dispatchAction(owner, shipName, program, run, authority, token, action)
        elseif onRefused and onRefused(code) then
            return
        else
            dispatchFailed(run, token, code, message)
        end
    end

    internalRequest(owner, authority, "POST", base .. "/travel", ProgramRules.copy(destination),
        function(status, response)
            answered("travel", status, response, function(code)
                if code ~= "destination_too_close" then return false end

                internalRequest(owner, authority, "POST", base .. "/route", ProgramRules.copy(destination),
                    function(routeStatus, routeResponse)
                        answered("route", routeStatus, routeResponse)
                    end)
                return true
            end)
        end)
end

local function startStep(owner, index, shipName, program, run, authority)
    local step = program.steps[run.step]
    local action = step.action

    -- A repeat starts the action again: the kills of the plan before it still count.
    run.killsBefore = (run.killsBefore or 0) + (run.planKills or 0)
    resetTracking(run)

    local token = run.token
    run.busy = true
    run.busyUntil = now() + Config.programDispatchTimeout
    note(run, "starting", "Starting " .. stepLabel(program, run.step) .. ".")

    if action.type == "wait" then
        dispatched(run, token, program, "Waiting.")
        return
    end

    if action.type == "mission" then
        local rule
        if action.library then
            rule = MissionLibrary.ruleFor(index, action.library)
            if not rule then
                dispatchFailed(run, token, "no_library_mission",
                               "The library has no mission called '" .. action.library .. "' any more.")
                return
            end
        else
            rule = action.rule or MissionAutomation.ruleFor(index, shipName)
        end
        if not rule then
            dispatchFailed(run, token, "no_mission_rule",
                           "The step flies the craft's mission rule, and it has none. Set one up "
                           .. "in the Automation tab, or give the step a rule of its own.")
            return
        end

        MissionAutomation.startOnce(owner, shipName, rule, authority.index,
            function(summary)
                dispatched(run, token, program, "Out on a mission"
                           .. (action.library and (" (" .. action.library .. ")") or "") .. ": " .. summary)
            end,
            function(code, message) dispatchFailed(run, token, code, message) end)
        return
    end

    if action.type == "transfer" and action.travelToTarget ~= false
       and not ShipData.isStation(owner, shipName) then
        startLeg(owner, shipName, program, run, authority, token, action)
        return
    end

    dispatchAction(owner, shipName, program, run, authority, token, action)
end

local function leaveStep(owner, index, shipName, program, run, authority, reason)
    local step = program.steps[run.step]
    local finishedLabel = stepLabel(program, run.step)

    local function onward()
        local nextIndex = ProgramRules.nextStep(program, run.step)

        if not nextIndex then
            resetTracking(run)
            run.busy = false
            run.phase = "finished"
            note(run, "finished", "The program has run to its end.", finishedLabel .. " done: " .. reason)
            saveCursor(index, shipName, run)
            return
        end

        note(run, "running", finishedLabel .. " done: " .. reason .. ".")
        enterStep(index, shipName, run, nextIndex)
    end

    -- A route or farm still flying would carry on underneath whatever comes next, and so
    -- would a transfer still on its way to the target, or the route flying the ship to it.
    if ((step.action.type == "route" or step.action.type == "farm") and run.planId and not run.planEnded)
       or (step.action.type == "transfer" and run.transferId and not run.transferEnded)
       or (run.leg and run.leg.kind == "route" and run.planId and not run.planEnded) then
        local token = run.token
        local stopping = run.transferShip and run.transferShip.name or shipName
        run.busy = true
        run.busyUntil = now() + Config.programDispatchTimeout
        internalRequest(owner, authority, "POST",
                        "/ships/" .. encodeSegment(stopping) .. "/automation/stop", {},
                        function()
                            if run.token ~= token then return end
                            run.busy = false
                            onward()
                        end,
                        run.transferShip and "all" or nil)
        return
    end

    onward()
end

local function consider(owner, index, shipName, program, run)
    if not owner then
        note(run, "error", "The owning faction no longer exists.")
        run.nextAt = now() + Config.programRetry
        return
    end

    local okOwns, owns = pcall(function() return owner.faction:ownsShip(shipName) end)
    if not okOwns or not owns then
        note(run, "error", "No craft by this name belongs to " .. tostring(owner.name) .. " any more.")
        run.nextAt = now() + Config.programRetry
        return
    end

    local okOnline, online = pcall(function() return Server():isOnline(owner.index) end)
    if not okOnline or not online then
        note(run, "waiting", owner.kind == "alliance"
             and "Waiting for an alliance member to log in: the alliance's agent carries the steps out."
             or "Waiting for the owner to log in: only their agent can carry the steps out.")
        return
    end

    local authority = authorityOf(owner, program)
    if not authority or not MissionAutomation.hasPrivilege(owner, authority.index, AlliancePrivilege.ManageShips) then
        note(run, "error", "The member who last saved this program may no longer manage alliance "
             .. "ships. Saving it again puts it under your own rank.")
        run.nextAt = now() + Config.programRetry
        return
    end

    local step = program.steps[run.step]

    if run.phase == "start" then
        startStep(owner, index, shipName, program, run, authority)
        return
    end

    if run.phase ~= "active" then return end

    local facts = gatherFacts(owner, shipName, run, step)
    local result = ProgramRules.evaluate(step, facts)
    run.conditions = result.met

    if result.done then
        leaveStep(owner, index, shipName, program, run, authority,
                  conditionsText(step) or "its action is over")
        return
    end

    -- On the way to a transfer's target: once there, the step starts again from the top,
    -- which finds the target in the sector and moves the cargo.
    if run.leg then
        local over = run.leg.kind == "route" and run.planEnded or run.leg.kind == "travel" and run.returned
        if over then
            note(run, "running", "The flight to " .. tostring(step.action.target) .. " is over; the "
                 .. "transfer is next.")
            run.phase = "start"
        end
        return
    end

    if facts.naturalEnd and step["repeat"] then
        note(run, "running", stepLabel(program, run.step) .. ": the action is over but the "
             .. "conditions are not met, so it starts again.")
        run.phase = "start"
        return
    end

    if facts.naturalEnd then
        note(run, "running", "Waiting until " .. tostring(conditionsText(step)) .. ".")
    end
end

local function pass()
    local t = now()

    for _, index in ipairs(factionIndices()) do
        local data = loadFaction(index)
        local owner

        for _, shipName in ipairs(sortedKeys(data.ships)) do
            local program = data.ships[shipName]
            local run = runOf(index, shipName, program)

            if run.busy and t > (run.busyUntil or 0) then
                dispatchFailed(run, run.token, "timeout", "The step's action did not answer in time.")
            end

            if not program.enabled then
                if run.status ~= "disabled" and not run.busy then
                    note(run, "disabled", "The program is switched off.")
                end
            elseif run.status ~= "finished" and not run.busy and t >= (run.nextAt or 0) then
                owner = owner or MissionAutomation.ownerOf(index)

                local ok, err = pcall(consider, owner, index, shipName, program, run)
                if not ok then
                    run.busy = false
                    run.nextAt = t + Config.programRetry
                    note(run, "error", Router.isApiError(err) and err.message or tostring(err))
                end
            end
        end
    end
end

local sinceLastPass = 0

function Programs.tick(elapsed)
    sinceLastPass = sinceLastPass + (elapsed or 0)
    if sinceLastPass < Config.programInterval then return end
    sinceLastPass = 0

    pass()
end

-- Mission automation stands aside for a craft whose program is running.
MissionAutomation.controlledBy = function(index, shipName)
    local program = loadFaction(index).ships[shipName]
    if not program or not program.enabled then return nil end

    local run = runs[runKey(index, shipName)]
    if run and run.status == "finished" then return nil end

    return program.name
end

-- The library asks which programs name a mission before deleting it, and has them follow a
-- rename.
local function eachLibraryStep(index, name, fn)
    local data = loadFaction(index)
    for _, shipName in ipairs(sortedKeys(data.ships)) do
        for _, step in ipairs(data.ships[shipName].steps) do
            if step.action.type == "mission" and step.action.library == name then fn(shipName, step) end
        end
    end
    return data
end

MissionLibrary.usersOf = function(index, name)
    local users, seen = {}, {}
    eachLibraryStep(index, name, function(shipName)
        if not seen[shipName] then
            seen[shipName] = true
            users[#users + 1] = shipName
        end
    end)
    return users
end

-- The steps are edited in place, without a new revision: the program is the same program,
-- so a running one carries on where it is.
MissionLibrary.renamed = function(index, oldName, newName)
    local changed = false
    local data = eachLibraryStep(index, oldName, function(_, step)
        step.action.library = newName
        changed = true
    end)
    if changed then saveFaction(index, data) end
end

-- The location library asks the same two questions of route and travel steps.
local function eachLocationStep(index, name, fn)
    local data = loadFaction(index)
    for _, shipName in ipairs(sortedKeys(data.ships)) do
        for _, step in ipairs(data.ships[shipName].steps) do
            if step.action.location == name then fn(shipName, step) end
        end
    end
    return data
end

Locations.usersOf = function(index, name)
    local users, seen = {}, {}
    eachLocationStep(index, name, function(shipName)
        if not seen[shipName] then
            seen[shipName] = true
            users[#users + 1] = shipName
        end
    end)
    return users
end

Locations.renamed = function(index, oldName, newName)
    local changed = false
    local data = eachLocationStep(index, oldName, function(_, step)
        step.action.location = newName
        changed = true
    end)
    if changed then saveFaction(index, data) end
end

-- #### DESCRIPTIONS #### --

local function describeRun(run, program)
    if not run then return nil end

    local step = program.steps[run.step]
    local conditions = Json.array({})

    if step then
        for i, condition in ipairs(step["until"].conditions) do
            conditions[i] =
            {
                text = ProgramRules.describeCondition(condition),
                met = run.conditions and run.conditions[i] == true or false,
            }
        end
    end

    local log = Json.array({})
    for _, line in ipairs(run.log) do log[#log + 1] = line end

    return
    {
        status = run.status,
        message = run.message,
        since = run.since,
        step = run.step,
        stepSince = run.stepSince,
        phase = run.phase,
        busy = run.busy == true,
        attempts = run.attempts or 0,
        nextCheckAt = run.nextAt,
        planId = run.planId,
        -- a transfer step's flight to its target: travel or route
        leg = run.leg and run.leg.kind or nil,
        bossKills = (run.killsBefore or 0) + (run.planKills or 0),
        conditions = conditions,
        log = log,
    }
end

local function describeEntry(owner, shipName, program)
    return
    {
        ship = shipName,
        owner = Owner.describe(owner),
        program = program,
        state = program and describeRun(runs[runKey(owner.index, shipName)]
                                         or runOf(owner.index, shipName, program), program) or nil,
    }
end

local function requireManage(ctx, owner)
    if owner.kind == "alliance"
       and not owner.faction:hasPrivilege(ctx.playerIndex, AlliancePrivilege.ManageShips) then
        Router.fail(403, "missing_privilege",
                    "Your alliance rank does not allow managing alliance ships.")
    end
end

-- #### ENDPOINTS #### --

function Programs.register(r)
    router = r

    router:get("/automation/programs", function(ctx)
        local owners
        if ctx.query.owner == nil or ctx.query.owner == "all" then
            owners = Owner.all(ctx)
        else
            owners = {Owner.resolve(ctx)}
        end

        local programs = Json.array({})
        for _, owner in ipairs(owners) do
            local data = loadFaction(owner.index)
            for _, shipName in ipairs(sortedKeys(data.ships)) do
                programs[#programs + 1] = describeEntry(owner, shipName, data.ships[shipName])
            end
        end

        return
        {
            serverTime = now(),
            programs = programs,
            actions = Json.array(ProgramRules.copy(ProgramRules.actionNames)),
            conditions = Json.array(ProgramRules.copy(ProgramRules.conditionNames)),
            maxSteps = ProgramRules.MAX_STEPS,
        }
    end)

    router:get("/ships/{name}/program", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)
        local body = describeEntry(owner, params.name, loadFaction(owner.index).ships[params.name])
        body.serverTime = now()
        return body
    end)

    -- Creates or replaces the program. Fields left out keep their stored values; `steps`
    -- replaces the steps whole. A change to the steps starts the program over at step 1,
    -- a switch on or off leaves it where it was.
    router:post("/ships/{name}/program", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)
        requireManage(ctx, owner)

        local data = loadFaction(owner.index)
        local previous = data.ships[params.name]

        if ctx.body.ifRevision ~= nil then
            local current = previous and previous.revision or 0
            if ctx.body.ifRevision ~= current then
                Router.fail(409, "program_changed",
                            "Someone changed this program since you loaded it. Reload and apply "
                            .. "your change again.",
                            {revision = current, program = previous or Json.null})
            end
        end

        local program = ProgramRules.normalize(ctx.body, previous)
        local station = ShipData.isStation(owner, params.name)

        for stepIndex, step in ipairs(program.steps) do
            if station and ProgramRules.MOVING[step.action.type] then
                Router.fail(400, "bad_program", string.format(
                            "Step %d: '%s' is a station, which cannot %s. A station's program "
                            .. "sets standing orders, gives orders, moves cargo and waits.", stepIndex,
                            params.name, step.action.type == "mission" and "go on missions"
                            or step.action.type == "farm" and "farm bosses" or "fly anywhere"))
            end

            local library = step.action.type == "mission" and step.action.library
            if library and not MissionLibrary.get(owner.index, library) then
                Router.fail(400, "bad_program", string.format(
                            "Step %d: the %s library has no mission called '%s'.", stepIndex,
                            owner.kind == "alliance" and "alliance's" or "owner's", library))
            end
        end

        local stepsChanged = ctx.body.steps ~= nil
        local run = runs[runKey(owner.index, params.name)]

        program.revision = (previous and previous.revision or 0) + 1
        program.updatedBy = {index = ctx.playerIndex, name = Serialize.string(ctx.player.name, "")}
        program.updatedAt = os.time()

        data.ships[params.name] = program
        saveFaction(owner.index, data)

        if run and not stepsChanged and not run.busy then
            -- same steps under a new revision: carry the run over
            run.revision = program.revision

            if program.enabled and run.status == "disabled" then
                if run.phase == "finished" then
                    note(run, "finished", "The program has run to its end.")
                else
                    -- Nobody knows what the ship did while the program was off, so the step
                    -- it was on starts its action again.
                    run.phase = "start"
                    note(run, "waiting", "Switched on; " .. stepLabel(program, run.step)
                         .. " starts again on the next pass.")
                end
            end

            saveCursor(owner.index, params.name, run)
        else
            runs[runKey(owner.index, params.name)] = nil
            saveCursor(owner.index, params.name, nil)
            local fresh = runOf(owner.index, params.name, program)
            note(fresh, program.enabled and "waiting" or "disabled",
                 program.enabled and "Saved; starts on the next pass." or "The program is switched off.",
                 "saved by " .. program.updatedBy.name)
        end

        local body = describeEntry(owner, params.name, program)
        body.serverTime = now()
        return body
    end)

    router:post("/ships/{name}/program/delete", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)
        requireManage(ctx, owner)

        local data = loadFaction(owner.index)
        local existed = data.ships[params.name] ~= nil

        data.ships[params.name] = nil
        if existed then saveFaction(owner.index, data) end

        runs[runKey(owner.index, params.name)] = nil
        saveCursor(owner.index, params.name, nil)

        return {ship = params.name, owner = Owner.describe(owner), deleted = existed}
    end)

    -- Moves a program: {"action": "restart"} back to step 1, {"action": "goto", "step": n}
    -- to step n. Whatever the current step started is left as it is; the step moved to
    -- starts its own action on the next pass.
    router:post("/ships/{name}/program/control", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)
        requireManage(ctx, owner)

        local program = loadFaction(owner.index).ships[params.name]
        if not program then
            Router.fail(404, "no_program", "'" .. params.name .. "' has no program.")
        end

        local action = ctx.body.action
        local target
        if action == "restart" then
            target = 1
        elseif action == "goto" then
            target = ctx.body.step
            if type(target) ~= "number" or not program.steps[target] then
                Router.fail(400, "bad_step", string.format("'step' is 1 to %d.", #program.steps))
            end
        else
            Router.fail(400, "bad_control", "'action' is restart or goto.")
        end

        local run = runOf(owner.index, params.name, program)
        enterStep(owner.index, params.name, run, target)
        note(run, program.enabled and "waiting" or "disabled",
             "Moved to " .. stepLabel(program, target) .. ".",
             "by " .. Serialize.string(ctx.player.name, ""))

        local body = describeEntry(owner, params.name, program)
        body.serverTime = now()
        return body
    end)
end

-- For tests: forget in-memory state, as a server restart would.
function Programs.resetState()
    runs = {}
    cache = {}
    sinceLastPass = 0
end

return Programs
