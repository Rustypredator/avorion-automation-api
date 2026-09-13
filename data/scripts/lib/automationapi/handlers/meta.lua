-- Service metadata: the endpoint a client calls first to check it is talking to
-- something it understands.

local Config = include("automationapi/config")
local Json = include("automationapi/json")
local Serialize = include("automationapi/serialize")

local Meta = {}

function Meta.register(router)

    router:get("/ping", function(ctx)
        local server = Server()

        local player = ctx.player
        local online = false
        if player then
            local ok, result = pcall(function() return server:isOnline(ctx.playerIndex) end)
            online = ok and result or false
        end

        -- An explicit null rather than an absent field, so a client can tell "not in an
        -- alliance" from a mod too old to say. The HTTP bridge decides who may read an
        -- alliance's shared history off exactly this field.
        local alliance = Json.null
        local ok, found = pcall(function() return player and player.alliance end)
        if ok and found then
            alliance = {index = found.index, name = Serialize.string(found.name)}
        end

        return
        {
            api = Config.apiVersion,
            mod = Config.version,
            -- reported so a planner can tell "the mod broke" from "the game moved"
            game = Serialize.string(GameVersion()),
            galaxy =
            {
                name = Serialize.string(server.name),
                seed = Serialize.string(server.seed),
            },
            server =
            {
                runtime = Serialize.number(server.unpausedRuntime, 0),
                players = Serialize.number(server.players, 0),
            },
            player =
            {
                index = ctx.playerIndex,
                name = player and Serialize.string(player.name) or nil,
                online = online,
                alliance = alliance,
            },
        }
    end)

end

return Meta
