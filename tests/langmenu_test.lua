local languages = { { code = "en", name = "English" }, { code = "zh-Hans", name = "Simplified Chinese" }, { code = "ja", name = "Japanese" } }
local settings = { source_lang = "auto", target_lang = "zh-Hans" }
local _ = function(s) return s end
local function build(which)
    local items = {}
    if which == "source" then
        table.insert(items, { text = "auto", radio = true, checked_func = function() return settings.source_lang == "auto" end,
            callback = function() settings.source_lang = "auto" end })
    end
    local is_target = which == "target"
    for __, lang in ipairs(languages) do
        local code, name = lang.code, lang.name
        table.insert(items, { text = string.format("%s (%s)", _(name), code), radio = true,
            checked_func = function() return (is_target and settings.target_lang or settings.source_lang) == code end,
            callback = function() settings[is_target and "target_lang" or "source_lang"] = code end })
    end
    return items
end
local src = build("source")
assert(src[1].text == "auto")
src[2].callback(); assert(settings.source_lang == "en")
src[3].callback(); assert(settings.source_lang == "zh-Hans")
src[4].callback(); assert(settings.source_lang == "ja")
local tgt = build("target")
assert(#tgt == 3)
tgt[1].callback(); assert(settings.target_lang == "en")
assert(tgt[1].text:match("English"))
print("PASS: language sub-menu closures + radio + per-row keys + gettext")
