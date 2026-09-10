-- Minimal JSON encoder/decoder for the Avorion Automation API.
--
-- Written for the game's sandbox: pure Lua 5.2, no external libraries, no bit ops.
-- Vanilla Lua tables can't tell an empty array apart from an empty object, so the
-- serializer marks arrays explicitly with Json.array(). Unmarked tables fall back to
-- the usual heuristic: a proper 1..n sequence encodes as an array, anything else as
-- an object, and an empty table as {}.

local Json = {}

-- sentinel for an explicit JSON null (a nil value would just vanish from a table)
Json.null = setmetatable({}, {__tostring = function() return "null" end})

local arrayMeta = {__jsonarray = true}

function Json.array(t)
    return setmetatable(t or {}, arrayMeta)
end

function Json.isArray(t)
    if getmetatable(t) == arrayMeta then return true end

    local n = #t
    if n == 0 then return false end

    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then return false end
        count = count + 1
    end

    return count == n
end

-- #### ENCODING #### --

local escapes =
{
    ['"'] = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function escapeChar(c)
    local escape = escapes[c]
    if escape then return escape end

    return string.format("\\u%04x", string.byte(c))
end

local function encodeString(s)
    return '"' .. string.gsub(s, '[%z\1-\31\\"]', escapeChar) .. '"'
end

local function encodeNumber(n)
    -- JSON has no way to express these, and letting them through produces a document
    -- that every strict parser on the other side will reject
    if n ~= n or n == math.huge or n == -math.huge then return "null" end

    if n == math.floor(n) and math.abs(n) < 1e15 then
        return string.format("%d", n)
    end

    return string.format("%.14g", n)
end

local encodeValue

local function encodeTable(value, out, depth)
    if depth > 64 then error("json: nesting too deep (cycle?)", 0) end

    if Json.isArray(value) then
        out[#out + 1] = "["
        for i = 1, #value do
            if i > 1 then out[#out + 1] = "," end
            encodeValue(value[i], out, depth + 1)
        end
        out[#out + 1] = "]"
        return
    end

    -- sort keys so identical data always produces identical bytes; makes responses
    -- diffable and test assertions stable
    local keys = {}
    for k, _ in pairs(value) do
        if type(k) == "string" or type(k) == "number" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    out[#out + 1] = "{"
    for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encodeString(tostring(k))
        out[#out + 1] = ":"
        encodeValue(value[k], out, depth + 1)
    end
    out[#out + 1] = "}"
end

encodeValue = function(value, out, depth)
    local t = type(value)

    if value == nil or value == Json.null then
        out[#out + 1] = "null"
    elseif t == "boolean" then
        out[#out + 1] = tostring(value)
    elseif t == "number" then
        out[#out + 1] = encodeNumber(value)
    elseif t == "string" then
        out[#out + 1] = encodeString(value)
    elseif t == "table" then
        encodeTable(value, out, depth)
    else
        -- userdata, functions: the caller forgot to run this through serialize.lua
        out[#out + 1] = encodeString(tostring(value))
    end
end

-- Returns the encoded string, or nil plus a message.
function Json.encode(value)
    local out = {}

    local ok, err = pcall(encodeValue, value, out, 0)
    if not ok then return nil, tostring(err) end

    return table.concat(out)
end

-- #### DECODING #### --

local function skipWhitespace(str, pos)
    local _, stop = string.find(str, "^[ \t\r\n]*", pos)
    return stop + 1
end

local function decodeError(pos, msg)
    error(string.format("json: %s at position %d", msg, pos), 0)
end

local function codepointToUtf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + (math.floor(cp / 0x40) % 0x40),
                           0x80 + (cp % 0x40))
    end

    return string.char(0xF0 + math.floor(cp / 0x40000),
                       0x80 + (math.floor(cp / 0x1000) % 0x40),
                       0x80 + (math.floor(cp / 0x40) % 0x40),
                       0x80 + (cp % 0x40))
end

local decodeValue

local function decodeString(str, pos)
    local out = {}
    local i = pos + 1 -- skip opening quote

    while true do
        local c = string.sub(str, i, i)
        if c == "" then decodeError(pos, "unterminated string") end

        if c == '"' then
            return table.concat(out), i + 1
        elseif c == "\\" then
            local e = string.sub(str, i + 1, i + 1)
            if e == "u" then
                local hex = string.sub(str, i + 2, i + 5)
                local cp = tonumber(hex, 16)
                if not cp then decodeError(i, "invalid unicode escape") end
                i = i + 6

                -- surrogate pair
                if cp >= 0xD800 and cp <= 0xDBFF and string.sub(str, i, i + 1) == "\\u" then
                    local low = tonumber(string.sub(str, i + 2, i + 5), 16)
                    if low and low >= 0xDC00 and low <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
                        i = i + 6
                    end
                end

                out[#out + 1] = codepointToUtf8(cp)
            else
                local simple = {['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
                                f = "\f", n = "\n", r = "\r", t = "\t"}
                local decoded = simple[e]
                if not decoded then decodeError(i, "invalid escape '\\" .. e .. "'") end

                out[#out + 1] = decoded
                i = i + 2
            end
        else
            -- consume a run of plain characters at once instead of byte by byte
            local _, stop = string.find(str, '^[^"\\]+', i)
            out[#out + 1] = string.sub(str, i, stop)
            i = stop + 1
        end
    end
end

local function decodeNumber(str, pos)
    local _, stop = string.find(str, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    local text = string.sub(str, pos, stop)
    local value = tonumber(text)
    if not value then decodeError(pos, "invalid number") end

    return value, stop + 1
end

local function decodeArray(str, pos)
    local result = Json.array({})
    local i = skipWhitespace(str, pos + 1)

    if string.sub(str, i, i) == "]" then return result, i + 1 end

    while true do
        local value
        value, i = decodeValue(str, i)
        result[#result + 1] = value

        i = skipWhitespace(str, i)
        local c = string.sub(str, i, i)

        if c == "]" then return result, i + 1 end
        if c ~= "," then decodeError(i, "expected ',' or ']'") end

        i = skipWhitespace(str, i + 1)
    end
end

local function decodeObject(str, pos)
    local result = {}
    local i = skipWhitespace(str, pos + 1)

    if string.sub(str, i, i) == "}" then return result, i + 1 end

    while true do
        if string.sub(str, i, i) ~= '"' then decodeError(i, "expected object key") end

        local key
        key, i = decodeString(str, i)

        i = skipWhitespace(str, i)
        if string.sub(str, i, i) ~= ":" then decodeError(i, "expected ':'") end

        i = skipWhitespace(str, i + 1)

        local value
        value, i = decodeValue(str, i)
        result[key] = value

        i = skipWhitespace(str, i)
        local c = string.sub(str, i, i)

        if c == "}" then return result, i + 1 end
        if c ~= "," then decodeError(i, "expected ',' or '}'") end

        i = skipWhitespace(str, i + 1)
    end
end

decodeValue = function(str, pos)
    local c = string.sub(str, pos, pos)

    if c == '"' then return decodeString(str, pos) end
    if c == "{" then return decodeObject(str, pos) end
    if c == "[" then return decodeArray(str, pos) end
    if c == "-" or string.match(c, "%d") then return decodeNumber(str, pos) end
    if string.sub(str, pos, pos + 3) == "true" then return true, pos + 4 end
    if string.sub(str, pos, pos + 4) == "false" then return false, pos + 5 end
    if string.sub(str, pos, pos + 3) == "null" then return Json.null, pos + 4 end

    decodeError(pos, "unexpected character '" .. c .. "'")
end

-- Returns the decoded value, or nil plus a message.
function Json.decode(str)
    if type(str) ~= "string" then return nil, "json: expected a string" end

    local ok, value, pos = pcall(function()
        local start = skipWhitespace(str, 1)
        return decodeValue(str, start)
    end)

    if not ok then return nil, tostring(value) end

    local rest = skipWhitespace(str, pos)
    if rest <= #str then return nil, "json: trailing garbage after value" end

    return value
end

return Json
