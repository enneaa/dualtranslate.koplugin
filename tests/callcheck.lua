local files = {}
for _, name in ipairs({ "main.lua", "dualtranslate_reader.lua", "dualtranslate_state.lua",
    "dualtranslate_pagetrans.lua", "dualtranslate_ui.lua", "dualtranslate_epub.lua",
    "dualtranslate_cache.lua", "dualtranslate_overlay.lua", "dualtranslate_providers.lua",
    "dualtranslate_tools.lua", "dualtranslate_languages.lua" }) do
    local f = io.open(name, "rb")
    if f then files[name] = f:read("*a"); f:close() end
end
local pool = {}
for _, content in pairs(files) do
    for name in content:gmatch("function [%w_]+:([%w_]+)") do pool[name] = true end
    for name in content:gmatch("function [%w_]+%.([%w_]+)") do pool[name] = true end
end
local attached = { "getTranslationQueuePath", "loadConfig", "saveTranslationQueue",
    "loadTranslationQueue", "clearTranslationQueueForBook", "enqueueTranslation",
    "buildTranslationQueueMenu",
    "cancelTranslation",
    "getQueueProgress", "showTranslationQueue", "startNextQueuedTranslation",
    "isPageTranslationEnabled", "togglePageTranslation", "maybeSchedulePageTranslation",
    "splitTranslationText", "translateTextForEpub", "isEpub", "isLegacyBilingualEpub",
    "getBookCacheDirectory", "getTranslationOverlayPath", "hasTranslationOverlay",
    "toggleTranslationVisible", "removeTranslationFilesForBook", "currentChapterIndex",
    "getCurrentFragment", "translateBook", "_runTranslation", "reopenTranslationProgress",
    "isCacheEnabled", "inlineStyleMenu", "getInlineFontSize", "getInlineFontCssSize",
    "getInlineFontFamily", "getInlineFontFamilyLabel", "showFontFamilyDialog",
    "buildFontFamilyMenu", "translateTextBatchForEpub", "refreshDocumentStyles",
    "showInlineFontSpin", "buildLanguageMenu", "confirmClearCache",
    "loadEpubModule" }
for _, name in ipairs(attached) do pool[name] = true end
local missing = {}
for path, content in pairs(files) do
    for name in content:gmatch("self:([%w_]+)%s*%(") do
        if not pool[name] then missing[#missing+1] = path .. ": self:" .. name end
    end
    for name in content:gmatch("plugin:([%w_]+)%s*%(") do
        if not pool[name] then missing[#missing+1] = path .. ": plugin:" .. name end
    end
end
print(#missing == 0 and "ALL METHOD CALLS RESOLVED" or table.concat(missing, "\n"))
