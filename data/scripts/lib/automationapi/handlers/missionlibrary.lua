-- The mission library: named mission rules a faction keeps for its programs to pick from.
--
-- A library mission is a mission automation rule without a craft - the same mission, area,
-- config, materials, escorts, objective and limits - under a name like "Refine, safe". A
-- program's mission step names one, and the runner loads it when the step starts, so
-- changing a library mission changes every program that flies it from its next start on.
--
-- Where things live, and why:
--
--   * Libraries are Server values, one JSON document per owning faction, for the reasons
--     rules and programs are: the galaxy bridge reads them with nobody logged in, they
--     survive restarts, and an alliance's library is one document every member shares.
--
--   * A library mission belongs to the faction that owns the craft flying it: player craft
--     fly the player's library, alliance craft the alliance's. Each mission carries its own
--     revision, so two members editing different missions do not refuse each other.
--
--   * Programs name missions rather than copying them, so the library has to know who uses
--     what: deleting a mission a program still names is refused, and renaming one renames
--     it in those programs. programs.lua answers both through the hooks below, which keeps
--     this module free of a dependency on it.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Serialize = include("automationapi/serialize")
local Config = include("automationapi/config")
local Owner = include("automationapi/owner")
local MissionRules = include("automationapi/missionrules")
local MissionAutomation = include("automationapi/handlers/missionautomation")

local MissionLibrary = {}

-- The longest name a library mission may have. Names go into steps, logs and paths.
MissionLibrary.MAX_NAME = 48

-- Set by programs.lua. usersOf(index, name) lists the craft whose programs name the
-- mission; renamed(index, old, new) points those programs at the new name.
MissionLibrary.usersOf = function() return {} end
MissionLibrary.renamed = function() end

-- #### HELPERS #### --

local function sortedKeys(t)
    local keys = {}
    for key, _ in pairs(t) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

-- A trimmed, non-empty name of sensible length, or nil.
function MissionLibrary.cleanName(value)
    if type(value) ~= "string" then return nil end
    local name = string.match(value, "^%s*(.-)%s*$")
    if name == "" or #name > MissionLibrary.MAX_NAME then return nil end
    return name
end

local function requireName(value, field)
    local name = MissionLibrary.cleanName(value)
    if not name then
        Router.fail(400, "bad_name", string.format("'%s' must be a name of 1 to %d characters.",
                                                   field, MissionLibrary.MAX_NAME))
    end
    return name
end

-- #### STORE #### --

local cache = {}

local function valueKey(index) return Config.missionLibraryValuePrefix .. tostring(index) end

local function loadFaction(index)
    local raw = Server():getValue(valueKey(index))

    local cached = cache[index]
    if cached and cached.raw == raw then return cached.data end

    local data
    if type(raw) == "string" and raw ~= "" then
        local decoded = Json.decode(raw)
        if type(decoded) == "table" and type(decoded.missions) == "table" then data = decoded end
    end

    data = data or {missions = {}}
    cache[index] = {raw = raw, data = data}

    return data
end

local function saveFaction(index, data)
    local raw
    if next(data.missions) ~= nil then
        local encoded, err = Json.encode({version = 1, missions = data.missions})
        if not encoded then
            Router.fail(500, "encoding_failed", "Could not store the library: " .. tostring(err))
        end
        raw = encoded
    end

    Server():setValue(valueKey(index), raw)
    cache[index] = {raw = raw, data = data}
end

-- The stored entry {rule, revision, updatedBy, updatedAt} for a name, or nil.
function MissionLibrary.get(index, name)
    return loadFaction(index).missions[name]
end

-- The rule a step flies under a library mission's name, as a copy, or nil.
function MissionLibrary.ruleFor(index, name)
    local entry = MissionLibrary.get(index, name)
    return entry and MissionRules.copy(entry.rule) or nil
end

