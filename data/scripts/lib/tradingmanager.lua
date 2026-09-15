
-- Automation API (https://github.com/Rustypredator/avorion-automation-api)
--
-- Appended to the game's own tradingmanager.lua, not a replacement for it: Avorion inserts
-- a mod's copy of a file ahead of the vanilla file's final `return`, which is what puts the
-- file-local TradingManager class in reach here. Everything this does is in
-- automationapi/stationhooks.lua; see there for what is recorded and why.
if onServer() then
    local ok, err = pcall(function()
        include("automationapi/stationhooks").trading(TradingManager)
    end)

    if not ok then eprint("AutomationAPI: trade recording not installed: %s", tostring(err)) end
end
