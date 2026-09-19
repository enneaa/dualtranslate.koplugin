-- Small EPUB reader/writer used by DualTranslate's chapter mode.
-- It intentionally handles XHTML as text: the original markup is preserved and
-- only translated block paragraphs are inserted after their source element.

local Epub = {}
local Archiver = require("ffi/archiver")
local Overlay = require("dualtranslate_overlay")
local Tools = require("dualtranslate_tools")
local DataStorage = require("datastorage")
local socket_url = require("socket.url")

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function write_file(path, data)
    local file = io.open(path, "wb")
    if not file then return false end
    file:write(data)
    file:close()
    return true
end

local function attr(tag, name)
    local escaped_name = name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    local pattern = escaped_name .. "%s*=%s*[\"']([^\"']+)[\"']"
    return tag:match(pattern)
end

local function normalize_path(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." and part ~= "" then
            table.insert(parts, part)
        end
    end
    return table.concat(parts, "/")
end

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or ""
end

local function html_to_text(html)
    -- Ruby readings are metadata for the base Japanese text, not additional
    -- words to send to the translator.  Keeping <rt> content used to turn e.g.
    -- 素人 into "素人 しろうと", which confused sentence translation and
    -- produced the apparently missing/broken clauses seen in the reader.
    html = html:gsub("<[rR][tT][^>]*>.-</[rR][tT]%s*>", "")
    html = html:gsub("<br%s*/?>", "\n")
    html = html:gsub("<[^>]+>", " ")
    html = html:gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", "\"")
        :gsub("&#39;", "'")
    return html:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function html_escape(text)
    return tostring(text)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
end

-- Throttled progress writer.  Whole-book runs call this once per paragraph,
-- which on a several-thousand-paragraph book means thousands of open/write/
-- close cycles; batching the writes to ~4/s keeps the progress dialog smooth
-- without the file I/O storm.  The watchdog keys off modification time with
-- a 10-minute window, so throttling is invisible to it.  os.clock() is
-- monotonic within this subprocess, so a fresh worker starts at 0.
local progress_last_write = 0
local function write_progress(path, current, total, translated, failed, chapter, chapters)
    if not path then return end
    local now = os.clock()
    -- The first call always writes (progress_last_write starts at 0), so the
    -- initial "0/total" marker and the file itself are created immediately.
    if progress_last_write > 0 and now - progress_last_write < 0.25 then return end
    progress_last_write = now
    local file = io.open(path, "w")
    if not file then return end
    file:write(string.format("%d|%d|%d|%d|%d|%d\n",
        current or 0, total or 0, translated or 0, failed or 0,
        chapter or 0, chapters or 0))
    file:close()
end

local function looks_translatable(text)
    -- A paragraph is worth sending to the translator when it carries at
    -- least one letter (ASCII) or one non-ASCII rune (CJK, kana, Cyrillic,
    -- accented Latin...).  Pure digits/punctuation-only paragraphs (page
    -- numbers, list markers, decorative separators) are skipped.
    if not text or text == "" then return false end
    if text:match("%a") then return true end
    -- UTF-8: any byte >= 0x80 implies a non-ASCII character.
    return text:match("[\128-\255]") ~= nil
end

