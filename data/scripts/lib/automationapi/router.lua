-- Request routing and the shared error envelope.
--
-- Pure Lua with no game dependencies, so it can be unit-tested outside Avorion.

local Router = {}
Router.__index = Router

-- Returned by a handler that has started async work and will answer later through
-- ctx.complete(). The bridge holds the request open until then (or until it times out).
Router.DEFERRED = setmetatable({}, {__tostring = function() return "DEFERRED" end})

local errorMeta = {__tostring = function(e) return e.code .. ": " .. e.message end}

-- Abort a handler with a specific HTTP-shaped status. Caught by dispatch().
function Router.fail(status, code, message, details)
    error(setmetatable(
    {
        isApiError = true,
        status = status,
        code = code,
        message = message,
        details = details,
    }, errorMeta), 0)
end

function Router.isApiError(err)
    return type(err) == "table" and err.isApiError == true
end

-- #### PERCENT DECODING #### --

-- Ship names routinely contain spaces and punctuation, so path segments arrive encoded.
function Router.decodeSegment(s)
    if type(s) ~= "string" then return s end

    s = string.gsub(s, "+", " ")
    s = string.gsub(s, "%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)

    return s
end

-- #### PATTERN COMPILATION #### --

-- "/ships/{name}/mission" becomes "^/ships/([^/]+)/mission$" plus the name list.
local function compile(path)
    local params = {}
    local pattern = string.gsub(path, "{(%w+)}", function(name)
        params[#params + 1] = name
        return "\1"
    end)

    -- escape everything that is magic in a Lua pattern, then restore the placeholders
    pattern = string.gsub(pattern, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    pattern = string.gsub(pattern, "\1", "([^/]+)")

    return "^" .. pattern .. "$", params
end

function Router.new()
    return setmetatable({routes = {}, sorted = true}, Router)
end

function Router:add(method, path, handler)
    local pattern, params = compile(path)

    self.routes[#self.routes + 1] =
    {
        method = string.upper(method),
        path = path,
        pattern = pattern,
        params = params,
        handler = handler,
    }
    self.sorted = false

    return self
end

function Router:get(path, handler)  return self:add("GET", path, handler) end
function Router:post(path, handler) return self:add("POST", path, handler) end

-- Fewer placeholders wins, so a static route always beats a parameterised one that
-- would also match. Ties keep registration order.
local function sortRoutes(routes)
    for i, route in ipairs(routes) do route.order = i end

    table.sort(routes, function(a, b)
        if #a.params ~= #b.params then return #a.params < #b.params end
        return a.order < b.order
    end)
end

-- Returns handler, params, or nil plus the set of methods that would have matched.
function Router:match(method, path)
    if not self.sorted then
        sortRoutes(self.routes)
        self.sorted = true
    end

    method = string.upper(method or "GET")

    local pathMatched = {}

    for _, route in ipairs(self.routes) do
        local captures = {string.match(path, route.pattern)}

        if captures[1] ~= nil then
            if route.method == method then
                local params = {}
                for i, name in ipairs(route.params) do
                    params[name] = Router.decodeSegment(captures[i])
                end

                return route.handler, params
            end

            pathMatched[route.method] = true
        end
    end

    local allowed = {}
    for m, _ in pairs(pathMatched) do allowed[#allowed + 1] = m end
    table.sort(allowed)

    return nil, allowed
end

-- Runs a request. Returns status, body. Never raises: a handler that blows up becomes
-- a 500, because this runs inside the server's update tick and must not take it down.
function Router:dispatch(method, path, ctx)
    local handler, allowed = self:match(method, path)

    if not handler then
        if allowed and #allowed > 0 then
            return 405, {error = {code = "method_not_allowed",
                                  message = "Allowed: " .. table.concat(allowed, ", ")}}
        end

        return 404, {error = {code = "not_found", message = "No such endpoint: " .. path}}
    end

    local ok, result, body = pcall(handler, ctx, allowed)

    if not ok then
        local err = result

        if Router.isApiError(err) then
            return err.status, {error = {code = err.code,
                                         message = err.message,
                                         details = err.details}}
        end

        return 500, {error = {code = "internal_error", message = tostring(err)}}, tostring(err)
    end

    if result == Router.DEFERRED then return Router.DEFERRED end

    -- handlers may return (status, body) or just a body
    if type(result) == "number" then return result, body end

    return 200, result
end

return Router
