
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Cache = require("dualtranslate_cache")
local Providers = require("dualtranslate_providers")
local TranslationUI = require("dualtranslate_ui")
local Languages = require("dualtranslate_languages")
local State = require("dualtranslate_state")
local Reader = require("dualtranslate_reader")
local PageTrans = require("dualtranslate_pagetrans")

local dualtranslate = WidgetContainer:extend{
    name = "dualtranslate",
    is_doc_only = false,
}

function dualtranslate:init()
    State.attach(self)
    Reader.attach(self)
    PageTrans.attach(self)
    -- One-time migration of older standalone config files into KOReader's
    -- native G_reader_settings (see State.loadConfig).  All settings are then
    -- read and written through the standard KOReader settings API.
    self:loadConfig()
    self.cache = Cache:new()
    self._translation_queue = self:loadTranslationQueue()
    -- Persist cleanup of completed entries immediately after startup.
    self:saveTranslationQueue()

    -- Load the EPUB engine defensively.  Prefer require(), but fall back to
    -- an absolute-path dofile from our own plugin directory so the engine
    -- can never resolve to another plugin's file or to a non-table value.
    self.epub = self:loadEpubModule()
    if not self.epub then
        logger.warn("dualtranslate: EPUB engine failed to load (no module, no dofile)")
    end

    -- Translation requests may need Wi-Fi, but connection retries must stay
    -- in the background.  Keep an explicit user's "ignore" choice intact;
    -- only replace KOReader's default prompt behavior.
    if G_reader_settings then
        if not G_reader_settings:readSetting("dualtranslate_silent_network") then
            G_reader_settings:saveSetting("dualtranslate_silent_network", true)
        end
        -- Never overwrite KOReader's global Wi-Fi policy.  The reader's own
        -- NetworkMgr handles prompts and restoration; the plugin only reports
        -- provider errors to the user.
    end

    self.ui.menu:registerToMainMenu(self)

    -- The reader hooks open the companion after document-ready. Keep the
    -- queue startup here, but do not replace a document during init.
    self:startNextQueuedTranslation()
end

-- Load the EPUB engine module.
--
-- KOReader appends every installed plugin directory to package.path (in
-- path-sorted order).  A bare module name could therefore resolve to a
-- file belonging to another plugin; require() can even come back with a
-- non-table value.  We therefore try require() first, then fall back to
-- loading the file straight from our own directory via self.path (set by
-- PluginLoader), which is immune to any package.path pollution.
function dualtranslate:loadEpubModule()
    local ok, mod = pcall(require, "dualtranslate_epub")
    if ok and type(mod) == "table" then
        return mod
    end
    logger.warn("dualtranslate: require(\"dualtranslate_epub\") failed:", tostring(mod))
    if self.path then
        local ok2, mod2 = pcall(dofile, self.path .. "/dualtranslate_epub.lua")
        if ok2 and type(mod2) == "table" then
            logger.warn("dualtranslate: loaded dualtranslate_epub.lua via dofile")
            return mod2
        end
        logger.warn("dualtranslate: dofile dualtranslate_epub.lua failed:", tostring(mod2))
    end
    return nil
end

-- Persistent configuration and translation-queue state lives in dualtranslate_state.lua.

------------------------------------------------------------------------
-- Settings helpers
------------------------------------------------------------------------
-- All plugin settings are stored through KOReader's native G_reader_settings
-- (settings.reader.lua), keyed with the dualtranslate_ prefix.
function dualtranslate:getSetting(key, default)
    local prefixed = "dualtranslate_" .. key
    local value = G_reader_settings and G_reader_settings:readSetting(prefixed)
    if value == nil then
        return default
    end
    return value
end

function dualtranslate:saveSetting(key, value)
    if G_reader_settings then
        G_reader_settings:saveSetting("dualtranslate_" .. key, value)
    end
end

function dualtranslate:isPluginEnabled()
    return self:getSetting("plugin_enabled", true) == true
end

function dualtranslate:togglePluginEnabled(menu)
    local enabled = not self:isPluginEnabled()
    self:saveSetting("plugin_enabled", enabled)
    self:refreshDocumentStyles()
    if enabled then
        self:startNextQueuedTranslation()
    else
        UIManager:setDirty("all", "ui")
    end
    if menu and menu.updateItems then menu:updateItems() end
end

function dualtranslate:queueStats()
    local active, queued = 0, 0
    for _, item in ipairs(self._translation_queue or {}) do
        if type(item) == "table" then
            if item.status == "queued" then queued = queued + 1
            elseif item.status == "active" then active = active + 1 end
        end
    end
    return active, queued
end

function dualtranslate:getMode()
    local mode = self:getSetting("mode", "microsoft_free")
    if mode ~= "system" and mode ~= "microsoft_free" then
        return "microsoft_free"
    end
    return mode
end

function dualtranslate:getSourceLang()
    return self:getSetting("source_lang", "auto")
end

function dualtranslate:getTargetLang()
    return self:getSetting("target_lang", "zh-Hans")
end