function Epub:resolve(book_path, work_dir, fragment)
    local container = read_file(work_dir .. "/META-INF/container.xml")
    if not container then return nil, "找不到 META-INF/container.xml" end
    local opf_path
    -- EPUBs may use a namespace prefix (for example container:rootfile),
    -- and some put rootfiles/rootfile on separate formatting lines.
    for rootfile_tag in container:gmatch("<[^>]*rootfile[^>]*>") do
        opf_path = attr(rootfile_tag, "full-path")
        if opf_path then break end
    end
    if not opf_path then return nil, "找不到 OPF 路径" end
    opf_path = normalize_path(socket_url.unescape(opf_path))
    local opf = read_file(work_dir .. "/" .. opf_path)
    if not opf then return nil, "找不到 OPF 文件" end

    local manifest = {}
    for item in opf:gmatch("<[%w_%-]*:?item[^>]*>") do
        local id = attr(item, "id")
        local href = attr(item, "href")
        if id and href then
            manifest[id] = normalize_path(dirname(opf_path) .. "/" .. socket_url.unescape(href:gsub("#.*$", "")))
        end
    end

    local spine = {}
    for itemref in opf:gmatch("<[%w_%-]*:?itemref[^>]*>") do
        local idref = attr(itemref, "idref")
        if idref and manifest[idref] then
            table.insert(spine, manifest[idref])
        end
    end

    -- fragment is either a plain spine index (preferred: the reader resolves
    -- the current chapter index because CREngine xpointers carry no
    -- DocFragment index), an xpointer with an explicit DocFragment[N] index,
    -- or anything else (fall back to the first spine item).
    local index = tonumber(fragment)
    if not index then
        index = tonumber(tostring(fragment or ""):match("DocFragment%[(%d+)%]")) or 1
    end
    local relative = spine[index] or spine[1]
    if not relative then return nil, "找不到可读取的 spine 项" end
    return {
        relative = relative,
        absolute = work_dir .. "/" .. relative,
        index = index,
        spine_count = #spine,
        spine = spine,
    }
end

local overlay_target_tags = {
    p = true, h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    figcaption = true, dt = true, dd = true,
}

local void_tags = {
    area = true, base = true, br = true, col = true, embed = true, hr = true,
    img = true, input = true, link = true, meta = true, param = true,
    source = true, track = true, wbr = true,
}

local function css_attribute(value)
    return tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
end

