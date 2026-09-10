-- Provides getParentFaction() while vanilla command code is running.
--
-- The background simulation normally lives on a Player or Alliance script, where the
-- engine supplies getParentFaction(). This mod drives the same command objects from a
-- galaxy script - which is what lets read endpoints work with nobody logged in - so that
-- global is missing. Most of the prediction and validation paths use
-- Galaxy():findFaction(ownerIndex) instead, but a few reach for getParentFaction(), and
-- one nil call would take out the request.
--
-- The previous value is restored afterwards, so nothing outside the call is affected.

local FactionScope = {}

function FactionScope.with(faction, fn, ...)
    local previous
    local installed = pcall(function()
        previous = rawget(_G, "getParentFaction")
        _G.getParentFaction = function() return faction end
    end)

    local results = {pcall(fn, ...)}

    if installed then
        pcall(function() _G.getParentFaction = previous end)
    end

    local ok = table.remove(results, 1)
    if not ok then error(results[1], 0) end

    return table.unpack(results)
end

return FactionScope
