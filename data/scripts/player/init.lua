-- This is always the first script that is executed for a logged in player
-- Offline players don't have running scripts

-- Note: This script does not get attached to the Player
-- Note: This script is called BEFORE any other scripts are initialized
-- Note: When loading from Database, other scripts attached to the Player are available through Player():hasScript() etc.
-- Note: When adding scripts to the player from here with addScript() or addScriptOnce(),
--       the added scripts will NOT get initialized immediately,
--       their initialization order is not defined,
--       parameters passed in addition to the script name will be IGNORED and NOT passed to the script's initialize() function,
--       and the script will instead be treated as if loaded from database, with the _restoring variable set in its initialize() function
-- Note: Player scripts are initialized once the player's sector was loaded and the player is placed inside, not on log-in.

if onServer() then

local player = Player()

-- make sure that async execution always works again once the player relogs
player:setValue("block_async_execution", nil)

player:addScriptOnce("map/mapcommands.lua")
player:addScriptOnce("map/economyinfo.lua")
player:addScriptOnce("client/musiccoordinator.lua")

player:addScriptOnce("ui/playerdiplomacy.lua")
player:addScriptOnce("ui/alliancediplomacy.lua")
player:addScriptOnce("ui/sectorshipoverview.lua")
player:addScriptOnce("ui/badcargoshipproblem.lua")
player:addScriptOnce("ui/enemystrengthindicators.lua")
player:addScriptOnce("ui/encyclopedia/encyclopedia.lua")
player:addScriptOnce("ui/profile/playerprofile.lua")

player:addScriptOnce("background/homesectorrelations.lua")
player:addScriptOnce("background/tutorialstarter.lua")
player:addScriptOnce("background/exodussectorgenerator.lua")
player:addScriptOnce("background/traderharassment.lua")
player:addScriptOnce("background/storystarter.lua")
player:addScriptOnce("background/factionwelcomingmails.lua")
player:addScriptOnce("background/simulation/simulation.lua")
player:addScriptOnce("background/simulation/shipappearances.lua")

-- avorion-automation-api: the write side of the API has to run as a player script.
-- A galaxy script cannot call Player:invokeFunction - the engine segfaults - so the
-- galaxy bridge queues writes and this agent executes them.
player:addScriptOnce("automationapi/agent.lua")

player:addScriptOnce("events/headhunter.lua")
player:addScriptOnce("events/eventscheduler.lua")
player:addScriptOnce("events/spawnasteroidboss.lua")
player:addScriptOnce("story/spawnrandombosses.lua")
player:addScriptOnce("story/spawnguardian.lua")

player:addScriptOnce("data/scripts/player/background/lostships.lua")
player:addScriptOnce("data/scripts/player/background/attachdebugscript.lua")

if not player:getValue("gates2.0") then
    player:addScriptOnce("background/gatemapcompatibility.lua")
end

-- Add story script again, if it isn't there and story completed flag is not set
if player:getValue("story_advance") and not player:getValue("story_completed") then
    if GameSettings().storyline then
        player:addScriptOnce("background/storyquestutility.lua")
    end
end

-- Add Black Market DLC intro missions to player if they're not completed
if player.ownsBlackMarketDLC and not player:getValue("accomplished_intro_missions") and player:getValue("accomplished_intro_1") then
    player:addScriptOnce("internal/dlc/blackmarket/player/missions/intro/intromissionutility.lua")
end

-- Add syndicate mission framework if player completed intro, this script is necessary to play syndicate storyline which can be played endlessly
if player.ownsBlackMarketDLC and player:getValue("accomplished_intro_missions") then
    player:addScriptOnce("internal/dlc/blackmarket/player/background/syndicateframeworkmission.lua")
end

-- Add reveal black market script again, it is necessary for interacting with black markets and doing black market trader events
-- At the same time add script that will periodically try to add black market event
if player.ownsBlackMarketDLC and player:getValue("can_reveal_black_markets") then
    player:addScriptOnce("internal/dlc/blackmarket/player/background/revealblackmarkets.lua")
    player:addScriptOnce("internal/dlc/blackmarket/player/background/blackmarketeventstarter.lua")
end

-- Add rift story script
if player.ownsIntoTheRiftDLC then
    player:addScriptOnce("internal/dlc/rift/player/story/riftstorycampaign.lua")
end

-- only in creative or if enabled in free play settings
if GameSettings().creativeModeCommandCenter then
    player:addScriptOnce("ui/creativemodemenu.lua")
end


end
