-- The caller's own API keys: listed, renamed and revoked without leaving the console.
--
--   GET  /keys                        every key this player owns, by fingerprint
--   POST /keys/{fingerprint}          renames one: {label}
--   POST /keys/{fingerprint}/delete   revokes one
--
-- Making a key is deliberately not here and stays /apikey new in game chat. A key already
-- grants everything this API can do, so one that could mint more would outlive its own
-- revocation: whoever took it just makes another while you are busy deleting the first.
-- The owner's chat window is the one place a stolen key cannot reach, which is why a key
-- is born there and only its later life is on the API.
--
-- Keys belong to a player, never to an alliance - Auth stores them in a Player value -
-- so nothing here goes through Owner.resolve, and ?owner= means nothing to it.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Auth = include("automationapi/auth")
local Serialize = include("automationapi/serialize")

local KeysHandler = {}

KeysHandler.MAX_LABEL = 48

-- A label is shown in chat, written into the key file as a comment and drawn in the
-- console, so control characters are not merely untidy: a newline in one would forge a
-- line in that file. Empty is allowed and means "no label".
local function cleanLabel(value)
    if value == nil then return "" end
    if type(value) ~= "string" then
        Router.fail(400, "bad_label", "'label' must be a string.")
    end

    local label = string.match(value, "^%s*(.-)%s*$")
    if string.match(label, "%c") then
        Router.fail(400, "bad_label", "'label' cannot contain control characters.")
    end
    if #label > KeysHandler.MAX_LABEL then
        Router.fail(400, "bad_label",
                    string.format("'label' is at most %d characters.", KeysHandler.MAX_LABEL))
    end

    return label
end

-- Fingerprints are the first 8 characters of a key's hex body, so anything else cannot
-- name a key of this player's and is rejected before it reaches the store.
local function requireFingerprint(value)
    if type(value) ~= "string" or not string.match(value, "^%x%x%x%x%x%x%x%x$") then
        Router.fail(400, "bad_fingerprint",
                    "A fingerprint is the 8 hex characters shown by /apikey list.")
    end

    return string.lower(value)
end

local function describe(ctx)
    local keys = Json.array({})

    for _, entry in ipairs(Auth.listKeys(ctx.playerIndex)) do
        keys[#keys + 1] =
        {
            fingerprint = entry.fingerprint,
            label = Serialize.string(entry.label or ""),
            -- Server uptime when the key was made, not a date: the engine offers no wall
            -- clock a script can trust. `now` below is what it should be read against,
            -- and a key older than this server run reads as a negative age, which is the
            -- honest answer rather than a made-up date.
            created = Serialize.number(entry.created or 0, 0),
            -- The key this very request arrived with. Revoking it is allowed - it is how
            -- you retire the key a console is holding - but a client wants to say so
            -- first.
            current = entry.fingerprint == ctx.keyFingerprint,
        }
    end

    return {keys = keys, now = Serialize.number(Server().unpausedRuntime, 0),
            maxLabel = KeysHandler.MAX_LABEL}
end

function KeysHandler.register(router)

    router:get("/keys", function(ctx)
        return describe(ctx)
    end)

    router:post("/keys/{fingerprint}", function(ctx, params)
        local fingerprint = requireFingerprint(params.fingerprint)

        if ctx.body.label == nil then
            Router.fail(400, "bad_label", "Send a 'label' to rename this key.")
        end

        if not Auth.renameKey(ctx.playerIndex, fingerprint, cleanLabel(ctx.body.label)) then
            Router.fail(404, "unknown_key", "You own no key with that fingerprint.")
        end

        return describe(ctx)
    end)

    router:post("/keys/{fingerprint}/delete", function(ctx, params)
        local fingerprint = requireFingerprint(params.fingerprint)

        -- Read before the revoke, because afterwards there is nothing left to ask.
        local current = fingerprint == ctx.keyFingerprint

        if not Auth.revokeKey(ctx.playerIndex, fingerprint) then
            Router.fail(404, "unknown_key", "You own no key with that fingerprint.")
        end

        -- The answer is written by the transport after the key is already gone, so this
        -- request is the last one that key will ever complete.
        local result = describe(ctx)
        result.revoked = fingerprint
        result.wasCurrent = current

        return result
    end)

end

return KeysHandler
