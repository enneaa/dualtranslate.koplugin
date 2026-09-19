-- 复现：整书翻译完成(overlay complete) -> 清除译文 -> 再点翻译本书
local REPRO = "/tmp/dt_repro_clear"
os.execute("rm -rf " .. REPRO)
local settings = {}
local notified = {}
local _ = function(s) return s end
local function template(fmt, ...) return fmt end

local function mini_json_decode(s)
    local pos = 1
    local function skip()
        while s:sub(pos, pos):match("%s") do pos = pos + 1 end
    end
    local function parse()
        skip()
        local c = s:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local t = {}
            skip()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
            while true do
                skip()
                local k = parse()
                skip()
                assert(s:sub(pos, pos) == ":", "expected :")
                pos = pos + 1
                t[k] = parse()
                skip()
                local sep = s:sub(pos, pos)
                if sep == "," then pos = pos + 1
                elseif sep == "}" then pos = pos + 1 break
                else error("bad object") end
            end
            return t
        elseif c == "[" then
            pos = pos + 1
            local t = {}
            skip()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
            while true do
                t[#t + 1] = parse()
                skip()
                local sep = s:sub(pos, pos)
                if sep == "," then pos = pos + 1
                elseif sep == "]" then pos = pos + 1 break
                else error("bad array") end
            end
            return t
        elseif c == '"' then
            pos = pos + 1
            local out = {}
            while true do
                local ch = s:sub(pos, pos)
                if ch == '"' then pos = pos + 1 break end
                if ch == "\\" then
                    out[#out + 1] = s:sub(pos + 1, pos + 1)
                    pos = pos + 2
                else
                    out[#out + 1] = ch
                    pos = pos + 1
                end
            end
            return table.concat(out)
        elseif c == "t" then pos = pos + 4 return true
        elseif c == "f" then pos = pos + 5 return false
        elseif c == "n" then pos = pos + 4 return nil
        else
            local num = s:match("^-?%d+%.?%d*", pos)
            assert(num, "bad value at " .. pos)
            pos = pos + #num
            return tonumber(num)
        end
    end
    return parse()
end

local stubs = {
    ["logger"] = { warn = function() end, err = function() end, info = function() end },
    ["gettext"] = _,
    ["datastorage"] = { getDataDir = function() return REPRO end },
    ["util"] = { makePath = function(p) os.execute("mkdir -p " .. p) return true end, trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end },
    ["ffi/util"] = { template = template },
    ["ffi/archiver"] = {},
    ["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } },
    ["libs/libkoreader-lfs"] = {
        attributes = function(p, m)
            if m == "mode" then
                local kind = io.popen('stat -c "%F" "' .. p .. '" 2>/dev/null'):read("*l")
                if kind == "directory" then return "directory" end
                if kind == "regular file" or kind == "regular empty file" then return "file" end
                return nil
            end
            if m == "modification" then
                local t = io.popen('stat -c "%Y" "' .. p .. '" 2>/dev/null'):read("*l")
                return tonumber(t) or 0
            end
            return nil
        end,
        mkdir = function(p) os.execute("mkdir -p " .. p) return true end,
        rmdir = function(p) os.execute("rmdir " .. p) return true end,
        remove = function(p) os.remove(p) return true end,
        dir = function(p)
            local entries = {}
            for name in io.popen('ls -A "' .. p .. '" 2>/dev/null'):lines() do entries[#entries + 1] = name end
            return function() return (table.remove(entries, 1)) end, p, nil
        end,
    },
    ["json"] = { encode = function() return "" end, decode = mini_json_decode },
    ["socket.http"] = {}, ["ltn12"] = {}, ["socketutil"] = {}, ["socket.url"] = { escape = function(s) return s end, unescape = function(s) return s end },
    ["lua-ljsqlite3/init"] = {},
    ["ui/uimanager"] = { show = function() end, close = function() end, setDirty = function() end, scheduleIn = function() end, nextTick = function() end },
    ["ui/widget/notification"] = { new = function(self, o) notified[#notified + 1] = o.text return {} end },
    ["ui/widget/buttondialog"] = {},
    ["ui/widget/textviewer"] = {},
    ["ui/widget/container/framecontainer"] = {},
    ["ui/widget/verticalgroup"] = {},
    ["ui/widget/textwidget"] = {},
    ["ui/widget/progresswidget"] = {},
    ["ui/widget/container/inputcontainer"] = {},
    ["ui/widget/container/widgetcontainer"] = {},
    ["ui/geometry"] = {},
    ["ui/gesturerange"] = {},
    ["ui/font"] = {},
    ["ui/size"] = {},
    ["ui/time"] = {},
    ["ffi/blitbuffer"] = {},
    ["ui/widget/menu"] = {},
    ["ui/widget/progressbardialog"] = {},
    ["ui/widget/inputdialog"] = {},
    ["ui/widget/spinwidget"] = {},
    ["ui/trapper"] = { dismissableRunInSubprocess = function() end, wrap = function() end },
    ["ui/event"] = { new = function() return {} end },
    ["document/credocument"] = { engineInit = function() return {} end },
    ["fontlist"] = {},
    ["ui/translator"] = {},
    ["dump"] = function() return "{}" end,
}
for k, v in pairs(stubs) do package.preload[k] = function() return v end end
_G.G_reader_settings = {
    readSetting = function(self, key) return settings[key] end,
    saveSetting = function(self, key, value) settings[key] = value end,
}
package.path = "/home/user/Doubao/chats/38441681735635970/kotranslate_xplatform/?.lua;" .. package.path

local Overlay = require("dualtranslate_overlay")
local Tools = require("dualtranslate_tools")
local Cache = require("dualtranslate_cache")
local Providers = require("dualtranslate_providers")
local TranslationUI = require("dualtranslate_ui")
local Reader = require("dualtranslate_reader")

local plugin = { getSetting = function(self, key, d) return settings[key] ~= nil and settings[key] or d end }
Reader.attach(plugin)
-- need cache etc.
plugin.cache = { clearForBook = function() end, close = function() end, open = function() end }
plugin.getTargetLang = function(self) return settings["dualtranslate_target_lang"] or "zh-Hans" end
plugin.getSourceLang = function(self) return settings["dualtranslate_source_lang"] or "auto" end
plugin.getMode = function(self) return settings["dualtranslate_mode"] or "microsoft_free" end
plugin.isPageTranslationEnabled = function(self) return settings["dualtranslate_page_translation"] == true end
plugin.ui = { document = { file = "/books/test.epub" } }
plugin.epub = {}
plugin._translation_queue = {}
plugin.saveTranslationQueue = function() end
plugin.loadTranslationQueue = function() return {} end
plugin.startNextQueuedTranslation = function() end
plugin.TranslationUI = { showInfo = function() end }

-- 1. 模拟整书翻译完成：写 complete=true 的 overlay
local book = "/books/test.epub"
local overlay_path = plugin:getTranslationOverlayPath(book)
Tools.mkdir_p(plugin:getBookCacheDirectory(book))
-- 手写真实 overlay.json（完整格式）
local f = io.open(overlay_path, "w")
f:write('{"version":2,"complete":true,"book_path":"/books/test.epub","source_lang":"en","target_lang":"zh-Hans","entries":[{"selector":"x","translated":"y"}]}')
f:close()
local function is_complete(p) local d = Overlay.load(p) return d ~= nil and d.complete == true end

-- 2. 逐章模式开启（用户开着开关）
settings["dualtranslate_page_translation"] = true

-- 3. 点"翻译本书"（逐章分支）—— 修复后不得误报"已翻译完成"，应直接入队章节模式
plugin._page_translation_follow_active = false
notified = {}
local enqueued = nil
plugin.enqueueTranslation = function(self, bp, all_chapters, fragment, silent, span, auto)
    enqueued = { all_chapters = all_chapters, span = span }
end
plugin:translateBook(true)
assert(enqueued and enqueued.all_chapters == false and enqueued.span == 1,
    "stale complete must not block chapter translation")
assert(#notified == 0, "no false 'already translated' notification, got " .. tostring(#notified))
print("  stale complete no longer blocks chapter mode")

-- 4. 清除译文
local removed, cleared_path = plugin:removeTranslationFilesForBook(book)
print("  removed:", removed, "cleared_path:", cleared_path)
assert(removed == 1, "expected 1 overlay removed, got " .. tostring(removed))
-- 检查 overlay 是否真的删除
local f = io.open(overlay_path, "rb")
print("  overlay exists after clear:", f ~= nil)
assert(f == nil, "overlay.json should be deleted after clear")
assert(not is_complete(overlay_path), "isComplete should be false after clear")

-- 5. 清除后再点"翻译本书"（逐章分支）—— 不应提示已翻译，应进入逐章翻译
plugin.enqueueTranslation = function(self, bp, all_chapters, fragment, silent, span, auto)
    print("  enqueue called: all_chapters=" .. tostring(all_chapters) .. " span=" .. tostring(span))
    assert(all_chapters == false, "should enqueue chapter mode")
end
notified = {}
plugin:translateBook(true)
assert(#notified == 0, "should NOT say already translated, got " .. tostring(#notified))
print("PASS: clear then re-translate works (chapter mode enqueued, no false 'done')")

-- 6. 多语言残留场景：书曾翻译成 zh-Hans（完成）和 en（完成），当前语言改为 en
--    （用户整书翻译完成后改过目标语言）。清除应同时删掉两个语言目录。
local book2 = "/books/novel.epub"
settings["dualtranslate_target_lang"] = "zh-Hans"
local dir_zh = plugin:getBookCacheDirectory(book2)
os.execute("mkdir -p " .. dir_zh)
f = io.open(dir_zh .. "/overlay.json", "w")
f:write('{"version":2,"complete":true,"book_path":"/books/novel.epub","source_lang":"en","target_lang":"zh-Hans","entries":[{"selector":"a","translation":"b"}]}')
f:close()
settings["dualtranslate_target_lang"] = "en"
local dir_en = plugin:getBookCacheDirectory(book2)
os.execute("mkdir -p " .. dir_en)
f = io.open(dir_en .. "/overlay.json", "w")
f:write('{"version":2,"complete":true,"book_path":"/books/novel.epub","source_lang":"en","target_lang":"en","entries":[{"selector":"a","translation":"b"}]}')
f:close()
-- 另一本书的目录（不应被误删）
local book3 = "/books/other.epub"
local dir_other = plugin:getBookCacheDirectory(book3)
os.execute("mkdir -p " .. dir_other)
f = io.open(dir_other .. "/overlay.json", "w")
f:write('{"version":2,"complete":true,"book_path":"/books/other.epub","target_lang":"en","entries":[{"selector":"a","translation":"b"}]}')
f:close()

local removed2 = plugin:removeTranslationFilesForBook(book2)
print("  multi-lang removed:", removed2)
local function exists(p)
    local g = io.open(p, "rb")
    if g then g:close(); return true end
    return false
end
assert(not exists(dir_zh .. "/overlay.json"), "zh-Hans overlay should be cleared")
assert(not exists(dir_en .. "/overlay.json"), "en overlay should be cleared")
assert(exists(dir_other .. "/overlay.json"), "other book overlay must survive")

-- 7. 逐章模式 + 整书残留 complete：点"翻译本书"不得再误报"已翻译完成"
settings["dualtranslate_target_lang"] = "zh-Hans"
local dir_residue = plugin:getBookCacheDirectory(book2)
os.execute("mkdir -p " .. dir_residue)
f = io.open(dir_residue .. "/overlay.json", "w")
f:write('{"version":2,"complete":true,"book_path":"/books/novel.epub","target_lang":"zh-Hans","entries":[{"selector":"a","translation":"b"}]}')
f:close()
settings["dualtranslate_page_translation"] = true
notified = {}
plugin.enqueueTranslation = function(self, bp, all_chapters, fragment, silent, span, auto)
    print("  enqueue: all_chapters=" .. tostring(all_chapters) .. " span=" .. tostring(span))
    assert(all_chapters == false, "chapter mode expected")
end
plugin.ui.document.file = book2
plugin:translateBook(true)
assert(#notified == 0, "stale complete must NOT block chapter translation, got " .. tostring(#notified))
print("PASS: stale whole-book complete no longer blocks chapter translation")
