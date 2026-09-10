-- Converts game objects into plain, JSON-safe Lua tables.
--
-- Nothing else in the mod is allowed to hand a raw game value to the JSON encoder.
-- Vanilla tables are routinely sparse or 0-based and would silently encode as objects
-- with numeric string keys; predictions can hold NaN; and most getters return userdata
-- that has no JSON representation at all. Everything funnels through here.

local Json = include("automationapi/json")

local Serialize = {}

-- #### PRIMITIVES #### --

-- NaN and infinity have no JSON form, and letting them through produces documents that
-- strict parsers on the other end reject outright.
function Serialize.number(v, default)
    if type(v) ~= "number" then return default end
    if v ~= v or v == math.huge or v == -math.huge then return default end

    return v
end

function Serialize.bool(v, default)
    if type(v) ~= "boolean" then return default end
    return v
end

function Serialize.string(v, default)
    if v == nil then return default end
    if type(v) == "string" then return v end

    return tostring(v)
end

-- Engine display strings carry translator hints, e.g. "Chaingun /* Weapon Name*/".
-- The game strips those when it localizes; an API wants the bare, stable English name.
function Serialize.displayName(v)
    if v == nil then return nil end

    local text = Serialize.string(v)

    -- translator hints, e.g. "Chaingun /* Weapon Name*/"
    text = string.gsub(text, "/%*.-%*/", "")
    -- colour markup, e.g. "\c(dd5)warning\c()"
    text = string.gsub(text, "\\c%b()", "")

    return string.gsub(text, "^%s*(.-)%s*$", "%1")
end

function Serialize.vec2(x, y)
    return {x = Serialize.number(x, 0), y = Serialize.number(y, 0)}
end

-- #### GAME TYPES #### --

-- Format arguments arrive as PluralForm userdata. tostring() on one gives a raw pointer -
-- meaningless to a caller, and different on every server run, so two otherwise identical
-- responses would not compare equal. The readable text is on the object; if there is none,
-- the argument is dropped rather than reported as an address.
local function argumentText(value)
    local kind = type(value)

    if kind == "string" then return value end
    if kind == "number" or kind == "boolean" then return tostring(value) end
    if kind ~= "userdata" and kind ~= "table" then return nil end

    -- Only fields PluralForm actually has, and only for userdata. Reading a property an
    -- engine type does not have does not return nil - it raises, and the engine logs a
    -- full traceback on the way out even though the pcall catches it. Probing `text` here
    -- filled the server log with "Property not found: PluralForm.text", once per station
    -- title argument of every predicted sector.
    --
    -- An empty string counts as an answer. Some arguments legitimately are empty - the
    -- size suffix of an unsized factory, for one - and treating that as a miss is what
    -- made the probe fall through to a field that does not exist.
    if kind == "userdata" then
        for _, field in ipairs({"translated", "singular"}) do
            local ok, text = pcall(function() return value[field] end)
            if ok and type(text) == "string" then return text end
        end
    else
        local ok, text = pcall(function() return value.text end)
        if ok and type(text) == "string" then return text end
    end

    local ok, text = pcall(tostring, value)
    if ok and type(text) == "string" and not string.match(text, "^userdata: ") then
        return text
    end

    return nil
end

Serialize.argumentText = argumentText


-- Vanilla error and status strings are "..."%_T templates carrying named arguments.
-- Both halves are kept: `template` is stable enough for a planner to branch on, while
-- `text` is what a human should read.
function Serialize.format(fmt)
    if fmt == nil then return nil end

    if type(fmt) == "string" then
        return {template = fmt, text = fmt, args = {}}
    end

    local result = {}

    local ok, text = pcall(function() return fmt.text end)
    result.template = ok and text or tostring(fmt)

    local okEval, evaluated = pcall(function() return fmt:evaluate() end)
    result.text = okEval and evaluated or result.template

    local args = {}
    local okArgs, raw = pcall(function() return fmt:arguments() end)
    if okArgs and type(raw) == "table" then
        for k, v in pairs(raw) do
            args[tostring(k)] = argumentText(v)
        end
    end
    result.args = args

    return result
end

