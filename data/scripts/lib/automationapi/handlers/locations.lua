-- The location library's endpoints. See locations.lua for what a location is and where the
-- library is kept.
--
--   GET  /locations                     every location of the caller and their alliance
--   POST /locations/{name}              creates or changes one: {x, y, note, rename}
--   POST /locations/{name}/delete       removes one no program of its faction names

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Serialize = include("automationapi/serialize")
local Config = include("automationapi/config")
local Owner = include("automationapi/owner")
local Routes = include("automationapi/routes")
local Locations = include("automationapi/locations")

local LocationsHandler = {}

local function sortedKeys(t)
    local keys = {}
    for key, _ in pairs(t) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function requireName(value, field)
    local name = Locations.cleanName(value)
    if not name then
        Router.fail(400, "bad_name", string.format("'%s' must be a name of 1 to %d characters.",
                                                   field, Locations.MAX_NAME))
    end
    return name
end

local function describe(owner, name, entry)
    local usedBy = Json.array({})
    for _, shipName in ipairs(Locations.usersOf(owner.index, name)) do
        usedBy[#usedBy + 1] = shipName
    end

    return
    {
        name = name,
        owner = Owner.describe(owner),
        x = entry.x,
        y = entry.y,
        note = entry.note,
        revision = entry.revision,
        updatedBy = entry.updatedBy,
        updatedAt = entry.updatedAt,
        usedBy = usedBy,
    }
end

function LocationsHandler.register(router)

    router:get("/locations", function(ctx)
        local owners
        if ctx.query.owner == nil or ctx.query.owner == "all" then
            owners = Owner.all(ctx)
        else
            owners = {Owner.resolve(ctx)}
        end

        local locations = Json.array({})
        for _, owner in ipairs(owners) do
            local data = Locations.load(owner.index)
            for _, name in ipairs(sortedKeys(data.locations)) do
                locations[#locations + 1] = describe(owner, name, data.locations[name])
            end
        end

        return {locations = locations, maxName = Locations.MAX_NAME, maxLocations = Config.maxLocations}
    end)

    -- Creates or changes a location, merged over the stored one: a new location needs x and
    -- y, a stored one keeps what is left out. `rename` moves it to a new name, and the
    -- programs naming it follow.
    router:post("/locations/{name}", function(ctx, params)
        local owner = Owner.resolve(ctx)
        local name = requireName(params.name, "name")
        local body = ctx.body

        local data = Locations.load(owner.index)
        local previous = data.locations[name]

        if body.ifRevision ~= nil then
            local current = previous and previous.revision or 0
            if body.ifRevision ~= current then
                Router.fail(409, "location_changed",
                            "Someone changed this location since you loaded it. Reload and "
                            .. "apply your change again.",
                            {revision = current,
                             location = previous and describe(owner, name, previous) or Json.null})
            end
        end

        local newName = name
        if body.rename ~= nil then
            newName = requireName(body.rename, "rename")
            if newName ~= name and data.locations[newName] then
                Router.fail(409, "name_taken", "There is a location called '" .. newName .. "' already.")
            end
        end

        if not previous and Locations.count(owner.index) >= Config.maxLocations then
            Router.fail(409, "too_many_locations",
                        string.format("A library holds at most %d locations.", Config.maxLocations))
        end

        local x, y
        if body.x ~= nil or body.y ~= nil or body.to ~= nil then
            x, y = Routes.coordinates(body.to or body, "location")
        elseif previous then
            x, y = previous.x, previous.y
        else
            Router.fail(400, "bad_coordinates", "A new location needs whole-number 'x' and 'y'.")
        end

        local note = previous and previous.note or nil
        if body.note ~= nil then
            if body.note == Json.null or body.note == "" then
                note = nil
            elseif type(body.note) ~= "string" or #body.note > Locations.MAX_NOTE then
                Router.fail(400, "bad_note",
                            string.format("'note' is text of at most %d characters.", Locations.MAX_NOTE))
            else
                note = body.note
            end
        end

        local entry =
        {
            x = x,
            y = y,
            note = note,
            revision = (previous and previous.revision or 0) + 1,
            updatedBy = {index = ctx.playerIndex, name = Serialize.string(ctx.player.name, "")},
            updatedAt = os.time(),
        }

        data.locations[name] = nil
        data.locations[newName] = entry
        Locations.save(owner.index, data)

        if newName ~= name and previous then Locations.renamed(owner.index, name, newName) end

        return describe(owner, newName, entry)
    end)

    router:post("/locations/{name}/delete", function(ctx, params)
        local owner = Owner.resolve(ctx)
        local name = requireName(params.name, "name")

        local data = Locations.load(owner.index)
        local existed = data.locations[name] ~= nil

        local users = Locations.usersOf(owner.index, name)
        if existed and #users > 0 then
            Router.fail(409, "location_in_use",
                        "Programs still fly to '" .. name .. "': " .. table.concat(users, ", ")
                        .. ". Change their steps first.",
                        {usedBy = Json.array(users)})
        end

        data.locations[name] = nil
        if existed then Locations.save(owner.index, data) end

        return {name = name, owner = Owner.describe(owner), deleted = existed}
    end)
end

return LocationsHandler
