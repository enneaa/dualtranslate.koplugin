local calls = {}
local M = {}
function M.open(path)
    local db = { path = path, closed = false, exec = function() return true end, close = function(self) self.closed = true end }
    return setmetatable(db, { __index = M })
end
local stmt_mt = {}
function stmt_mt.__index(_, k)
    if k == "bind" then return function(self, ...) self.binds = { ... } return self end
    elseif k == "step" then return function(self)
        if self.sql:find("SELECT", 1, true) then
            if not self.fired then self.fired = true
                if self.binds and self.binds[#self.binds] == "missing" then return false end
                return { "译文A", "microsoft_free" }
            end
            return false
        end
        return true
    end
    elseif k == "close" then return function() end end
    return nil
end
function M.prepare(db, sql) local s = { sql = sql } setmetatable(s, stmt_mt) calls[#calls + 1] = { sql = sql, stmt = s } return s end
function M.exec(db, sql) return true end
function M.close(db) db.closed = true end
package.preload["lua-ljsqlite3/init"] = function() return M end
package.preload["datastorage"] = function() return { getDataDir = function() return "/data" end } end
package.preload["logger"] = function() return { warn = function() end, err = function() end, info = function() end } end
local Cache = dofile("dualtranslate_cache.lua")
local c = Cache:new()
local hit = c:lookupForBook("/b.epub", "auto", "zh-Hans", "Hello")
assert(hit and hit.translated_text == "译文A")
assert(calls[1].sql:find("FROM book_translations", 1, true) and #calls[1].stmt.binds == 4)
assert(calls[2].sql:find("UPDATE book_translations", 1, true) and #calls[2].stmt.binds == 5)
calls = {}
assert(c:storeForBook("/b.epub", "auto", "zh-Hans", "Hello", "你好", "system") == true)
assert(#calls[1].stmt.binds == 8 and calls[1].stmt.binds[1] == "/b.epub")
calls = {}
c:clearForBook("/b.epub")
assert(#calls == 2)
print("PASS: cache helpers")
