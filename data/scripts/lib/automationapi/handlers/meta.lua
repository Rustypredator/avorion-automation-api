-- Service metadata: the endpoint a client calls first to check it is talking to
-- something it understands.

local Config = include("automationapi/config")
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
            },
        }
    end)

end

return Meta
