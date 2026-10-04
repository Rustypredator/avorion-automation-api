-- The inventory endpoints and the trash manager: what a listing reports for each kind of
-- item, what a filter and a rule can say about one, and that a sweep marks what it should
-- without doing it all in one tick.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local Mock = require("mock_avorion")
Mock.install()
Mock.reset()

local Json = require("automationapi.json")
local Config = require("automationapi.config")
local Auth = require("automationapi.auth")
local Items = require("automationapi.items")
local ItemRules = require("automationapi.itemrules")

dofile("data/scripts/galaxy/automationapi/bridge.lua")
local Bridge = AutomationApiBridge

local failures = 0
local function check(cond, msg)
    if cond then print("  ok   " .. msg)
    else failures = failures + 1; print("  FAIL " .. msg) end
end

-- #### WORLD #### --

Mock.addPlayer(1, "Rustypredator")
Mock.addPlayer(2, "Someone Else")
Mock.addAlliance(9, "Rusty Co", 1, {[AlliancePrivilege.SpendItems] = true})

local T = {turret = 0, template = 1, upgrade = 2, item = 3, usable = 4}
local R = {petty = -1, common = 0, uncommon = 1, rare = 2, exceptional = 3,
           exotic = 4, legendary = 5}

-- A spread wide enough that every filter below has something to include and something to
-- leave out. Indices are explicit and sparse, because the engine's are.
local slots = {}

slots.pea      = Mock.addItem(1, {index = 0, type = T.turret, name = "Pea Shooter",
                                  rarity = R.petty, dps = 12, category = 0, slotType = 1,
                                  material = 0, averageTech = 3, title = "Petty Pea Shooter"})
slots.chaingun = Mock.addItem(1, {index = 3, type = T.turret, name = "Chaingun Turret",
                                  rarity = R.rare, dps = 480, category = 0, slotType = 1,
                                  material = 3, averageTech = 22,
                                  shieldDamageMultiplier = 0.2, hullDamageMultiplier = 1.5})
slots.railgun  = Mock.addItem(1, {index = 4, type = T.turret, name = "Railgun Turret",
                                  rarity = R.exotic, dps = 2100, category = 0, slotType = 1,
                                  material = 6, averageTech = 48, coaxial = true})
slots.miner    = Mock.addItem(1, {index = 7, type = T.turret, name = "Mining Turret",
                                  rarity = R.common, dps = 30, category = 1, slotType = 2,
                                  bestEfficiency = 0.3, armed = false, amount = 4})
slots.salvage  = Mock.addItem(1, {index = 8, type = T.turret, name = "Salvaging Turret",
                                  rarity = R.uncommon, dps = 55, category = 2, slotType = 2,
                                  bestEfficiency = 0.5, armed = false})
slots.loved    = Mock.addItem(1, {index = 11, type = T.turret, name = "Lucky Gun",
                                  rarity = R.petty, dps = 1, category = 0, favorite = true})
slots.upgrade  = Mock.addItem(1, {index = 12, type = T.upgrade, name = "Cargo Extension",
                                  rarity = R.rare, price = 25000})
slots.quest    = Mock.addItem(1, {index = 13, type = T.upgrade, name = "XSTN-K III",
                                  rarity = R.legendary, missionRelevant = true})
slots.usable   = Mock.addItem(1, {index = 16, type = T.usable, name = "Reconstruction Kit",
                                  rarity = R.exotic, price = 500000})

Mock.addItem(9, {index = 0, type = T.turret, name = "Alliance Popgun", rarity = R.petty,
                 dps = 5, category = 0})

Bridge.initialize()

local key = Auth.createKey(1, "tests")
local otherKey = Auth.createKey(2, "tests")
local seq = 0

local function send(method, path, body, query, withKey)
    seq = seq + 1
    local id = "t" .. seq

    local f = assert(io.open(Config.getRequestsDir() .. "/" .. id .. ".json", "wb"))
    f:write(Json.encode{id = id, key = withKey or key, method = method, path = path,
                        body = body or {}, query = query or {}})
    f:close()

    Bridge.update(Config.pollInterval)

    local rf = io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb")
    if not rf then return nil end
    local res = Json.decode(rf:read("*all")); rf:close()

    return res.status, res.body
end

local function call(method, path, body, query, withKey)
    local status, answer = send(method, path, body, query, withKey)
    return status, answer
end