-- Flattens a Format or NamedFormat down to one readable string.
--
-- Wanted wherever the value is data rather than a message - station titles, which a
-- caller searches on. evaluate() localizes, but it needs a language loaded and returns
-- the raw template when there is none, so ${name} substitution is the fallback.
function Serialize.formatText(value)
    if value == nil then return nil end
    if type(value) == "string" then return Serialize.displayName(value) end

    local ok, evaluated = pcall(function() return value:evaluate() end)
    if ok and type(evaluated) == "string" and evaluated ~= ""
       and not string.find(evaluated, "${", 1, true) then
        return Serialize.displayName(evaluated)
    end

    local template
    local okText, raw = pcall(function() return value.text end)
    template = (okText and type(raw) == "string") and raw or tostring(value)

    local args = {}
    local okArgs, rawArgs = pcall(function() return value:arguments() end)
    if okArgs and type(rawArgs) == "table" then
        for key, argument in pairs(rawArgs) do
            args[tostring(key)] = argumentText(argument)
        end
    end

    local filled = string.gsub(template, "%${(%w+)}", function(name)
        return args[name] or ("${" .. name .. "}")
    end)

    return Serialize.displayName(filled)
end

-- Pairs a template with its argument table the way vanilla returns them:
-- `local msg, args = command:getErrors(...)`.
function Serialize.message(template, args)
    if template == nil then return nil end

    if type(template) ~= "string" then
        local result = Serialize.format(template)
        if args then
            for k, v in pairs(args) do result.args[tostring(k)] = argumentText(v) end
        end
        return result
    end

    local out = {template = template, args = {}, text = template}

    if type(args) == "table" then
        for k, v in pairs(args) do out.args[tostring(k)] = argumentText(v) end
    end

    -- best-effort substitution so logs are readable without the game's locale. Vanilla
    -- uses both named ${slots} and positional %1% ones, and ship status messages are
    -- mostly the latter.
    out.text = string.gsub(template, "%${(%w+)}", function(name)
        return out.args[name] or ("${" .. name .. "}")
    end)

    out.text = string.gsub(out.text, "%%(%d+)%%", function(index)
        return out.args[index] or ("%" .. index .. "%")
    end)

    -- `template` stays raw so a caller can still match on it, but the rendered text drops
    -- the translator hints the game embeds ("Idle /* ship AI status */").
    out.text = Serialize.displayName(out.text)

    return out
end

function Serialize.tradingGood(good, amount)
    if good == nil then return nil end

    return
    {
        name = Serialize.displayName(good.name),
        plural = Serialize.displayName(good.plural),
        price = Serialize.number(good.price, 0),
        size = Serialize.number(good.size, 0),
        amount = Serialize.number(amount),
        stolen = Serialize.bool(good.stolen, false),
        illegal = Serialize.bool(good.illegal, false),
        dangerous = Serialize.bool(good.dangerous, false),
        suspicious = Serialize.bool(good.suspicious, false),
    }
end

-- table<TradingGood, int> is keyed by userdata, which JSON cannot express. Flattened
-- into an array of goods carrying their amount.
function Serialize.cargoList(cargos)
    local result = Json.array({})
    if type(cargos) ~= "table" then return result end

    for good, amount in pairs(cargos) do
        local entry = Serialize.tradingGood(good, amount)
        if entry then result[#result + 1] = entry end
    end

    table.sort(result, function(a, b) return (a.name or "") < (b.name or "") end)

    return result
end

-- #### GENERIC FALLBACK #### --

local MAX_DEPTH = 12

local function isSequence(t)
    local n = #t
    if n == 0 then return false end

    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then return false end
        count = count + 1
    end

    return count == n
end

local function convert(value, depth, seen)
    local t = type(value)

    if value == nil then return nil end
    if t == "boolean" or t == "string" then return value end
    if t == "number" then return Serialize.number(value) end

    if t ~= "table" then
        -- userdata: vec3, Uuid, TradingGood used as a plain value, ...
        local ok, text = pcall(tostring, value)
        return ok and text or "<unserializable>"
    end

    if depth >= MAX_DEPTH then return "<max depth>" end
    if seen[value] then return "<cycle>" end
    seen[value] = true

    local result
    if isSequence(value) then
        result = Json.array({})
        for i = 1, #value do
            result[i] = convert(value[i], depth + 1, seen)
        end
    else
        result = {}
        for k, v in pairs(value) do
            local kt = type(k)
            -- keys that aren't strings or numbers (TradingGood, Entity, ...) can't be
            -- expressed; callers that need those must flatten them explicitly
            if kt == "string" or kt == "number" then
                local converted = convert(v, depth + 1, seen)
                if converted ~= nil then result[tostring(k)] = converted end
            end
        end
    end

    seen[value] = nil

    return result
end

-- Last-resort coercion for tables whose exact shape we don't control, such as the
-- prediction tables each mission type builds. Note that a 0-based or sparse table
-- becomes a JSON object with numeric string keys rather than an array; that is
-- deliberate, since renumbering would silently corrupt indices that mean something.
function Serialize.value(v)
    return convert(v, 0, {})
end

return Serialize
