-- Cargo transfers between a ship and another craft of the caller or the caller's alliance.
--
--   GET  /ships/{name}/transfer   the ship's hold and every craft it could transfer with,
--                                 each with its own hold, read from the ship database
--   POST /ships/{name}/transfer   moves goods: give into the target, or take from it
--
-- The move itself is done by the ship, in this mod's orderchain.lua extension, because only
-- a script in the sector can reach both holds and measure how far apart the craft are. So
-- the request is checked here against what the database knows - who owns what, where it
-- is, whether it is out on a mission - and sent as one call; the answer is held until the
-- ship reports the transfer done, refused, or on its way to a target out of reach.
--
-- A station does not fly and has no order chain to carry a transfer out. Named as the
-- craft of a transfer with a ship, the ship does it instead, the other way round: a
-- station that gives, is a ship that takes. Two stations cannot trade holds at all.
--
-- The database is not asked whether the goods are there. A loaded craft's row trails the
-- craft, and a program that mines and then unloads would be refused on a stale hold; the
-- ship reads its real hold and says what it could not move.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Serialize = include("automationapi/serialize")
local Owner = include("automationapi/owner")
local ShipData = include("automationapi/shipdata")
local Enums = include("automationapi/enums")
local TransferRules = include("automationapi/transferrules")
local Missions = include("automationapi/handlers/missions")
local Movement = include("automationapi/handlers/movement")

local Transfer = {}

local nextId = 0

local function transferId()
    nextId = nextId + 1

    local ok, runtime = pcall(function() return Server().unpausedRuntime end)
    return string.format("t%d-%d", nextId, math.floor(ok and runtime or 0))
end

local function requestFail(code, message)
    Router.fail(400, code, message)
end

-- #### READS #### --

local function cargoOf(ownerIndex, name)
    local entry = ShipDatabaseEntry(ownerIndex, name)
    if not entry then return nil end

    local okCargo, cargos, capacity = pcall(function() return entry:getCargo() end)
    local okFree, free = pcall(function() return entry:getFreeCargoSpace() end)
    if not okCargo then return nil end

    capacity = Serialize.number(capacity, 0)
    free = okFree and Serialize.number(free, 0) or 0

    return {capacity = capacity, free = free, used = capacity - free, goods = Serialize.cargoList(cargos)}
end

local function describeCraft(owner, name, from)
    local faction = owner.faction
    local okPosition, x, y = pcall(function() return faction:getShipPosition(name) end)
    local okType, entityType = pcall(function() return faction:getShipType(name) end)
    local availability = faction:getShipAvailability(name)

    local craft =
    {
        name = name,
        owner = Owner.describe(owner),
        type = okType and Enums.name(Enums.entityType, entityType) or nil,
        position = Serialize.vec2(okPosition and x or 0, okPosition and y or 0),
        availability = Enums.name(Enums.shipAvailability, availability),
        cargo = cargoOf(owner.index, name),
    }

    if from then
        craft.sameSector = okPosition and x == from.x and y == from.y or false
    end

    return craft
end

-- Whether the caller may move cargo in or out of this owner's craft. Vanilla asks for
-- ManageShips on both craft of a transfer.
local function mayManage(ctx, owner)
    if owner.kind ~= "alliance" then return true end

    local ok, allowed = pcall(function()
        return owner.faction:hasPrivilege(ctx.playerIndex, AlliancePrivilege.ManageShips)
    end)
    return ok and allowed == true
end

local function requireManage(ctx, owner, what)
    if not mayManage(ctx, owner) then
        Router.fail(403, "missing_privilege",
                    "Your alliance rank does not allow moving cargo " .. what .. " alliance craft.")
    end
end

-- The craft on the other end, looked up among the caller's own and their alliance's.
local function findTarget(ctx, name, ownerKind)
    for _, owner in ipairs(Owner.all(ctx)) do
        if ownerKind == nil or owner.kind == ownerKind then
            local ok, owns = pcall(function() return owner.faction:ownsShip(name) end)
            if ok and owns then return owner end
        end
    end

    Router.fail(404, "no_such_target",
                "Neither you nor your alliance own a craft named '" .. name .. "'.")
end

local function isStation(owner, name)
    local ok, entityType = pcall(function() return owner.faction:getShipType(name) end)
    return ok and entityType == EntityType.Station
end

local function automationOf(event)
    return type(event) == "table" and type(event.automation) == "table" and event.automation
           or nil
end

-- #### ENDPOINTS #### --