local function byIndex(list, index)
    for _, entry in ipairs(list or {}) do if entry.index == index then return entry end end
    return nil
end

local function names(list)
    local out = {}
    for _, entry in ipairs(list or {}) do out[#out + 1] = entry.name end
    table.sort(out)
    return table.concat(out, ", ")
end

-- #### READING #### --

print("\nGET /inventory")

local status, body = call("GET", "/inventory", nil, {pageSize = "50"})
check(status == 200 and #body.items == 9, "every occupied slot, and only the caller's")
check(body.inventory.occupied == 9 and body.inventory.maxSlots == 1000,
      "and what the inventory itself reports")

local pea = byIndex(body.items, 0)
check(pea and pea.index == 0, "a slot index of 0 survives the trip (the engine's are 0-based)")
check(pea and pea.type == "turret" and pea.rarity.name == "Petty" and pea.dps == 12,
      "a turret reports its type, rarity and dps")
check(pea and pea.title == "Petty Pea Shooter",
      "and its title, which the engine hands over as a Format object rather than a string")

local chaingun = byIndex(body.items, 3)
check(chaingun and chaingun.hullDps == 720 and chaingun.shieldDps == 96,
      "damage multipliers are applied, so two guns of one dps are comparable")

local upgrade = byIndex(body.items, 12)
check(upgrade and upgrade.type == "upgrade" and upgrade.price == 25000 and upgrade.dps == nil,
      "a system upgrade reports a price and no weapon stats")
check(upgrade and upgrade.tradeable == nil,
      "and is not asked for fields its type does not carry - the engine raises on those")

local miner = byIndex(body.items, 7)
check(miner and miner.amount == 4, "a stack reports how many it holds")

-- #### FILTERS #### --

print("\nfilters")

status, body = call("GET", "/inventory", nil, {type = "turret"})
check(status == 200 and body.matched == 6, "by item type")

status, body = call("GET", "/inventory", nil, {category = "Mining"})
check(status == 200 and names(body.items) == "Mining Turret", "by weapon category")

status, body = call("GET", "/inventory", nil, {rarityMin = "rare"})
check(status == 200 and body.matched == 5, "by rarity floor, spelled however the caller likes")

status, body = call("GET", "/inventory", nil, {rarityMin = "Rare", rarityMax = "Exotic"})
check(status == 200 and body.matched == 4, "and between two rarities")

status, body = call("GET", "/inventory", nil, {dpsMin = "100"})
check(status == 200 and names(body.items) == "Chaingun Turret, Railgun Turret", "by dps")

status, body = call("GET", "/inventory", nil, {search = "turret"})
check(status == 200 and body.matched == 4, "by a piece of the name, ignoring case")

status, body = call("GET", "/inventory", nil, {tag = "favorite"})
check(status == 200 and names(body.items) == "Lucky Gun", "by what is already tagged")

status, body = call("GET", "/inventory", nil, {tag = "sideways"})
check(status == 400 and body.error.code == "bad_query", "and an unknown tag is refused")

status, body = call("GET", "/inventory", nil, {rarityMin = "Shiny"})
check(status == 400 and body.error.code == "bad_rule", "as is a rarity that does not exist")

-- A filter on a stat the item type does not have must not sweep that type up. This is the
-- rule that stops "dps at most 400" from matching every system upgrade in the inventory.
status, body = call("GET", "/inventory", nil, {dpsMax = "400", pageSize = "50"})
check(status == 200 and names(body.items) == "Lucky Gun, Mining Turret, Pea Shooter, Salvaging Turret",
      "an item with no dps at all matches no dps threshold, in either direction")

print("\nsorting and paging")

status, body = call("GET", "/inventory", nil, {sort = "dps", order = "desc", pageSize = "2"})
check(status == 200 and body.items[1].name == "Railgun Turret"
      and body.items[2].name == "Chaingun Turret", "sorted by a stat, highest first")
check(body.matched == 9 and body.page == 1 and #body.items == 2,
      "paged, with the full count still reported")

status, body = call("GET", "/inventory", nil, {sort = "dps", order = "desc", pageSize = "50"})
check(status == 200 and body.items[#body.items].dps == nil,
      "an item without the stat sorts last rather than first")

status, body = call("GET", "/inventory", nil, {sort = "nonsense"})
check(status == 400 and body.error.code == "bad_sort", "an unknown sort is refused")

print("\nPOST /inventory/search")

status, body = call("POST", "/inventory/search",
                    {conditions = {{stat = "type", op = "is", value = "turret"},
                                   {stat = "dps", op = "atMost", value = 100},
                                   {stat = "favorite", op = "is", value = false}}})
check(status == 200 and names(body.items) == "Mining Turret, Pea Shooter, Salvaging Turret",
      "every condition has to hold")

status, body = call("POST", "/inventory/search",
                    {conditions = {{stat = "material", op = "atLeast", value = "Trinium"}}})
check(status == 200 and names(body.items) == "Chaingun Turret, Railgun Turret",
      "materials are ordered, so a floor means something")

status, body = call("POST", "/inventory/search",
                    {conditions = {{stat = "category", op = "oneOf", value = {"Mining", "Salvaging"}}}})
check(status == 200 and body.matched == 2, "oneOf takes a list")

status, body = call("POST", "/inventory/search", {conditions = {{stat = "dps", op = "contains", value = "x"}}})
check(status == 400 and body.error.code == "bad_rule", "a stat cannot be compared in a way it has no meaning for")

print("\nGET /inventory/stats and /inventory/vocabulary")

status, body = call("GET", "/inventory/stats")
check(status == 200 and body.byType.turret == 6 and body.byType.upgrade == 2,
      "counted by type")
check(body.byRarity.Petty == 2 and body.byCategory.Armed == 4, "by rarity and category")
check(body.items == 12 and body.slots == 9, "stacks counted as what they hold, slots as slots")

status, body = call("GET", "/inventory/vocabulary")
check(status == 200 and #body.stats > 20 and #body.rarities == 7,
      "the whole vocabulary, so a console need not hardcode it")

-- #### TAGS BY HAND #### --

print("\nPOST /inventory/tags")

status, body = call("POST", "/inventory/tags", {indices = {0, 3}, mark = "trash"})
check(status == 200 and body.changed == 2, "marks several slots at once")
check(Mock.itemAt(1, 0).trash == true and Mock.itemAt(1, 3).trash == true,
      "and the engine has them")

status, body = call("POST", "/inventory/tags", {items = {{index = 0, favorite = true}}})
check(status == 200 and Mock.itemAt(1, 0).favorite == true and Mock.itemAt(1, 0).trash == false,
      "favouriting something clears its trash mark - the game shows one flag, not two")

status, body = call("POST", "/inventory/tags", {indices = {0}, mark = "none"})
check(status == 200 and Mock.itemAt(1, 0).favorite == false, "and 'none' clears both")

status, body = call("POST", "/inventory/tags", {indices = {99}, mark = "trash"})
check(status == 200 and body.results[1].ok == false and body.results[1].reason == "gone",
      "a slot that emptied since the caller listed it is reported, not guessed at")

status, body = call("POST", "/inventory/tags", {indices = {3}, mark = "trash"})
check(status == 200 and body.results[1].reason == "unchanged" and body.changed == 0,
      "and a write that would change nothing is not made")

status, body = call("POST", "/inventory/tags", {})
check(status == 400 and body.error.code == "no_items", "something has to be asked for")

call("POST", "/inventory/tags", {indices = {3}, mark = "none"})

-- #### THE RULES #### --

print("\nrule validation")

local function refused(payload)
    local s, b = call("POST", "/inventory/trash", payload)
    return s == 400 and b.error.code or nil
end

check(refused({rules = {{name = "x", mark = "trash"}}}) == "bad_rule",
      "a trash rule with no conditions would mark the whole inventory, so it is refused")
check(refused({rules = {{name = "x", mark = "sell"}}}) == "bad_rule", "marks are trash, favorite or keep")
check(refused({rules = {{name = "", mark = "trash"}}}) == "bad_rule", "a rule needs a name")
check(refused({rules = {{name = "a", mark = "trash", conditions = {{stat = "glory", op = "is", value = 1}}}}})
      == "bad_rule", "and conditions the API understands")
check(refused({rules = {{name = "dup", mark = "keep"}, {name = "DUP", mark = "keep"}}}) == "bad_rule",
      "two rules cannot share a name")

status, body = call("POST", "/inventory/trash", {rules = {{name = "catch all", mark = "keep"}}})
check(status == 200, "a catch-all KEEP rule is allowed - it is how 'and nothing else' is written")

print("\nPOST /inventory/trash/preview")

local ruleset =
{
    enabled = true,
    rules =
    {
        {name = "hands off the good stuff", mark = "keep",
         conditions = {{stat = "rarity", op = "atLeast", value = "Exotic"}}},
        {name = "weak guns", mark = "trash",
         conditions = {{stat = "category", op = "is", value = "Armed"},
                       {stat = "dps", op = "atMost", value = 500}}},
        {name = "poor miners", mark = "trash",
         conditions = {{stat = "category", op = "oneOf", value = {"Mining", "Salvaging"}},
                       {stat = "efficiency", op = "atMost", value = 0.4}}},
    },
}

status, body = call("POST", "/inventory/trash/preview", ruleset)
check(status == 200 and body.counts.trash == 3,
      "the preview says what would change and changes nothing")
check(names(body.changes) == "Chaingun Turret, Mining Turret, Pea Shooter",
      "the right three: two weak guns and a miner below its threshold")
check(byIndex(body.changes, 3).rule == "weak guns", "and which rule decided")
check(Mock.itemAt(1, 3).trash == false, "nothing was actually written")

-- The order of the rules is the whole of their logic.
local lucky = nil
for _, change in ipairs(body.changes) do
    if change.name == "Lucky Gun" then lucky = change end
end
check(lucky == nil, "a favourited item is never touched, whatever the rules say")

local quest = nil
for _, change in ipairs(body.changes) do
    if change.name == "XSTN-K III" then quest = change end
end
check(quest == nil, "and neither is a mission item")

-- #### THE SWEEP #### --

print("\nthe sweep")

status, body = call("POST", "/inventory/trash", ruleset)
check(status == 200 and body.enabled == true and body.revision == 2, "the rules are saved")

status, body = call("POST", "/inventory/trash", ruleset)
check(status == 200 and body.revision == 3, "and each save is a new revision")

status, body = call("POST", "/inventory/trash", {rules = {}, ifRevision = 1})
check(status == 409 and body.error.code == "rules_changed",
      "a save against a stale revision is refused rather than clobbering someone else's")

-- The sweeper is the whole reason this feature exists, so what is worth asserting is not
-- that it finishes but that it refuses to finish quickly. The saves above already ran a
-- pass - every request the bridge handles also gives the sweeper a tick - so this starts
-- from a clean slate and drives the ticks by hand.
call("POST", "/inventory/tags", {indices = {0, 3, 7}, mark = "none"})
Mock.tagWrites = {}
Mock.advanceClock(Config.trashSweepInterval + 1)

local perTick = {}
for _ = 1, 20 do
    local before = #Mock.tagWrites
    Bridge.update(Config.pollInterval)
    perTick[#perTick + 1] = #Mock.tagWrites - before
end

local busy, worst = 0, 0
for _, written in ipairs(perTick) do
    if written > 0 then busy = busy + 1 end
    if written > worst then worst = written end
end

status, body = call("GET", "/inventory/trash")
check(body.sweep.passes >= 1, "a pass runs by itself, with nobody asking")
check(body.sweep.lastPass.scanned == 9 and body.sweep.lastPass.marked == 3,
      "it looked at every slot and marked the three the preview named")
check(#Mock.tagWrites == 3, "and wrote exactly three tags, not nine")
check(worst <= Config.trashSweepWritesPerTick, "never more than the per-tick write budget")

check(Mock.itemAt(1, 0).trash == true and Mock.itemAt(1, 3).trash == true
      and Mock.itemAt(1, 7).trash == true, "the right items are marked")
check(Mock.itemAt(1, 4).trash == false, "the exotic railgun the keep rule protects is not")
check(Mock.itemAt(1, 11).trash == false and Mock.itemAt(1, 13).trash == false,
      "nor the favourite, nor the mission item")

-- The real point, on an inventory big enough to show it: a hoard that the obvious
-- implementation would mark inside one tick takes this one dozens of ticks, and no single
-- tick does more than its budget.
print("\nslicing")

for slot = 0, 199 do
    Mock.addItem(2, {index = slot, type = T.turret, name = "Junk " .. slot, rarity = R.petty,
                     dps = 1, category = 0})
end

local hoarderKey = otherKey
call("POST", "/inventory/trash",
     {enabled = true, rules = {{name = "all junk", mark = "trash",
      conditions = {{stat = "dps", op = "atMost", value = 2}}}}}, nil, hoarderKey)

Mock.tagWrites = {}

local ticksUsed, scannedPerTick = 0, 0
for _ = 1, 400 do
    ticksUsed = ticksUsed + 1

    local before = #Mock.tagWrites
    Bridge.update(Config.pollInterval)
    if #Mock.tagWrites - before > scannedPerTick then
        scannedPerTick = #Mock.tagWrites - before
    end

    if #Mock.tagWrites >= 200 then break end
end

check(#Mock.tagWrites == 200, "two hundred items all get marked in the end")
check(scannedPerTick <= Config.trashSweepWritesPerTick,
      "with no tick ever writing more than its budget")
check(ticksUsed >= 200 / Config.trashSweepWritesPerTick,
      string.format("which took %d ticks rather than one - the whole point of the thing",
                    ticksUsed))

call("POST", "/inventory/trash", {enabled = false, rules = {}}, nil, hoarderKey)

-- Nothing more to do: a second pass must not rewrite what it already wrote.
Mock.tagWrites = {}
Mock.advanceClock(Config.trashSweepInterval + 1)
for _ = 1, 40 do Bridge.update(Config.pollInterval) end

status, body = call("GET", "/inventory/trash")
check(body.sweep.passes >= 2 and #Mock.tagWrites == 0,
      "a second pass over an inventory it has already sorted writes nothing")

print("\nrestoring")

-- Tighten the threshold. Without `restore` yesterday's marks stay, which is the safe
-- default; with it they come back off.
local tighter = {enabled = true, rules = {{name = "weak guns", mark = "trash",
                 conditions = {{stat = "category", op = "is", value = "Armed"},
                               {stat = "dps", op = "atMost", value = 20}}}}}

call("POST", "/inventory/trash", tighter)
Mock.advanceClock(Config.trashSweepInterval + 1)
for _ = 1, 40 do Bridge.update(Config.pollInterval) end

check(Mock.itemAt(1, 3).trash == true,
      "loosening a rule leaves what it marked before alone by default")

tighter.restore = true
call("POST", "/inventory/trash", tighter)
Mock.advanceClock(Config.trashSweepInterval + 1)
for _ = 1, 40 do Bridge.update(Config.pollInterval) end

check(Mock.itemAt(1, 3).trash == false and Mock.itemAt(1, 7).trash == false,
      "with 'restore' on, items that no longer match are unmarked")
check(Mock.itemAt(1, 0).trash == true, "and the one that still matches stays marked")

print("\nturning it off")

call("POST", "/inventory/trash", {enabled = false, rules = tighter.rules})
call("POST", "/inventory/tags", {indices = {0}, mark = "none"})

Mock.tagWrites = {}
Mock.advanceClock(Config.trashSweepInterval + 1)
for _ = 1, 40 do Bridge.update(Config.pollInterval) end

check(#Mock.tagWrites == 0, "a ruleset that is turned off sweeps nothing")

status, body = call("POST", "/inventory/trash/run")
check(status == 409 and body.error.code == "trash_disabled",
      "and cannot be asked to run")

-- #### OWNERS #### --

print("\nowners")

status, body = call("GET", "/inventory", nil, {owner = "alliance"})
check(status == 200 and names(body.items) == "Alliance Popgun",
      "an alliance has its own inventory")

status, body = call("POST", "/inventory/tags", {indices = {0}, mark = "trash"}, {owner = "alliance"})
check(status == 200 and Mock.itemAt(9, 0).trash == true,
      "a member with SpendItems may tag it")

status, body = call("GET", "/inventory", nil, {owner = "alliance"}, otherKey)
check(status == 409 and body.error.code == "no_alliance",
      "somebody else's alliance is not theirs to read")

status, body = call("GET", "/inventory", nil, {pageSize = "5"}, otherKey)
check(status == 200 and body.owner.index == 2 and body.items[1].name ~= nil,
      "and each caller reads their own, never another player's")

print("\nthe reader in isolation")

-- Items.read is the half that touches the engine, so it is worth one direct check that it
-- copes with the shapes the engine actually produces.
local records, summary = Items.read(Player(1))
check(#records == 9 and summary.occupied == 9, "every slot, described")
check(records[1].index == 0 and records[#records].index == 16,
      "in slot order, which is sparse and starts at zero")

local limited = Items.read(Player(1), 2)
check(#limited == 2, "and a cap is a cap")

check(ItemRules.matches({dps = 50}, {{stat = "dps", op = "atMost", value = 100}}) == true
      and ItemRules.matches({}, {{stat = "dps", op = "atMost", value = 100}}) == false,
      "a missing stat never matches a threshold")

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