-- Keep requests below the common free web-engine request limit.
function dualtranslate:getTranslationChunkLimit()
    local limits = {
        microsoft_free = 4500,
    }
    return limits[self:getMode()] or 4500
end

function dualtranslate:addToMainMenu(menu_items)
    -- Single top-level entry. The enable/disable checkbox lives as the first
    -- item of the submenu (see buildMenuTable) so it can be toggled by a
    -- plain tap; KOReader would otherwise swallow taps on any item that also
    -- carries a sub_item_table and the checkbox would be display-only.
    menu_items.dualtranslate = {
        text = _("DualTranslate"),
        sorting_hint = "tools",
        sub_item_table = self:buildMenuTable(),
    }
end

function dualtranslate:buildMenuTable()
    local menu = {
        -- Master switch as a plain tap-to-toggle checkbox inside the submenu.
        {
            text = "启用插件",
            checkbox = true,
            checked_func = function() return self:isPluginEnabled() end,
            callback = function(menu) self:togglePluginEnabled(menu) end,
        },
        {
            text = "翻译本书",
            enabled_func = function()
                return self:isEpub() and not self:isLegacyBilingualEpub(self.ui.document.file)
            end,
            callback = function()
                self:translateBook(true)
            end,
        },
        {
            -- "逐章模式" preference.  Checked: tapping "翻译本书" starts from
            -- the current chapter and follows the reading position (page
            -- turns silently translate newly reached chapters).  Unchecked:
            -- "翻译本书" translates the whole book.
            text_func = function()
                return self:isPageTranslationEnabled() and "逐章模式（从当前章开始）" or "逐章模式"
            end,
            checkbox = true,
            checked_func = function() return self:isPageTranslationEnabled() end,
            enabled_func = function()
                return self:isEpub() and not self:isLegacyBilingualEpub(self.ui.document.file)
            end,
            callback = function(menu) self:togglePageTranslation(menu) end,
        },
        {
            -- Queue as a native sub-menu: items expand inline instead of
            -- popping a separate window.
            text_func = function()
                local active, queued = self:queueStats()
                if active + queued == 0 then return "翻译队列（空）" end
                return string.format("翻译队列（进行中%d，排队%d）", active, queued)
            end,
            enabled_func = function()
                local active, queued = self:queueStats()
                return active + queued > 0
            end,
            sub_item_table_func = function()
                return self:buildTranslationQueueMenu()
            end,
        },
        {
            -- 译文可见性开关：勾选 = 在正文中显示译文（不勾 = 隐藏）。
            text = "显示译文",
            checked_func = function()
                local path = self.ui and self.ui.document and self.ui.document.file
                return path and self:hasTranslationOverlay(path)
                    and self:getSetting("translation_visible", true) == true or false
            end,
            enabled_func = function()
                local path = self.ui and self.ui.document and self.ui.document.file
                return self:isEpub() and self:hasTranslationOverlay(path)
            end,
            callback = function() self:toggleTranslationVisible() end,
        },
        -- Provider / Mode selector
        {
            text_func = function()
                return "翻译服务：" .. Providers.getProviderName(self:getMode())
            end,
            sub_item_table = self:buildProviderSelector(),
        },
        -- Language settings: plain sub-menus with radio items (the same
        -- structure the translator_switch plugin uses), no pop-up dialog.
        {
            text_func = function()
                local sl = self:getSourceLang()
                local name = sl == "auto" and "自动识别" or Languages.getNameByCode(sl)
                return "源语言：" .. name
            end,
            sub_item_table = self:buildLanguageMenu("source"),
        },
        {
            text_func = function()
                return "目标语言：" .. Languages.getNameByCode(self:getTargetLang())
            end,
            sub_item_table = self:buildLanguageMenu("target"),
        },
        {
            text_func = function()
                return "译文字号：" .. self:getInlineFontSize()
            end,
            callback = function() self:showInlineFontSpin() end,
        },
        {
            text_func = function()
                return "译文字体：" .. self:getInlineFontFamilyLabel()
            end,
            sub_item_table_func = function()
                return self:buildFontFamilyMenu()
            end,
        },
        self:inlineStyleMenu("inline_color", "译文颜色…", {
            { value = "#e6e6e6", label = "10% 灰" },
            { value = "#cccccc", label = "20% 灰" },
            { value = "#b3b3b3", label = "30% 灰" },
            { value = "#999999", label = "40% 灰" },
            { value = "#808080", label = "50% 灰" },
            { value = "#666666", label = "60% 灰" },
            { value = "#4d4d4d", label = "70% 灰" },
            { value = "#333333", label = "80% 灰" },
            { value = "#1a1a1a", label = "90% 灰" },
        }),
        {
            text = "清除本书译文",
            enabled_func = function()
                return self:isEpub()
            end,
            callback = function()
                self:confirmClearCache()
            end,
        },
    }

    return menu
end