function Transfer.register(router)

    -- The ship, its hold, and every other craft of the caller and the caller's alliance
    -- with theirs. `sameSector` marks the ones a transfer can reach right now; the rest are
    -- listed for planning, since a program can fly the ship there first.
    router:get("/ships/{name}/transfer", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)

        local okPosition, x, y = pcall(function() return owner.faction:getShipPosition(params.name) end)
        local from = okPosition and type(x) == "number" and {x = x, y = y} or nil

        local onlySameSector = ctx.query.sameSector == "true" or ctx.query.sameSector == true

        local targets = Json.array({})
        for _, candidate in ipairs(Owner.all(ctx)) do
            if mayManage(ctx, candidate) then
                for _, name in ipairs({candidate.faction:getShipNames()}) do
                    if not (candidate.index == owner.index and name == params.name) then
                        local craft = describeCraft(candidate, name, from)
                        if not onlySameSector or craft.sameSector then
                            targets[#targets + 1] = craft
                        end
                    end
                end
            end
        end

        -- the ones in reach first, then by name
        table.sort(targets, function(a, b)
            if a.sameSector ~= b.sameSector then return a.sameSector == true end
            return a.name < b.name
        end)

        local ship = describeCraft(owner, params.name)
        ship.sector = from and Serialize.vec2(from.x, from.y) or nil
        ship.captain = ShipData.hasCaptain(owner.index, params.name)

        return
        {
            ship = ship,
            targets = targets,
            count = #targets,
        }
    end)

    router:post("/ships/{name}/transfer", function(ctx, params)
        local body = ctx.body
        local owner = Owner.findShip(ctx, params.name)

        -- the request is checked before the world, as /orders does
        local targetName, targetOwnerKind = TransferRules.target(body, requestFail)
        local transfer = TransferRules.normalize(body, requestFail)

        local targetOwner = findTarget(ctx, targetName, targetOwnerKind)

        if targetOwner.index == owner.index and targetName == params.name then
            Router.fail(422, "same_craft", "A craft cannot transfer cargo with itself.")
        end

        requireManage(ctx, owner, "out of or into")
        requireManage(ctx, targetOwner, "out of or into")

        -- Which of the two carries the transfer out: the ship, or the other craft when the
        -- ship named in the path is a station.
        local executor, executorName = owner, params.name
        local other, otherName = targetOwner, targetName
        local direction = transfer.direction

        if isStation(owner, params.name) then
            if isStation(targetOwner, targetName) then
                Router.fail(422, "no_ship",
                            "Neither '" .. params.name .. "' nor '" .. targetName .. "' is a ship, and "
                            .. "only a ship can carry a transfer out.")
            end
            executor, executorName, other, otherName = targetOwner, targetName, owner, params.name
            direction = direction == "give" and "take" or "give"
        end

        -- Only the executing ship has to be orderable. Whether it needs a captain depends
        -- on whether the other craft is in reach, which only the ship can tell.
        local x, y = Movement.requireOrderable(ctx, executor, executorName, nil, {skipCaptain = true})

        local availability = other.faction:getShipAvailability(otherName)
        if availability == ShipAvailability.InBackground then
            Router.fail(409, "target_in_background",
                        "'" .. otherName .. "' is out on a captain mission, and its hold is with it.")
        end

        local okPosition, tx, ty = pcall(function() return other.faction:getShipPosition(otherName) end)
        if not okPosition or tx ~= x or ty ~= y then
            Router.fail(422, "not_same_sector",
                        string.format("'%s' is in (%d:%d) and '%s' in (%s:%s). Cargo only moves "
                                      .. "between craft in the same sector; fly the ship there first.",
                                      executorName, x, y, otherName, tostring(tx), tostring(ty)),
                        {ship = Serialize.vec2(x, y),
                         target = okPosition and Serialize.vec2(tx, ty) or Json.null})
        end

        local id = transferId()

        local payload =
        {
            id = id,
            target = {faction = other.index, name = otherName},
            direction = direction,
            all = transfer.all,
            goods = transfer.goods,
            approach = transfer.approach,
        }

        local response =
        {
            ship = params.name,
            owner = Owner.describe(owner),
            target = {name = targetName, owner = Owner.describe(targetOwner)},
            sector = Serialize.vec2(x, y),
            transferId = id,
            direction = transfer.direction,
            all = transfer.all,
            goods = transfer.goods,
            approach = transfer.approach,
            summary = TransferRules.describe(transfer, targetName),
            -- the ship whose feed carries the transfer: this one, or the target when this
            -- craft is a station
            carriedOutBy = {name = executorName, owner = Owner.describe(executor)},
        }

        return Missions.enqueue
        {
            kind = "orders",
            owner = executor,
            playerIndex = ctx.playerIndex,
            shipName = executorName,
            sector = {x = x, y = y},
            clear = false,
            run = false,
            calls = {{fn = "automationApiTransfer", args = {Json.encode(payload)}}},
            complete = ctx.complete,
            onResult = function()
                Movement.awaitConfirmation
                {
                    owner = executor,
                    shipName = executorName,
                    body = response,
                    complete = ctx.complete,
                    check = function(event)
                        local automation = automationOf(event)
                        if not automation then return nil end

                        local last = automation.lastTransfer
                        if type(last) == "table" and last.id == id then
                            response.result = last
                            response.done = true

                            if last.outcome == "refused" then
                                response.error =
                                {
                                    code = tostring(last.reason or "transfer_refused"),
                                    message = "The ship refused the transfer"
                                              .. (last.message and (": " .. last.message)
                                                  or (last.reason and (": " .. last.reason) or ".")),
                                }
                                return 422
                            end

                            return 200
                        end

                        -- out of reach, and on its way
                        local current = automation.transfer
                        if type(current) == "table" and current.id == id then
                            response.done = false
                            response.phase = current.phase
                            return 200
                        end

                        return nil
                    end,
                }
            end,
        }
    end)

end

return Transfer
