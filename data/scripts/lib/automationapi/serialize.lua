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
            args[tostring(k)] = Serialize.string(v)
        end
    end
    result.args = args

    return result
end

-- Pairs a template with its argument table the way vanilla returns them:
-- `local msg, args = command:getErrors(...)`.
function Serialize.message(template, args)
    if template == nil then return nil end

    if type(template) ~= "string" then
        local result = Serialize.format(template)
        if args then
            for k, v in pairs(args) do result.args[tostring(k)] = Serialize.string(v) end
        end
        return result
    end

    local out = {template = template, args = {}, text = template}

    if type(args) == "table" then
        for k, v in pairs(args) do out.args[tostring(k)] = Serialize.string(v) end
    end

    -- best-effort ${name} substitution so logs are readable without the game's locale
    out.text = string.gsub(template, "%${(%w+)}", function(name)
        return out.args[name] or ("${" .. name .. "}")
    end)

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
