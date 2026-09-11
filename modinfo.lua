meta =
{
    -- The Steam Workshop ID: the game resolves subscribed mods by it.
    id = "3799355928",

    name = "AutomationAPI",
    title = "Automation API",

    type = "mod",

    description = [[Exposes ships, captain missions and map knowledge as a JSON API so an external program can plan and dispatch mining, trading and salvage missions.]],

    authors = {"Rustypredator"},

    version = "0.1.4",

    dependencies =
    {
        {id = "Avorion", min = "2.5", max = "*.0"},
    },

    -- Nothing here runs on the client: no UI, no rendering, no client scripts.
    serverSideOnly = true,
    clientSideOnly = false,

    -- Adds a galaxy script and player/server values that stop meaning anything once the
    -- mod is removed, so removal is not transparent.
    saveGameAltering = true,

    contact = "https://github.com/Rustypredator/avorion-automation-api",
}
