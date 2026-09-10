-- /apikey - manage Automation API keys from in-game chat.
--
-- Command scripts return exactly three values: (int status, string response,
-- string errorMessage), where 0 means success and 1 means failure - see the vanilla
-- data/scripts/commands/knowledge.lua for the convention.

package.path = package.path .. ";data/scripts/lib/?.lua"

local Auth = include("automationapi/auth")

local usage = [[Usage:
  /apikey new [label]        - create a new API key
  /apikey list               - list your keys by fingerprint
  /apikey revoke <fprint>    - revoke one key
  /apikey revokeall          - revoke every key you own]]

local function formatKeyList(keys)
    if #keys == 0 then
        return "You have no API keys. Create one with /apikey new"
    end

    local lines = {"Your API keys (" .. #keys .. "):"}
    for _, entry in ipairs(keys) do
        local label = entry.label
        if label == "" then label = "(no label)" end

        lines[#lines + 1] = "  " .. entry.fingerprint .. "  " .. label
    end

    return table.concat(lines, "\n")
end

function execute(sender, commandName, ...)
    local args = {...}

    -- The console and RCON run commands with no player attached, and a key has to
    -- belong to somebody.
    if sender == nil then
        return 1, "", "/apikey must be run by a player; the console has no account to attach a key to."
    end

    local player = Player(sender)
    if not player then
        return 1, "", "Could not resolve the calling player."
    end

    local action = string.lower(args[1] or "help")

    if action == "help" then
        return 0, usage, ""
    end

    if action == "new" then
        local label = table.concat(args, " ", 2)

        local key, path = Auth.createKey(sender, label)
        if not key then
            return 1, "", path or "Could not create a key."
        end

        local response = "New Automation API key (store it now, it is not shown again):\n"
                         .. key .. "\nFingerprint: " .. Auth.fingerprint(key)

        -- the chat window cannot be copied from, so point at the file instead
        if path then
            response = response .. "\nAlso written to: " .. path
        end

        return 0, response, ""
    end

    if action == "list" then
        return 0, formatKeyList(Auth.listKeys(sender)), ""
    end

    if action == "revoke" then
        local fingerprint = args[2]
        if not fingerprint or fingerprint == "" then
            return 1, "", "Usage: /apikey revoke <fingerprint>  (see /apikey list)"
        end

        if not Auth.revokeKey(sender, fingerprint) then
            return 1, "", "No key with fingerprint '" .. fingerprint .. "'."
        end

        return 0, "Revoked key " .. fingerprint .. ".", ""
    end

    if action == "revokeall" then
        local count = Auth.revokeAll(sender)
        return 0, "Revoked " .. count .. " key(s).", ""
    end

    return 1, "", "Unknown action '" .. action .. "'.\n" .. usage
end

function getDescription()
    return "Manage Automation API keys"
end

function getHelp()
    return usage
end
