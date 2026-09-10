-- This is always the first script that is executed for the galaxy

-- Note: This script does not get attached to the Galaxy
-- Note: This script is called BEFORE any other scripts are initialized
-- Note: When loading from Database, other scripts attached to the Galaxy are available through Galaxy():hasScript() etc.
-- Note: When adding scripts to the galaxy from here with addScript() or addScriptOnce(),
--       the added scripts will NOT get initialized immediately,
--       their initialization order is not defined,
--       parameters passed in addition to the script name will be IGNORED and NOT passed to the script's initialize() function,
--       and the script will instead be treated as if loaded from database, with the _restoring variable set in its initialize() function

Galaxy():addScriptOnce("server.lua")

Galaxy():addScriptOnce("internal/dlc/blackmarket/galaxy/convoyevent.lua")
Galaxy():addScriptOnce("data/scripts/galaxy/behemothevent.lua")

-- Automation API (https://github.com/Rustypredator/avorion-automation-api)
-- Overlay of the vanilla file: everything above is stock, this is the only addition.
Galaxy():addScriptOnce("data/scripts/galaxy/automationapi/bridge.lua")
