-- Queue sub-menu behavior: active row reopens the progress dialog, queued/
-- failed rows carry a native cancel sub-item. No popup window is created.
local settings = {}
local calls = {}
local _ = function(s) return s end
package.preload["logger"] = function() return { warn = function() end, err = function() end, info = function() end } end
package.preload["datastorage"] = function() return { getDataDir = function() return "/tmp/dt_queue" end } end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return nil end, mkdir = function() return true end,
        rmdir = function() return true end, remove = function() return true end, dir = function() end }
end
package.preload["dump"] = function() return function(t) return "{}" end end
package.preload["ui/uimanager"] = function()
    return { show = function(w) calls[#calls + 1] = { show = w } end,
        close = function() end, setDirty = function() end }
end
package.preload["ui/widget/notification"] = function()
    return { new = function(self, o) calls[#calls + 1] = { notif = o.text } return {} end }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(self, o) calls[#calls + 1] = { bd = o } return { title = o.title } end }
end
package.preload["dualtranslate_tools"] = function() return { mkdir_p = function() return true end } end
package.preload["device"] = function() return { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } } end
_G.G_reader_settings = {
    readSetting = function(self, key) return settings[key] end,
    saveSetting = function(self, key, value) settings[key] = value end,
}
local State = dofile("dualtranslate_state.lua")
local closed_menu = false
local fake_menu = { onClose = function() closed_menu = true end }
local plugin = {
    _translation_queue = {
        { book_path = "/books/a.epub", status = "active", current = 1, total = 4, translated = 2, failed = 0 },
        { book_path = "/books/b.epub", status = "queued", current = 0, total = 4 },
        { book_path = "/books/c.epub", status = "failed", current = 0, total = 0, error = "boom" },
        { book_path = "/books/d.epub", status = "done", current = 4, total = 4 },
    },
    _translation_progress = { active = true },
    saveTranslationQueue = function() end,
    reopenTranslationProgress = function() calls[#calls + 1] = { reopen = true } return true end,
}
local rows = State.buildQueueMenu(plugin)
assert(#rows == 3, "expected 3 rows (done skipped), got " .. #rows)
-- active row -> reopenTranslationProgress
calls = {}
closed_menu = false
rows[1].callback(fake_menu)
assert(closed_menu, "active row should close the menu")
assert(#calls == 1 and calls[1].reopen, "active row should call reopenTranslationProgress")
-- queued row -> native cancel sub-item (no ButtonDialog popup)
assert(rows[2].sub_item_table and #rows[2].sub_item_table == 1, "queued row should carry cancel sub-item")
assert(rows[2].sub_item_table[1].text == "取消翻译", rows[2].sub_item_table[1].text)
calls = {}
closed_menu = false
rows[2].sub_item_table[1].callback(fake_menu)
assert(closed_menu, "cancel sub-item should close the menu")
local still_b = false
for _, it in ipairs(plugin._translation_queue) do
    if it.book_path == "/books/b.epub" then still_b = true end
end
assert(not still_b, "queued job should be removed from the queue")
-- failed row -> cancel sub-item too
assert(rows[3].sub_item_table and #rows[3].sub_item_table == 1, "failed row should carry cancel sub-item")
rows[3].sub_item_table[1].callback(fake_menu)
local still_c = false
for _, it in ipairs(plugin._translation_queue) do
    if it.book_path == "/books/c.epub" then still_c = true end
end
assert(not still_c, "failed job should be removed from the queue")
-- active row fallback: reopen fails -> ButtonDialog confirmation
plugin.reopenTranslationProgress = function() return false end
calls = {}
rows[1].callback(fake_menu)
local has_bd = false
for _, c in ipairs(calls) do if c.bd then has_bd = true end end
assert(has_bd, "active row fallback should show confirmation")
-- empty queue -> empty item table (menu item gets disabled upstream)
local empty = State.buildQueueMenu({ _translation_queue = {} })
assert(type(empty) == "table" and #empty == 0, "empty queue should yield empty table")
