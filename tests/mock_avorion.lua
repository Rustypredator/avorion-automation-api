-- Minimal stand-in for the Avorion scripting environment, enough to drive the bridge
-- outside the game. Only what the mod actually touches is implemented.

local M = {}

local root = os.getenv("MOCK_ROOT") or "/tmp/avorion-mock"

local serverValues = {}
local playerValues = {}
local players = {}

local clock = 1000.0

-- #### FILESYSTEM #### --

local function shellQuote(s) return "'" .. string.gsub(s, "'", "'\\''") .. "'" end

function M.install()
    _G.include = function(path)
        return require((string.gsub(path, "/", ".")))
    end

    _G.onClient = function() return false end
    _G.onServer = function() return true end

    _G.printlog = function(fmt, ...)
        if M.verbose then print("[log] " .. string.format(fmt, ...)) end
    end
    _G.eprint = function(fmt, ...)
        M.errors[#M.errors + 1] = string.format(fmt, ...)
        if M.verbose then print("[err] " .. string.format(fmt, ...)) end
    end
    _G.print = _G.print

    _G.createDirectory = function(dir)
        os.execute("mkdir -p " .. shellQuote(dir))
        return 0
    end

    _G.deleteFile = function(file)
        os.remove(file)
        return 0
    end

    _G.listFilesOfDirectory = function(dir)
        local pipe = io.popen("ls -1 " .. shellQuote(dir) .. " 2>/dev/null")
        if not pipe then return end

        local names = {}
        for line in pipe:lines() do names[#names + 1] = line end
        pipe:close()

        return table.unpack(names)
    end

    -- #### GAME OBJECTS #### --

    local server =
    {
        folder = root,
        name = "MockGalaxy",
        seed = "ABCDEFG",
        players = 1,
        maxPlayers = 10,
    }

    setmetatable(server, {__index = function(t, k)
        if k == "unpausedRuntime" or k == "runtime" then return clock end
        return nil
    end})

    function server:setValue(key, value) serverValues[key] = value end
    function server:getValue(key) return serverValues[key] end
    function server:isOnline(index) return players[index] ~= nil and players[index].online end

    _G.Server = function() return server end

    _G.Player = function(index)
        if index == nil then return nil end
        local p = players[index]
        if not p then return nil end

        return p
    end

    _G.GameVersion = function() return "2.5.13" end

    local uuidCounter = 0
    _G.Uuid = function()
        local u = {string = "00000000-0000-0000-0000-000000000000"}
        function u:toRandom()
            uuidCounter = uuidCounter + 1
            -- deterministic but distinct, so tests can assert on key uniqueness
            self.string = string.format("%08x-%04x-%04x-%04x-%012x",
                uuidCounter * 2654435761 % 0xffffffff, uuidCounter % 0xffff,
                (uuidCounter * 7) % 0xffff, (uuidCounter * 13) % 0xffff, uuidCounter)
        end
        return u
    end

    -- Avorion's sandbox breaks os.rename: it returns true, deletes the source and never
    -- creates the destination (verified against 2.5.13). Reproduced here so that any
    -- future attempt to rename inside the mod fails loudly in tests instead of silently
    -- losing data in the game.
    _G.os.rename = function(oldname, newname)
        os.remove(oldname)
        return true
    end

    M.errors = {}
end

-- #### TEST CONTROLS #### --

function M.addPlayer(index, name)
    local values = {}
    playerValues[index] = values

    local p =
    {
        index = index,
        name = name,
        online = true,
    }
    function p:setValue(key, value) values[key] = value end
    function p:getValue(key) return values[key] end
    function p:getValues() return values end

    players[index] = p

    return p
end

function M.setClock(t) clock = t end
function M.advanceClock(dt) clock = clock + dt end
function M.getClock() return clock end
function M.root() return root end

function M.reset()
    os.execute("rm -rf " .. shellQuote(root))
    os.execute("mkdir -p " .. shellQuote(root))
    serverValues = {}
    playerValues = {}
    players = {}
    clock = 1000.0
    M.errors = {}
end

return M
