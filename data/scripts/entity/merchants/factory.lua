
-- Automation API (https://github.com/Rustypredator/avorion-automation-api)
--
-- Appended to the game's own factory.lua, not a replacement for it: Avorion inserts a mod's
-- copy of a file ahead of the vanilla file's final `return`, which is the only way to reach
-- the production state factory.lua keeps in file locals. Everything this does is in
-- automationapi/stationhooks.lua; see there for what is recorded and why.
if onServer() then
    local ok, err = pcall(function()
        include("automationapi/stationhooks").factory(Factory, function()
            return production, newProductionError, currentProductions
        end)
    end)

    if not ok then eprint("AutomationAPI: production recording not installed: %s", tostring(err)) end
end
