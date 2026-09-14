
if onServer() then

local alliance = Alliance()
alliance:addScriptOnce("data/scripts/player/background/simulation/simulation.lua")
alliance:addScriptOnce("data/scripts/player/background/simulation/shipappearances.lua")
alliance:addScriptOnce("data/scripts/player/background/lostships.lua")

-- avorion-automation-api: an alliance's Simulation can only be called from the alliance's
-- own script thread - a player script gets result code 7 - so the agent that runs API
-- jobs is attached here too. It notices where it runs and claims only alliance jobs.
alliance:addScriptOnce("data/scripts/player/automationapi/agent.lua")

if not alliance:getValue("gates2.0") then
    alliance:addScriptOnce("data/scripts/player/background/gatemapcompatibility.lua")
end

end