function dualtranslate:buildProviderSelector()
    local items = {}
    for i, provider in ipairs(Providers.list) do
        -- Lua 5.1: loop variables are shared by every closure created inside
        -- the loop.  Capture the per-iteration values (id and name) so each
        -- row shows its own provider and toggles its own mode.
        local pid, pname = provider.id, provider.name

        table.insert(items, {
            text_func = function()
                return pname
            end,
            checked_func = function()
                return self:getMode() == pid
            end,
            radio = true,
            callback = function()
                self:saveSetting("mode", pid)
                TranslationUI.showInfo(T(_("Provider: %1"), pname))
            end,
        })
    end
    return items
end

------------------------------------------------------------------------
-- Language sub-menus (source / target)
------------------------------------------------------------------------
-- Generic radio sub-menu like translator_switch's genLanguagesMenu: no
-- pop-up dialog, selection is applied immediately, and the parent menu item
-- reflects the new value on the next rebuild.
function dualtranslate:buildLanguageMenu(which)
    local items = {}

    if which == "source" then
        table.insert(items, {
            text = "自动识别 (auto)",
            radio = true,
            checked_func = function() return self:getSourceLang() == "auto" end,
            callback = function()
                self:saveSetting("source_lang", "auto")
            end,
        })
    end

    local is_target = which == "target"
    for __, lang in ipairs(Languages.list) do
        -- Lua 5.1: capture the per-iteration values; otherwise every row's
        -- closures would use the last language in the list.
        local code, name = lang.code, lang.name
        table.insert(items, {
            text = string.format("%s (%s)", _(name), code),
            radio = true,
            checked_func = function()
                local current = is_target and self:getTargetLang() or self:getSourceLang()
                return current == code
            end,
            callback = function()
                self:saveSetting(is_target and "target_lang" or "source_lang", code)
            end,
        })
    end
    return items
end

------------------------------------------------------------------------
-- Clear cache
------------------------------------------------------------------------
function dualtranslate:confirmClearCache()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        -- ButtonDialog has no separate info field; the body text lives in
        -- the title (TextBoxWidget, wraps).
        title = "清除本书译文\n彻底删除当前书的全部译文数据？原 EPUB 不会被修改。",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Clear"),
                    callback = function()
                        local book_path = self.ui and self.ui.document and self.ui.document.file
                        if not self:clearTranslationQueueForBook(book_path) then
                            UIManager:close(dialog)
                            TranslationUI.showInfo("这本书正在翻译，请在任务结束后再清除。")
                            return
                        end
                        local removed, cleared_path = self:removeTranslationFilesForBook(book_path)
                        self.cache:clearForBook(cleared_path or book_path)
                        self:saveSetting("translation_visible", false)
                        -- Stop follow-mode after a clear: the page-turn
                        -- scheduler must not immediately re-translate the
                        -- chapter the user just wiped.
                        self._page_translation_follow_active = nil
                        self._page_translation_last_fragment = nil
                        self._page_translation_overlay_state = nil
                        self._chapter_index_cache = nil
                        UIManager:close(dialog)
                        if self.ui and self.ui.document then
                            self.ui.document._dualtranslate_extra_css = nil
                        end
                        self:refreshDocumentStyles()
                        TranslationUI.showInfo(removed > 0
                            and "已彻底删除本书译文"
                            or "已清除本书译文数据库记录")
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function dualtranslate:onCloseDocument()
    -- Follow-mode session state is per book: closing the book must not let
    -- the next opened book inherit an armed follow session (which would
    -- auto-translate it on the first page turn).
    self._page_translation_overlay_state = nil
    self._page_translation_follow_active = nil
    self._page_translation_last_fragment = nil
    self._chapter_index_cache = nil
    self._style_refresh_scheduled = nil
    self.cache:close()
end

function dualtranslate:onReaderReady()
    UIManager:nextTick(function()
        self:refreshDocumentStyles()
    end)
end

-- Restore the saved translation layer while CREngine is still loading its
-- document settings. Applying the same CSS after ReaderReady makes the built
-- DOM stale and triggers KOReader's full-reload prompt; at this stage it is
-- part of the initial render and appears immediately without a toggle cycle.
function dualtranslate:onReadSettings()
    local path = self.ui and self.ui.document and self.ui.document.file
    if path and self:hasTranslationOverlay(path)
        and self:getSetting("translation_visible", true) == true then
        self:refreshDocumentStyles(true)
    end
end

function dualtranslate:onPageUpdate()
    if self.maybeSchedulePageTranslation then
        -- Auto-continue for chapter-by-chapter translation shows the same
        -- progress dialog as a manual start, so the user can watch the
        -- newly reached chapter being translated.
        self:maybeSchedulePageTranslation(false)
    end
end

function dualtranslate:onPosUpdate()
    if self.maybeSchedulePageTranslation then
        self:maybeSchedulePageTranslation(false)
    end
end

function dualtranslate:onDocumentRerendered()
    if self.maybeSchedulePageTranslation then
        self:maybeSchedulePageTranslation(false)
    end
end

dualtranslate.onDocumentPartiallyRerendered = dualtranslate.onDocumentRerendered

return dualtranslate
