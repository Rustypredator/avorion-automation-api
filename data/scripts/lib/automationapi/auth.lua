-- API key storage and lookup.
--
-- A key maps to exactly one player index. Player *names* are deliberately not used as
-- identity anywhere: the Avorion docs warn twice that they can change via Steam and that
-- two players can share one.
--
-- Keys are stored in plaintext in the galaxy's globals file. That is a deliberate
-- trade-off, not an oversight: anyone who can read that file can already read and write
-- the request directory this API is driven through, so hashing would buy nothing. See
-- docs/protocol.md.

local Json = include("automationapi/json")
local Config = include("automationapi/config")

local Auth = {}

-- #### KEY GENERATION #### --

local function randomHex()
    local uuid = Uuid()
    uuid:toRandom()

    -- Uuid().string is hyphenated; we want a flat token
    return string.gsub(string.lower(uuid.string), "[^0-9a-f]", "")
end

-- 256 bits, drawn from two independent random UUIDs.
function Auth.generateKey()
    return Config.keyPrefix .. randomHex() .. randomHex()
end

-- Short, safe-to-display handle for a key. Never enough to reconstruct one.
function Auth.fingerprint(key)
    if type(key) ~= "string" then return nil end

    local body = string.sub(key, #Config.keyPrefix + 1)
    return string.sub(body, 1, 8)
end

-- #### PER-PLAYER KEY LIST #### --

-- Player values are POD only, so the list is kept as a JSON string.
local function loadKeys(player)
    local raw = player:getValue(Config.playerKeysValue)
    if not raw or raw == "" then return {} end

    local decoded = Json.decode(raw)
    if type(decoded) ~= "table" then return {} end

    return decoded
end

local function saveKeys(player, keys)
    if #keys == 0 then
        player:setValue(Config.playerKeysValue, nil)
        return
    end

    player:setValue(Config.playerKeysValue, Json.encode(Json.array(keys)))
end

-- #### PUBLIC API #### --

-- Returns the new key string.
function Auth.createKey(playerIndex, label)
    local player = Player(playerIndex)
    if not player then return nil, "Player not found." end

    local key = Auth.generateKey()

    Server():setValue(Config.keyValuePrefix .. key, playerIndex)

    local keys = loadKeys(player)
    keys[#keys + 1] =
    {
        key = key,
        label = label or "",
        created = Server().unpausedRuntime,
    }
    saveKeys(player, keys)

    return key
end

-- Returns the owning player index, or nil.
function Auth.resolve(key)
    if type(key) ~= "string" then return nil end
    if string.sub(key, 1, #Config.keyPrefix) ~= Config.keyPrefix then return nil end

    -- reject anything with characters that could confuse the value-key namespace
    if string.match(key, "[^%w_]") then return nil end

    local index = Server():getValue(Config.keyValuePrefix .. key)
    if type(index) ~= "number" then return nil end

    return index
end

-- Returns an array of {fingerprint, label, created}, safe to show a player.
function Auth.listKeys(playerIndex)
    local player = Player(playerIndex)
    if not player then return {} end

    local result = {}
    for _, entry in ipairs(loadKeys(player)) do
        result[#result + 1] =
        {
            fingerprint = Auth.fingerprint(entry.key),
            label = entry.label or "",
            created = entry.created or 0,
        }
    end

    return result
end

-- Returns true if a key was removed.
function Auth.revokeKey(playerIndex, fingerprint)
    local player = Player(playerIndex)
    if not player then return false end

    local keys = loadKeys(player)
    local remaining = {}
    local removed = false

    for _, entry in ipairs(keys) do
        if not removed and Auth.fingerprint(entry.key) == fingerprint then
            Server():setValue(Config.keyValuePrefix .. entry.key, nil)
            removed = true
        else
            remaining[#remaining + 1] = entry
        end
    end

    if removed then saveKeys(player, remaining) end

    return removed
end

-- Removes every key a player owns. Returns how many went.
function Auth.revokeAll(playerIndex)
    local player = Player(playerIndex)
    if not player then return 0 end

    local keys = loadKeys(player)
    for _, entry in ipairs(keys) do
        Server():setValue(Config.keyValuePrefix .. entry.key, nil)
    end

    saveKeys(player, {})

    return #keys
end

return Auth
