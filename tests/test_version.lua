-- One version, several places that have to agree.
--
-- modinfo.lua is the source of truth: the Workshop resolves the mod by it, and the game
-- parses it standalone before any script runs, so nothing the mod loads can generate it.
-- Every other copy is checked against it here, and tools/bump.sh writes them all at once.

package.path = "data/scripts/lib/?.lua;" .. package.path

local failures = 0
local function check(cond, msg)
    if cond then
        print("  ok   " .. msg)
    else
        failures = failures + 1
        print("  FAIL " .. msg)
    end
end

local function slurp(path)
    local file = assert(io.open(path, "rb"), "cannot read " .. path)
    local content = file:read("*a")
    file:close()
    return content
end

local version = string.match(slurp("modinfo.lua"), 'version%s*=%s*"([^"]+)"')

check(version ~= nil and string.match(version, "^%d+%.%d+%.%d+$") ~= nil,
      "modinfo.lua declares a version: " .. tostring(version))

if not version then
    print("\n1 check(s) failed")
    os.exit(1)
end

-- The runtime value, taken from the module itself rather than by reading the source, so
-- this is the string /ping actually reports. config.lua touches no game objects on load.
local Config = require("automationapi.config")

check(Config.version == version,
      "config.lua matches modinfo.lua (" .. tostring(Config.version) .. ")")

-- Copies in prose. Each is matched by shape, so a stale one is caught rather than a
-- missing one being mistaken for a pass.
local copies =
{
    {
        path = "README.md",
        pattern = "%[!%[version ([%d%.]+)%]",
        what = "the README badge label",
    },
    {
        path = "README.md",
        pattern = "badge/version%-([%d%.]+)%-",
        what = "the README badge image",
    },
    {
        path = "README.md",
        pattern = "AutomationAPI: v([%d%.]+) ready",
        what = "the startup line quoted in the README",
    },
    {
        path = "docs/protocol.md",
        pattern = "AutomationAPI: v([%d%.]+) ready",
        what = "the startup line quoted in docs/protocol.md",
    },
    {
        path = "docs/api.md",
        pattern = '"mod": "([%d%.]+)"',
        what = "the /ping example in docs/api.md",
    },
}

for _, copy in ipairs(copies) do
    local found = string.match(slurp(copy.path), copy.pattern)

    check(found == version,
          copy.what .. " says " .. tostring(found) .. ", modinfo.lua says " .. version)
end

print("")
if failures > 0 then
    print(failures .. " check(s) failed - run tools/bump.sh " .. version)
    os.exit(1)
end
print("all checks passed")