local function describe(owner, name, entry)
    local rule = MissionRules.copy(entry.rule)
    rule.escorts = Json.array(rule.escorts or {})
    if rule.materials then rule.materials = Json.array(rule.materials) end

    local usedBy = Json.array({})
    for _, shipName in ipairs(MissionLibrary.usersOf(owner.index, name)) do
        usedBy[#usedBy + 1] = shipName
    end

    return
    {
        name = name,
        owner = Owner.describe(owner),
        rule = rule,
        revision = entry.revision,
        updatedBy = entry.updatedBy,
        updatedAt = entry.updatedAt,
        usedBy = usedBy,
    }
end

-- #### ENDPOINTS #### --

function MissionLibrary.register(router)

    router:get("/automation/missions/library", function(ctx)
        local owners
        if ctx.query.owner == nil or ctx.query.owner == "all" then
            owners = Owner.all(ctx)
        else
            owners = {Owner.resolve(ctx)}
        end

        local missions = Json.array({})
        for _, owner in ipairs(owners) do
            local data = loadFaction(owner.index)
            for _, name in ipairs(sortedKeys(data.missions)) do
                missions[#missions + 1] = describe(owner, name, data.missions[name])
            end
        end

        return {missions = missions, maxName = MissionLibrary.MAX_NAME}
    end)

    -- Creates or updates a library mission. The body is a rule, as POST
    -- /ships/{name}/mission/automation takes it, merged over the stored one; `rename` moves
    -- it to a new name, and the programs naming it follow.
    router:post("/automation/missions/library/{name}", function(ctx, params)
        local owner = Owner.resolve(ctx, {privilege = AlliancePrivilege.ManageShips})
        local name = requireName(params.name, "name")

        local data = loadFaction(owner.index)
        local previous = data.missions[name]

        if ctx.body.ifRevision ~= nil then
            local current = previous and previous.revision or 0
            if ctx.body.ifRevision ~= current then
                Router.fail(409, "library_changed",
                            "Someone changed this library mission since you loaded it. Reload "
                            .. "and apply your change again.",
                            {revision = current,
                             mission = previous and describe(owner, name, previous) or Json.null})
            end
        end

        local newName = name
        if ctx.body.rename ~= nil then
            newName = requireName(ctx.body.rename, "rename")
            if newName ~= name and data.missions[newName] then
                Router.fail(409, "name_taken", "The library already has a mission called '"
                            .. newName .. "'.")
            end
        end

        local body = MissionRules.copy(ctx.body)
        body.ifRevision, body.rename = nil, nil

        local rule = MissionRules.normalize(body, previous and previous.rule)
        -- A library mission is never switched on or off: the programs naming it decide.
        rule.enabled = nil

        -- A misspelt material is refused now rather than at every start.
        MissionAutomation.checkRule(rule)

        local entry =
        {
            rule = rule,
            revision = (previous and previous.revision or 0) + 1,
            updatedBy = {index = ctx.playerIndex, name = Serialize.string(ctx.player.name, "")},
            updatedAt = os.time(),
        }

        data.missions[name] = nil
        data.missions[newName] = entry
        saveFaction(owner.index, data)

        if newName ~= name and previous then MissionLibrary.renamed(owner.index, name, newName) end

        return describe(owner, newName, entry)
    end)

    router:post("/automation/missions/library/{name}/delete", function(ctx, params)
        local owner = Owner.resolve(ctx, {privilege = AlliancePrivilege.ManageShips})
        local name = requireName(params.name, "name")

        local data = loadFaction(owner.index)
        local existed = data.missions[name] ~= nil

        local users = MissionLibrary.usersOf(owner.index, name)
        if existed and #users > 0 then
            Router.fail(409, "mission_in_use",
                        "Programs still fly '" .. name .. "': " .. table.concat(users, ", ")
                        .. ". Change their mission steps first.",
                        {usedBy = Json.array(users)})
        end

        data.missions[name] = nil
        if existed then saveFaction(owner.index, data) end

        return {name = name, owner = Owner.describe(owner), deleted = existed}
    end)
end

-- For tests: forget in-memory state, as a server restart would.
function MissionLibrary.resetState()
    cache = {}
end

return MissionLibrary
