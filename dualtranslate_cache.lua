local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
-- Lua 5.2+ moved unpack into table; LuaJIT (5.1) keeps the global.  Both
-- forms are identical on every target this plugin runs on.
local unpack = table.unpack or unpack
local logger = require("logger")

local DB_FILENAME = "dualtranslate_cache.sqlite3"

local Cache = {}

function Cache:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Cache:getDbPath()
    return DataStorage:getDataDir() .. "/" .. DB_FILENAME
end


-- Every accessor runs through these two helpers so SQLite errors (corrupt
-- db, bad bind) degrade to a cache miss instead of crashing the worker.
-- prepare/bind/step/close are the only ljsqlite3 calls in the module.
function Cache:_query(sql, ...)
    local args = { ... }
    local db = self:open()
    if not db then return nil end
    local ok, stmt = pcall(function() return db:prepare(sql) end)
    if not ok or not stmt then return nil end
    local step_ok, row = pcall(function()
        stmt:bind(unpack(args))
        return stmt:step()
    end)
    stmt:close()
    if not step_ok or not row then return nil end
    return row
end

function Cache:_execute(sql, ...)
    local args = { ... }
    local db = self:open()
    if not db then return false end
    local ok, stmt = pcall(function() return db:prepare(sql) end)
    if not ok or not stmt then return false end
    local run_ok, err = pcall(function()
        stmt:bind(unpack(args))
        stmt:step()
    end)
    stmt:close()
    if not run_ok then
        logger.warn("dualtranslate: cache write error:", tostring(err))
        return false
    end
    return true
end

function Cache:open()
    if self.db then return self.db end
    local db_path = self:getDbPath()
    -- A cache database corrupted by a crash/power loss must not take the
    -- plugin down: SQLite throws on open/prepare of a damaged file.  Try to
    -- recreate the database instead, and fall back to a nil handle so every
    -- caller degrades to a cache miss instead of crashing.
    local ok, db = pcall(SQ3.open, db_path)
    if not ok or not db then
        logger.warn("dualtranslate: cache db corrupt, recreating:", db_path)
        os.remove(db_path)
        os.remove(db_path .. "-wal")
        os.remove(db_path .. "-shm")
        ok, db = pcall(SQ3.open, db_path)
        if not ok or not db then
            logger.err("dualtranslate: cannot recreate cache db:", db)
            return nil
        end
    end
    local setup_ok, setup_err = pcall(function()
        db:exec("PRAGMA journal_mode=WAL;")
        db:exec("PRAGMA busy_timeout=5000;")
        db:exec("PRAGMA synchronous=NORMAL;")
        db:exec([[
            CREATE TABLE IF NOT EXISTS translations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_lang TEXT NOT NULL,
                target_lang TEXT NOT NULL,
                source_text TEXT NOT NULL,
                translated_text TEXT NOT NULL,
                provider TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                last_used_at INTEGER NOT NULL,
                use_count INTEGER DEFAULT 1,
                book_path TEXT,
                UNIQUE(source_lang, target_lang, source_text)
            );
        ]])
        db:exec([[
            CREATE INDEX IF NOT EXISTS idx_translations_lookup
                ON translations(source_lang, target_lang, source_text);
        ]])
        db:exec([[
            CREATE INDEX IF NOT EXISTS idx_translations_book
                ON translations(book_path);
        ]])
        -- Whole-book translations are deliberately isolated by book.  The old
        -- translations table is shared by selected-text translation and its
        -- UNIQUE key cannot represent the same paragraph in multiple books.
        db:exec([[
            CREATE TABLE IF NOT EXISTS book_translations (
                book_path TEXT NOT NULL,
                source_lang TEXT NOT NULL,
                target_lang TEXT NOT NULL,
                source_text TEXT NOT NULL,
                translated_text TEXT NOT NULL,
                provider TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                last_used_at INTEGER NOT NULL,
                use_count INTEGER DEFAULT 1,
                PRIMARY KEY(book_path, source_lang, target_lang, source_text)
            );
        ]])
    end)
    if not setup_ok then
        logger.warn("dualtranslate: cache db setup failed:", setup_err)
        db:close()
        self.db = nil
        return nil
    end
    self.db = db
    return db
end

function Cache:lookupForBook(book_path, source_lang, target_lang, source_text)
    if not book_path then return nil end
    local row = self:_query([[
        SELECT translated_text, provider FROM book_translations
        WHERE book_path = ? AND source_lang = ? AND target_lang = ? AND source_text = ?
        LIMIT 1
    ]], book_path, source_lang, target_lang, source_text)
    if not row then return nil end
    self:_execute([[
        UPDATE book_translations SET last_used_at = ?, use_count = use_count + 1
        WHERE book_path = ? AND source_lang = ? AND target_lang = ? AND source_text = ?
    ]], os.time(), book_path, source_lang, target_lang, source_text)
    return { translated_text = row[1], provider = row[2], cached = true }
end

function Cache:storeForBook(book_path, source_lang, target_lang, source_text,
        translated_text, provider)
    if not book_path then return false end
    local now = os.time()
    return self:_execute([[
        INSERT OR REPLACE INTO book_translations
            (book_path, source_lang, target_lang, source_text, translated_text,
             provider, created_at, last_used_at, use_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
    ]], book_path, source_lang, target_lang, source_text, translated_text, provider, now, now)
end

function Cache:close()
    if self.db then
        self.db:close()
        self.db = nil
    end
end

function Cache:clear()
    local db = self:open()
    if not db then return end
    local ok, err = pcall(function()
        db:exec("DELETE FROM translations;")
        db:exec("DELETE FROM book_translations;")
        db:exec("VACUUM;")
    end)
    if not ok then logger.warn("dualtranslate: cache clear error:", err) end
end

function Cache:clearForBook(book_path)
    if not book_path then return end
    self:_execute("DELETE FROM book_translations WHERE book_path = ?", book_path)
    -- Older builds also stored whole-book rows in the shared table with a
    -- NULL book_path; they are unreachable now (book lookups use the
    -- book_translations table), so a plain removal of this book's rows is
    -- enough.  The overlay-driven per-paragraph repair loop from older
    -- versions is gone.
    self:_execute("DELETE FROM translations WHERE book_path = ?", book_path)
end

return Cache
