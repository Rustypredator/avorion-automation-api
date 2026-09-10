-- Ship listing and inspection.
--
-- These endpoints read the ship database directly, so they work for craft in unloaded
-- sectors and while the owning player is offline.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Owner = include("automationapi/owner")
local ShipData = include("automationapi/shipdata")

local Ships = {}

-- getShipNames() returns ships and stations together; callers usually want one or the
-- other. Defaults to ships, since those are what missions can be flown with.
local function wantedTypes(ctx)
    local requested = ctx.query.type

    if requested == nil or requested == "ship" then return {Ship = true} end
    if requested == "station" then return {Station = true} end
    if requested == "all" then return nil end

    Router.fail(400, "bad_type",
                "Unknown type '" .. tostring(requested) .. "'. Use 'ship', 'station' or 'all'.")
end

local function ownersFor(ctx)
    if ctx.query.owner == "all" then return Owner.all(ctx) end

    return {Owner.resolve(ctx)}
end

function Ships.register(router)

    router:get("/ships", function(ctx)
        local types = wantedTypes(ctx)

        local result = Json.array({})

        for _, owner in ipairs(ownersFor(ctx)) do
            for _, name in ipairs({owner.faction:getShipNames()}) do
                local summary = ShipData.summary(owner, name)

                if types == nil or types[summary.type] then
                    result[#result + 1] = summary
                end
            end
        end

        table.sort(result, function(a, b) return a.name < b.name end)

        return {ships = result, count = #result}
    end)

    router:get("/ships/{name}", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)

        local detail = ShipData.detail(owner, params.name)
        if not detail then
            -- owned according to the faction, but no database row: a ship mid-creation,
            -- or one destroyed between the two reads
            Router.fail(404, "no_ship_data",
                        "No database entry for '" .. params.name .. "'.")
        end

        return detail
    end)

end

return Ships