-- Build selectors from the original XHTML tree.  These selectors address
-- CREngine's internal DocFragment nodes, so generated text is laid out in the
-- open source EPUB while the archive itself stays byte-for-byte untouched.
local function collect_overlay_candidates(document, relative, fragment_index, div_fallback)
    local targets = div_fallback and { div = true } or overlay_target_tags
    local root = { counts = {}, in_body = false, path = "", xpath = "" }
    local stack = { root }
    local candidates = {}
    local position = 1
    while true do
        local tag_start, tag_end = document:find("<[^>]*>", position)
        if not tag_start then break end
        local raw = document:sub(tag_start, tag_end)
        position = tag_end + 1
        if not raw:match("^<%s*[!?]") then
            local closing = raw:match("^<%s*/") ~= nil
            local name = raw:match("^<%s*/?%s*([%w_:%-]+)")
            if name then
                name = name:lower():gsub("^.-:", "")
                if closing then
                    local found
                    for index = #stack, 2, -1 do
                        if stack[index].name == name then found = index; break end
                    end
                    if found then
                        local node = stack[found]
                        if node.target and node.inner_start then
                            local inner = document:sub(node.inner_start, tag_start - 1)
                            local source = html_to_text(inner)
                            if looks_translatable(source) then
                                table.insert(candidates, {
                                    source = source,
                                    selector = 'DocFragment[Source="' .. css_attribute(relative)
                                        .. '"] > body' .. node.path,
                                    xpointer = "/body/DocFragment"
                                        .. (fragment_index > 1
                                            and ("[" .. tostring(fragment_index) .. "]") or "")
                                        .. "/body" .. node.xpath,
                                })
                            end
                        end
                        for index = #stack, found, -1 do table.remove(stack) end
                    end
                else
                    local parent = stack[#stack]
                    parent.counts[name] = (parent.counts[name] or 0) + 1
                    local in_body = parent.in_body or name == "body"
                    local path = parent.path
                    local xpath = parent.xpath
                    if name == "body" then
                        path = ""
                        xpath = ""
                    elseif in_body then
                        path = path .. " > " .. name .. ":nth-of-type("
                            .. tostring(parent.counts[name]) .. ")"
                        xpath = xpath .. "/" .. name
                            .. (parent.counts[name] > 1
                                and ("[" .. tostring(parent.counts[name]) .. "]") or "")
                    end
                    local node = {
                        name = name,
                        counts = {},
                        in_body = in_body,
                        path = path,
                        xpath = xpath,
                        inner_start = tag_end + 1,
                        target = in_body and targets[name] == true,
                    }
                    local self_closing = raw:match("/%s*>$") ~= nil or void_tags[name]
                    if not self_closing then table.insert(stack, node) end
                end
            end
        end
    end
    return candidates
end

function Epub:translate_overlay(book_path, fragment, target_lang, source_lang,
        translate, all_chapters, progress_path, translate_batch, output_dir, span, cancel_path)
    if not book_path:lower():match("%.epub$") then
        return nil, "整书翻译目前仅支持 EPUB"
    end
    local data_dir = DataStorage:getDataDir()
    local nonce = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
    local work_dir = data_dir .. "/cache/dualtranslate/overlay_" .. nonce
    if not Tools.mkdir_p(work_dir) then
        return nil, "无法创建临时目录"
    end
    local function cleanup()
        Tools.rmtree(work_dir)
        if progress_path then os.remove(progress_path) end
    end
    if not Tools.unzip_to(book_path, work_dir) then
        cleanup()
        return nil, "无法解包 EPUB（可能受 DRM 保护）"
    end
    local chapter, err = self:resolve(book_path, work_dir, fragment)
    if not chapter then cleanup(); return nil, err end
    local chapters = {}
    if all_chapters then
        for index, relative in ipairs(chapter.spine) do
            table.insert(chapters, { index = index, relative = relative,
                absolute = work_dir .. "/" .. relative })
        end
    else
        -- Chapter mode translates the current chapter plus the next few
        -- (span = number of consecutive chapters starting at the current
        -- one, clamped to the end of the spine).
        local span_count = math.max(1, tonumber(span) or 1)
        for offset = 0, span_count - 1 do
            local index = chapter.index + offset
            local relative = chapter.spine[index]
            if not relative then break end
            table.insert(chapters, { index = index, relative = relative,
                absolute = work_dir .. "/" .. relative })
        end
    end

    local chapter_candidates = {}
    local total = 0
    for _, current in ipairs(chapters) do
        local document = read_file(current.absolute)
        local candidates = document and collect_overlay_candidates(document,
            current.relative, current.index, false) or {}
        if #candidates == 0 and document then
            candidates = collect_overlay_candidates(document, current.relative,
                current.index, true)
        end
        chapter_candidates[current.index] = candidates
        total = total + #candidates
    end
    if total == 0 then cleanup(); return nil, "没有找到可翻译的段落" end

    if not Tools.mkdir_p(output_dir) then
        cleanup(); return nil, "无法创建本书翻译缓存目录"
    end
    local output = output_dir .. "/overlay.json"
    local entries, entry_index = {}, {}
    -- A killed subprocess or closing the book may interrupt a run.  Keep the
    -- batches already completed and merge into them on the next run.
    local previous = Overlay.load(output)
    -- Spine indexes covered by previous runs, carried forward so a partial
    -- resume never forgets chapters translated in earlier sessions.
    local covered_indexes = {}
    if previous
        and previous.book_path == book_path
        and previous.source_lang == source_lang
        and previous.target_lang == target_lang then
        for _, entry in ipairs(previous.entries or {}) do
            if entry.selector and entry.translation then
                entries[#entries + 1] = entry
                entry_index[entry.selector] = #entries
            end
        end
        if type(previous.chapters) == "table" then
            for _, index in ipairs(previous.chapters) do
                covered_indexes[#covered_indexes + 1] = index
            end
        end
    end
    local function save_checkpoint(complete)
        return Overlay.save(output, {
            version = 2, complete = complete == true,
            book_path = book_path, source_lang = source_lang,
            target_lang = target_lang, entries = entries,
            -- Spine indexes covered so far.  Chapter-mode runs never set
            -- complete, so the follow mode uses this list to tell "this
            -- chapter is already translated" from "the whole book is done";
            -- without it, visiting an already-covered chapter would re-queue
            -- it and the overlay merge would "finish" instantly at 100%.
            chapters = covered_indexes,
        })
    end
    local processed, translated_count, failed_count = 0, 0, 0
    local first_error
    local cancelled = false
    local last_processed_index = 0
    local function cancel_requested()
        if not cancel_path then return false end
        local file = io.open(cancel_path, "rb")
        if file then file:close() return true end
        return false
    end
    write_progress(progress_path, 0, total, 0, 0, 0, #chapters)
    for _, current in ipairs(chapters) do
        if cancel_requested() then cancelled = true; break end
        last_processed_index = current.index
        covered_indexes[#covered_indexes + 1] = current.index
        local candidates = chapter_candidates[current.index] or {}
        -- Release the collected source text of this chapter as soon as its
        -- batch loop finishes.  On a several-hundred-chapter book the full
        -- candidate list would otherwise stay resident for the whole run,
        -- needlessly raising the subprocess memory watermark.
        local function release_chapter()
            chapter_candidates[current.index] = nil
        end
        local batch_size = 48
        for first = 1, #candidates, batch_size do
            if cancel_requested() then cancelled = true; break end
            local last = math.min(first + batch_size - 1, #candidates)
            local sources, translations = {}, {}
            local pending_sources, pending_offsets = {}, {}
            for index = first, last do
                local candidate = candidates[index]
                local offset = #sources + 1
                sources[offset] = candidate.source
                local old_index = entry_index[candidate.selector]
                local old = old_index and entries[old_index]
                if old and old.source == candidate.source and old.translation ~= "" then
                    translations[offset] = old.translation
                else
                    pending_sources[#pending_sources + 1] = candidate.source
                    pending_offsets[#pending_offsets + 1] = offset
                end
            end
            if translate_batch and #pending_sources > 0 then
                local ok, values, batch_err = pcall(translate_batch, pending_sources)
                if ok and values then
                    for index = 1, #pending_offsets do
                        translations[pending_offsets[index]] = values[index]
                    end
                else first_error = first_error or ((not ok and values) or batch_err) end
            end
            for offset, source in ipairs(sources) do
                local candidate = candidates[first + offset - 1]
                local translated = translations[offset]
                if not translated or translated == "" then
                    local ok, value, single_err = pcall(translate, source)
                    if ok then translated = value else first_error = first_error or value end
                    first_error = first_error or single_err
                end
                processed = processed + 1
                if translated and translated ~= "" then
                    local entry = { selector = candidate.selector,
                        xpointer = candidate.xpointer, source = source,
                        translation = translated }
                    local existing = entry_index[entry.selector]
                    if existing then
                        entries[existing] = entry
                    else
                        entries[#entries + 1] = entry
                        entry_index[entry.selector] = #entries
                    end
                    translated_count = translated_count + 1
                else
                    failed_count = failed_count + 1
                end
                write_progress(progress_path, processed, total, translated_count,
                    failed_count, current.index, #chapters)
            end
            -- Atomic JSON replacement after every network batch provides a
            -- real restart point even when KOReader or the book closes.
            save_checkpoint(false)
        end
        release_chapter()
    end
    if translated_count == 0 and not cancelled then
        cleanup()
        return nil, type(first_error) == "table" and first_error.message
            or tostring(first_error or "翻译服务没有返回译文")
    end
    -- Only a whole-book run may mark the overlay complete.  A chapter-mode
    -- run (span == 1, follow mode) must leave it incomplete so page-turn
    -- scheduling keeps working and the "翻译本书" entry does not report the
    -- book as done while chapters are still missing.
    local saved = save_checkpoint(all_chapters and not cancelled and failed_count == 0)
    cleanup()
    if not saved then return nil, "无法保存本书翻译缓存" end
    return {
        output = output,
        overlay = true,
        chapters = #chapters,
        translated = translated_count,
        failed = failed_count,
        cancelled = cancelled,
        last_chapter = last_processed_index >= (chapter.spine_count or 1),
    }
end

return Epub
