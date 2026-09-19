-- Non-destructive, per-book inline layers for EPUB documents.
-- The original archive is never modified.  Translations are persisted as
-- JSON and exposed to CREngine as generated CSS text.

local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")

local Overlay = {}

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function write_file(path, data)
    -- Atomic replacement: rename(2) overwrites the destination on POSIX, so
    -- there is no window where the old overlay is gone but the new one is
    -- not yet in place (a crash mid-checkpoint keeps the previous file).
    local temporary = path .. ".tmp"
    local file = io.open(temporary, "wb")
    if not file then return false end
    file:write(data)
    file:close()
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return false
    end
    return true
end

local function css_string(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\"):gsub('"', '\\"')
    value = value:gsub("\r\n", "\\A "):gsub("[\r\n]", "\\A ")
    value = value:gsub("%z", "")
    return '"' .. value .. '"'
end

function Overlay.load(path)
    local raw = read_file(path)
    if not raw or raw == "" then return nil end
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" or type(data.entries) ~= "table" then
        return nil
    end
    return data
end

function Overlay.save(path, data)
    local ok, encoded = pcall(JSON.encode, data)
    if not ok or not encoded then return false end
    return write_file(path, encoded)
end

function Overlay.exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    local size = file:seek("end") or 0
    file:close()
    return size > 0
end

-- Serialize a user font setting into a valid CSS font-family value.
-- Multi-word family names ("Noto Serif CJK SC") must be quoted, but the CSS
-- generic families (serif, sans-serif, ...) must NOT be quoted.  Quoted parts
-- the user already wrote are kept as-is.
local generic_families = {
    ["serif"] = true, ["sans-serif"] = true, ["monospace"] = true,
    ["cursive"] = true, ["fantasy"] = true, ["system-ui"] = true,
}
function Overlay.cssFontFamily(value)
    if not value or value == "" then return "" end
    local parts = {}
    for part in tostring(value):gmatch("[^,]+") do
        part = part:gsub("^%s+", ""):gsub("%s+$", "")
        if part ~= "" then
            if generic_families[part] then
                table.insert(parts, part)
            elseif part:match("^['\"]") and part:match("['\"]$") then
                table.insert(parts, part)
            else
                table.insert(parts, '"' .. part .. '"')
            end
        end
    end
    return table.concat(parts, ", ")
end

-- CREngine implements generated ::before/::after content as real layout
-- nodes.  It therefore participates in pagination without touching EPUB
-- XHTML.  Rebuilding this CSS only changes the visible layers.
--
-- A large book overlay can hold thousands of entries; chapter-by-chapter
-- translation calls refreshDocumentStyles (and therefore buildCss) after
-- every chapter, so re-parsing the whole JSON every time is wasted work.
-- Cache the compiled CSS keyed by path + mtime + rendering options.  The
-- worker that writes the overlay replaces the file atomically, so mtime
-- changes exactly when the content does.
local css_cache = {}
local CSS_CACHE_LIMIT = 16
local function build_css(path, options)
    local data = Overlay.load(path)
    if not data then return "" end
    options = options or {}
    local translation_visible = options.translation_visible == true
    local translation_color = options.translation_color or "#666666"
    local translation_size = options.translation_size or "1em"
    -- Empty font family inherits the paragraph's own font (default).
    local translation_font_family = options.translation_font_family
    local font_family_css = ""
    if translation_font_family and translation_font_family ~= "" then
        font_family_css = "font-family:" .. Overlay.cssFontFamily(translation_font_family) .. "!important;"
    end
    local rules = {
        "/* DualTranslate non-destructive generated layers */",
    }
    for _, entry in ipairs(data.entries) do
        local selector = entry.selector
        if selector and selector ~= "" then
            if translation_visible and entry.translation and entry.translation ~= "" then
                table.insert(rules, string.format(
                    "%s::after{content:%s!important;display:block!important;white-space:pre-wrap!important;color:%s!important;font-size:%s!important;%sline-height:130%%!important;margin:0!important;padding:0!important;}",
                    selector, css_string(entry.translation), translation_color, translation_size, font_family_css))
            end
        end
    end
    return table.concat(rules, "\n")
end

function Overlay.buildCss(path, options)
    options = options or {}
    -- When the mtime cannot be read (no overlay yet, exotic filesystem) skip
    -- the cache entirely rather than risk serving stale CSS.
    local mtime = path and lfs.attributes(path, "modification") or nil
    if not mtime then return build_css(path, options) end
    local key = table.concat({
        tostring(path), tostring(mtime),
        options.translation_visible == true and "1" or "0",
        tostring(options.translation_color or ""),
        tostring(options.translation_size or ""),
        tostring(options.translation_font_family or ""),
    }, "|")
    local cached = css_cache[key]
    if cached ~= nil then return cached end
    local css = build_css(path, options)
    css_cache[key] = css
    local count = 0
    for _ in pairs(css_cache) do count = count + 1 end
    if count > CSS_CACHE_LIMIT then
        for k in pairs(css_cache) do css_cache[k] = nil end
    end
    return css
end

return Overlay
