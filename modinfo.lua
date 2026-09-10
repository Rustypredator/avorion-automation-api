meta =
{
    -- Replaced with the Workshop ID if this is ever uploaded there.
    id = "avorion-automation-api",

    name = "AutomationAPI",
    title = "Automation API",

    type = "mod",

    description = [[Exposes ships, captain missions and map knowledge as a JSON API so an
external program can plan and dispatch mining, trading and salvage missions.

Avorion's Lua sandbox has no sockets, so the mod cannot host HTTP itself. It speaks JSON
over files in the galaxy's moddata/AutomationAPI folder; a small HTTP process on the same
machine translates. See docs/protocol.md.]],

    authors = {"Rustypredator"},

    version = "0.1.0",

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
