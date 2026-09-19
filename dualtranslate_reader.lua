-- Reader-facing translation, EPUB mapping, and styling operations.
-- Menu, persistence, and provider implementations live in separate modules.
local Notification = require("ui/widget/notification")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local logger = require("logger")
local _ = require("gettext")
local util = require("util")
local Trapper = require("ui/trapper")
local DataStorage = require("datastorage")
local Cache = require("dualtranslate_cache")
local Providers = require("dualtranslate_providers")
local Overlay = require("dualtranslate_overlay")
local Tools = require("dualtranslate_tools")

local Reader = {}

function Reader.attach(plugin)
    local dualtranslate = plugin

function dualtranslate:splitTranslationText(text, limit)
    if #text <= limit then return { text } end
    local chunks = {}
    local rest = text
    -- Rewind a split point to the last byte boundary: when cut lands inside
    -- a multi-byte UTF-8 character, back up to the character's start byte
    -- and then one more byte, so neither chunk ends nor the next chunk
    -- begins with a dangling continuation byte.
    local function to_char_boundary(cut)
        while cut > 1 do
            local byte = rest:byte(cut)
            if not byte or byte < 128 or byte > 191 then
                if byte and byte >= 192 then cut = cut - 1 end
                break
            end
            cut = cut - 1
        end
        return cut
    end
    while #rest > limit do
        local cut = limit
        local search_from = math.max(1, limit - 160)
        -- Prefer whitespace or sentence punctuation near the limit, so that
        -- English words and sentences are not cut in the middle.
        for i = limit, search_from, -1 do
            local character = rest:sub(i, i)
            if character:match("[%s%.,;:%?!]" ) then
                cut = i
                break
            end
        end
        -- If there is no whitespace (for example, a CJK paragraph), avoid
        -- splitting in the middle of a UTF-8 byte sequence.
        cut = to_char_boundary(cut)
        local part = util.trim(rest:sub(1, cut))
        if part == "" then
            cut = to_char_boundary(limit)
            part = rest:sub(1, cut)
        end
        table.insert(chunks, part)
        rest = util.trim(rest:sub(cut + 1))
    end
    if rest ~= "" then table.insert(chunks, rest) end
    return chunks
end

-- Whole-book translation uses DualTranslate's provider registry directly and
-- stores the result in a non-destructive per-book overlay cache.
function dualtranslate:translateTextForEpub(text)
    local mode = self:getMode()
    local source_lang = self:getSourceLang()
    local target_lang = self:getTargetLang()
    local result, err

    if self:isCacheEnabled() then
        local cached = self.cache:lookupForBook(self._active_translation_book,
            source_lang, target_lang, text)
        if cached and cached.translated_text then
            return cached.translated_text, nil
        end
    end

    if mode == "default" then
        return nil, { message = "请先选择 DualTranslate 翻译服务" }
    end

    -- Keep long paragraphs below the selected provider's request limit.  The
    -- recursive calls use the same v19 one-paragraph request path, while the
    -- final result remains one continuous translation in the EPUB.
    local limit = self:getTranslationChunkLimit()
    if #text > limit then
        local translated_parts = {}
        for _, chunk in ipairs(self:splitTranslationText(text, limit)) do
            local translated, chunk_err = self:translateTextForEpub(chunk)
            if not translated then return nil, chunk_err end
            table.insert(translated_parts, translated)
        end
        local combined = table.concat(translated_parts, " ")
        if self:isCacheEnabled() then
            self.cache:storeForBook(self._active_translation_book, source_lang,
                target_lang, text, combined, mode)
        end
        return combined, nil
    end

    -- Keep the v19 request path: one paragraph, one provider request.
    -- The newer chunk/batch path was slower on-device and could turn one
    -- failed request into a failed EPUB generation.
    result, err = Providers.translate(mode, text, source_lang, target_lang)

    if result and result.translated_text and result.translated_text ~= "" then
        if self:isCacheEnabled() then
            self.cache:storeForBook(self._active_translation_book, source_lang,
                target_lang, text, result.translated_text, result.provider or mode)
        end
        return result.translated_text, nil
    end
    return nil, err or { message = "翻译服务没有返回译文" }
end

function dualtranslate:isEpub()
    return self.ui and self.ui.document and self.ui.document.file
        and self.ui.document.file:lower():match("%.epub$") ~= nil
end

function dualtranslate:isLegacyBilingualEpub(path)
    return path and path:lower():match("_bilingual_[^/]-%.epub$") ~= nil
end

function dualtranslate:getBookCacheDirectory(book_path)
    local data_dir = require("datastorage"):getDataDir()
    return data_dir .. "/cache/dualtranslate/books/"
        .. Tools.stable_path_hash(book_path .. "|" .. self:getTargetLang())
end

function dualtranslate:getTranslationOverlayPath(book_path)
    if not book_path then return nil end
    return self:getBookCacheDirectory(book_path) .. "/overlay.json"
end

function dualtranslate:hasTranslationOverlay(book_path)
    if not book_path then return false end
    local path = self:getTranslationOverlayPath(book_path)
    return path and Overlay.exists(path) or false
end

function dualtranslate:toggleTranslationVisible()
    local current = self.ui and self.ui.document and self.ui.document.file
    if not current or not self:hasTranslationOverlay(current) then return end
    self:saveSetting("translation_visible",
        self:getSetting("translation_visible", true) ~= true)
    self:refreshDocumentStyles()
end

-- Remove every artifact this plugin owns for a book: the per-book overlay
-- cache directories (overlay.json + any legacy files), across every target
-- language the book has been translated into.  Restrict deletion to the exact
-- DualTranslate books root.
function dualtranslate:removeTranslationFilesForBook(book_path)
    if not book_path then return 0 end
    local lfs = require("libs/libkoreader-lfs")
    local data_dir = DataStorage:getDataDir()
    local books_root = data_dir .. "/cache/dualtranslate/books/"
    local removed = 0
    local cleared_dir
    -- 1) Fast path: the directory for the *current* target language.  This
    -- also catches legacy overlays that carry no book metadata.
    local current_dir = self:getBookCacheDirectory(book_path)
    local current_overlay = Overlay.load(current_dir .. "/overlay.json")
    if current_overlay and current_overlay.book_path == book_path then
        removed = removed + 1
    end
    if current_dir:sub(1, #books_root) == books_root
        and #current_dir > #books_root then
        if Tools.rmtree(current_dir) then cleared_dir = current_dir end
    end
    -- 2) Sweep every other language directory whose overlay belongs to this
    -- same book (metadata written since v1.2.11).  Otherwise, if the target
    -- language was changed after a finished whole-book run, the old-language
    -- overlay would survive a "clear" and later trip stale "already done"
    -- checks or resurrect old translations.
    local ok, iterator, state = pcall(lfs.dir, books_root)
    if ok and iterator then
        for name in iterator, state do
            if name ~= "." and name ~= ".." then
                local dir = books_root .. name
                if dir ~= current_dir then
                    local overlay = Overlay.load(dir .. "/overlay.json")
                    if overlay and overlay.book_path == book_path then
                        removed = removed + 1
                        Tools.rmtree(dir)
                    end
                end
            end
        end
    end
    return removed, cleared_dir or book_path
end

-- Best-effort detection of the current spine chapter index.  CREngine
-- xpointers serialize as "/body/DocFragment/body/..." without a fragment
-- index, so Epub.resolve cannot locate the current chapter from a raw
-- xpointer (it would silently fall back to chapter 1).  Probe each
-- DocFragment's first page instead: the current chapter is the last one
-- whose first page is at or before the current page.  Falls back to nil when
-- the probes are unsupported so callers keep their previous behaviour.
--
-- Probing every fragment on every page turn (a 200-chapter book = 200
-- getPageFromXPointer calls per turn) is wasteful.  The spine is monotonic:
-- chapter N+1 starts at or after chapter N.  Cache the last result and probe
-- incrementally from there — page turns forward only probe a handful of
-- chapters, page turns back probe backwards from the cached position, and
-- only a large jump degrades to a full scan (bounded at 4096, far beyond any
-- realistic EPUB spine; a probe returns "not exists" past the real end).
function dualtranslate:currentChapterIndex()
    local document = self.ui and self.ui.document
    if not document
        or not document.isXPointerInDocument
        or not document.getPageFromXPointer
        or not document.getCurrentPage then
        return nil
    end
    local current_page = document:getCurrentPage()
    if not current_page then return nil end
    local cache = self._chapter_index_cache
    if cache and cache.page == current_page then return cache.index end
    local function probe(index)
        local xp = "/body/DocFragment[" .. tostring(index) .. "]/body"
        local ok_in, in_doc = pcall(function()
            return document:isXPointerInDocument(xp)
        end)
        -- Returns page, exists: an empty spine item (in the document but with
        -- no layout, page <= 0) is "exists but no page" and must be skipped
        -- by the scan rather than treated as the end of the spine; only a
        -- missing fragment terminates the scan.
        if not ok_in or not in_doc then return nil, false end
        local ok_page, page = pcall(function()
            return document:getPageFromXPointer(xp)
        end)
        if not ok_page or not page then return nil, false end
        if page <= 0 then return nil, true end
        return page, true
    end
    local best
    local start = (cache and cache.index) or 1
    -- Forward scan from the cached position (page turned forward).
    local index = start
    while index <= 4096 do
        local page, exists = probe(index)
        if not exists then break end
        if page then
            if page <= current_page then
                best = index
            else
                break
            end
        end
        index = index + 1
    end
    -- Page turned back: the cached chapter starts after the current page.
    -- Walk backwards and take the nearest chapter that still starts before
    -- the current page.
    if not best and start > 1 then
        index = start - 1
        while index >= 1 do
            local page, exists = probe(index)
            if not exists then break end
            if page and page <= current_page then
                best = index
                break
            end
            index = index - 1
        end
    end
    if best then
        self._chapter_index_cache = { page = current_page, index = best }
    end
    return best
end

function dualtranslate:getCurrentFragment()
    local document = self.ui.document
    -- Prefer the resolved chapter index (a plain decimal string).  Epub.resolve
    -- accepts it directly; a raw xpointer cannot locate the chapter.
    local index = self:currentChapterIndex()
    if index then return tostring(index) end
    if not document.getXPointer then return nil end
    local ok, xpointer = pcall(function() return document:getXPointer() end)
    return ok and xpointer or nil
end

function dualtranslate:translateBook(all_chapters, silent, span, auto)
    if not self:isEpub() then return end
    local book_path = self.ui.document.file
    -- "翻译本书" entry (all_chapters == true) honors the 逐章模式 preference:
    -- checked -> translate the current chapter and arm follow mode (page
    -- turns keep scheduling newly reached chapters silently); unchecked ->
    -- translate the whole book.
    -- 逐章模式下"翻译本书"始终翻译当前章并武装跟随模式。这里不能再用
    -- overlay 的 complete 标记判断"本书已翻译"：章节翻译从不写 complete，
    -- 该标记只来自更早某次整书翻译，可能是换语言前的残留，清除缓存后也
    -- 可能指向已删除的语言目录，据此拒绝会让用户再也无法补翻/重翻当前章。
    if all_chapters and self:isPageTranslationEnabled() then
        all_chapters = false
        span = 1
        self._page_translation_follow_active = true
    end
    local fragment = all_chapters and nil or self:getCurrentFragment()
    if fragment then self._page_translation_last_fragment = fragment end
    self:enqueueTranslation(book_path, all_chapters, fragment, silent, span, auto)
end

function dualtranslate:_runTranslation(item)
    local book_path = item.book_path
    local all_chapters = item.all_chapters
    self._active_translation_book = book_path
    local fragment = item.fragment
    local data_dir = DataStorage:getDataDir()
    local progress_path = data_dir .. "/cache/dualtranslate/progress_"
        .. tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999)) .. ".txt"
    Tools.mkdir_p(data_dir .. "/cache/dualtranslate")
    self._translation_progress = {
        active = true,
        all_chapters = all_chapters,
        book_path = book_path,
        item = item,
        path = progress_path,
        started_at = os.time(),
    }
    item.progress_path = progress_path
    self:saveTranslationQueue()

    UIManager:scheduleIn(0.1, function()
        -- Only show a modal progress card when this is still the book the
        -- user started from. Queue workers for books that are no longer open
        -- stay completely in the background.
        local progress_dialog
        if not item.silent and self.ui and self.ui.document and self.ui.document.file == book_path then
            progress_dialog = ProgressbarDialog:new{
                title = all_chapters and "正在翻译整本书…" or "正在翻译当前章节…",
                subtitle = "准备中…\n点按进度条可取消，点按外部收起。",
                -- Drive the native progress bar with a fixed 0-100 scale;
                -- the real paragraph total is not known before the worker
                -- starts walking the spine.
                progress_max = 100,
                refresh_time_seconds = 0.5,
                dismissable = true,
            }
        end
        self._translation_progress.dialog = progress_dialog
        -- Closing this status dialog must only hide it.  The worker keeps
        -- running and the queue can show the same dialog again later.
        if progress_dialog then
            local progress_on_close = progress_dialog.onCloseWidget
            function progress_dialog:onCloseWidget()
                self._dualtranslate_hidden = true
                return progress_on_close(self)
            end
            -- Tap on the dialog body opens the cancel-actions dialog; tap
            -- anywhere outside hides the progress dialog as before.  The
            -- native ProgressbarDialog treats the whole screen as one tap
            -- zone, so the hit test happens here in the handler (ges.pos is
            -- the tap coordinate, self[1].dimen the dialog body's box).
            function progress_dialog:onTapClose(arg, ges)
                if ges and ges.pos and self[1] and self[1].dimen
                    and ges.pos:intersectWith(self[1].dimen) then
                    local action_dialog
                    action_dialog = ButtonDialog:new{
                        title = "翻译进行中，要取消吗？\n已翻译部分会保留，可随时重翻。",
                        buttons = {{
                            {
                                text = "返回",
                                id = "close",
                                callback = function() UIManager:close(action_dialog) end,
                            },
                            {
                                text = "取消翻译",
                                is_enter_default = true,
                                callback = function()
                                    UIManager:close(action_dialog)
                                    UIManager:close(progress_dialog)
                                    dualtranslate:cancelTranslation(item)
                                    UIManager:show(Notification:new{
                                        text = "正在停止翻译…\n（当前批次完成后停止）",
                                        timeout = 2,
                                    })
                                    UIManager:setDirty("all", "ui")
                                end,
                            },
                        }},
                    }
                    UIManager:show(action_dialog)
                    return true
                end
                -- Outside the body: keep the native hide behavior (including
                -- its home_pending handling).
                return ProgressbarDialog.onDismiss(self)
            end
            progress_dialog:show()
        end

        local progress_active = true
        local function update_progress()
            if not progress_active then return end
            if not progress_dialog then return end
            if progress_dialog._dualtranslate_hidden then return end
            local file = io.open(progress_path, "r")
            local line = file and file:read("*l") or nil
            if file then file:close() end
            if line then
                local current, total, translated, failed, chapter, chapters = line:match(
                    "^(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)$")
                current, total = tonumber(current), tonumber(total)
                if current and total then
                    item.current = current
                    item.total = total
                    item.translated = tonumber(translated) or 0
                    item.failed = tonumber(failed) or 0
                    local percentage = total > 0 and math.floor(current * 100 / total + 0.5) or 0
                    progress_dialog.title = string.format("%s  %d%%",
                        all_chapters and "正在翻译整本书…" or "正在翻译当前章节…", percentage)
                    progress_dialog.subtitle = string.format(
                        "段落：%d/%d\n已翻译：%d    失败：%d\n章节：%d/%d\n点按进度条可取消，点按外部收起。",
                        current, total, tonumber(translated) or 0,
                        tonumber(failed) or 0, tonumber(chapter) or 0, tonumber(chapters) or 0)
                    pcall(function()
                        -- Update the existing TextWidgets in place instead of
                        -- rebuilding the whole dialog tree every 0.5s.
                        -- ProgressbarDialog:init() builds self[1] as a
                        -- FrameContainer around a VerticalGroup whose first two
                        -- children are the title and subtitle TextWidgets.
                        local frame = progress_dialog[1]
                        local group = frame and frame[1]
                        if group and group[1] and group[1].setText then
                            group[1]:setText(progress_dialog.title)
                        end
                        if group and group[2] and group[2].setText then
                            group[2]:setText(progress_dialog.subtitle)
                        end
                        progress_dialog:reportProgress(percentage)
                        UIManager:setDirty(progress_dialog, "ui")
                    end)
                end
            end
            UIManager:scheduleIn(0.5, update_progress)
        end
        UIManager:scheduleIn(0.5, update_progress)

        local resume_ok, wrapped_ok = Trapper:wrap(function()
            -- Passing a table avoids Trapper creating its default full-screen
            -- dismiss widget. Page touches remain usable and cannot cancel the
            -- background task.
            local trap_widget = {}
            -- Do not fork an already-open SQLite connection.  The child opens
            -- its own WAL connection and the reader may reopen one later.
            pcall(function() self.cache:close() end)
            local completed, result = Trapper:dismissableRunInSubprocess(function()
                -- Everything the worker touches (provider settings, language
                -- resolution, path helpers) is evaluated inside the pcall.
                -- A failure in any of them must surface as a readable error,
                -- never as a silently lost subprocess result ("无法生成本书
                -- 译文缓存" masks the real cause).
                local ok, info = pcall(function()
                    -- The EPUB engine is cached by main.lua; retry the loader
                    -- once in case init ran before self.path was available.
                    -- A missing engine must surface as a readable message,
                    -- never as an "index a boolean" crash.
                    local Epub = self.epub or self:loadEpubModule()
                    if type(Epub) ~= "table" then
                        return nil, "DualTranslate 模块加载失败：dualtranslate_epub.lua 缺失或损坏，请删除旧插件目录后重新安装"
                    end
                    local run_ok, run_info, run_err = pcall(Epub.translate_overlay, Epub,
                        book_path, fragment, self:getTargetLang(), self:getSourceLang(),
                        function(text)
                            return self:translateTextForEpub(text)
                        end,
                        all_chapters,
                        progress_path,
                        function(texts)
                            return self:translateTextBatchForEpub(texts)
                        end,
                        self:getBookCacheDirectory(book_path),
                        item.span,
                        progress_path .. ".cancel"
                    )
                    if not run_ok then return nil, "翻译过程异常：" .. tostring(run_info) end
                    if not run_info then return nil, run_err end
                    return run_info
                end)
                if not ok then
                    logger.warn("dualtranslate: translate_overlay worker error:", info)
                    return { error = tostring(info) }
                end
                return info
            end, trap_widget)

            if not completed then
                local was_hidden = progress_dialog and progress_dialog._dualtranslate_hidden
                progress_active = false
                self._translation_progress.active = false
                -- The cancel flag file is only meaningful while the worker is
                -- alive; drop it so a later job never sees a stale flag.
                os.remove(progress_path .. ".cancel")
                item.status = "failed"
                item.error = "翻译已中断"
                self:saveTranslationQueue()
                pcall(function() UIManager:close(progress_dialog) end)
                if was_hidden and not self._translation_retry_after_hide then
                    -- A dismissed status widget must not turn into a false
                    -- interruption.  Retry once in the background because
                    -- older KOReader builds may deliver that tap to the
                    -- subprocess trap as well.
                    self._translation_retry_after_hide = true
                    item.status = "queued"
                    item.error = nil
                    self:saveTranslationQueue()
                    UIManager:scheduleIn(0.2, function()
                        self._translation_retry_after_hide = nil
                        self:startNextQueuedTranslation()
                    end)
                elseif all_chapters then
                    -- Whole-book jobs are background jobs.  A transient
                    -- provider error or a reader restart must never cover the
                    -- page with a modal interruption message.  Keep the
                    -- resumable failed entry in the queue for an explicit
                    -- retry from the queue menu.
                    self._translation_retry_after_hide = nil
                    item.status = "queued"
                    item.error = nil
                    self:saveTranslationQueue()
                    logger.warn("dualtranslate: background full-book translation interrupted; queued to resume")
                    UIManager:scheduleIn(2, function() self:startNextQueuedTranslation() end)
                else
                    self._translation_retry_after_hide = nil
                    if not item.silent then
                        UIManager:show(Notification:new{ text = "翻译已中断。", timeout = 3 })
                    end
                    self:startNextQueuedTranslation()
                end
                return
            end
            if not result or not result.output then
                progress_active = false
                self._translation_progress.active = false
                -- A killed translation subprocess can return no serialized
                -- value at all (most often after a transient memory spike
                -- from a previous interrupted job). Give a whole-book job
                -- one automatic clean retry instead of turning it into a
                -- permanent false failure.
                local retry_count = tonumber(item.retry_count) or 0
                if all_chapters and retry_count < 1 then
                    item.retry_count = retry_count + 1
                    item.status = "queued"
                    item.error = nil
                    self:saveTranslationQueue()
                    pcall(function() UIManager:close(progress_dialog) end)
                    logger.warn("dualtranslate: full-book worker returned no result; retrying once")
                    UIManager:scheduleIn(1, function()
                        self:startNextQueuedTranslation()
                    end)
                    return
                end
                item.status = "failed"
                item.error = (result and result.error)
                    or "翻译进程未返回结果（可能内存不足或进程被终止），请查看日志后重试"
                self:saveTranslationQueue()
                pcall(function() UIManager:close(progress_dialog) end)
                if all_chapters then
                    -- Do not interrupt reading for a background full-book
                    -- failure.  The queue entry keeps the error and can be
                    -- retried later; the log is available for diagnosis.
                    logger.warn("dualtranslate: background full-book translation failed:", item.error)
                elseif not item.silent then
                    UIManager:show(Notification:new{
                        text = (result and result.error)
                            or "翻译进程未返回结果（可能内存不足或进程被终止）。\n请查看日志后重试。",
                        timeout = 5,
                    })
                end
                self:startNextQueuedTranslation()
                return
            end
            progress_active = false
            self._translation_progress.active = false
            if result.cancelled then
                -- The user asked the queue to cancel this job.  Keep the
                -- checkpoint already written, drop the task, and move on.
                os.remove(progress_path .. ".cancel")
                for index, queued_item in ipairs(self._translation_queue or {}) do
                    if queued_item == item then
                        table.remove(self._translation_queue, index)
                        break
                    end
                end
                self:saveTranslationQueue()
                pcall(function() UIManager:close(progress_dialog) end)
                if not item.silent then
                    UIManager:show(Notification:new{ text = "已取消翻译。", timeout = 2 })
                end
                self:startNextQueuedTranslation()
                return
            end
            local result_failed = tonumber(result.failed) or 0
            if all_chapters and result_failed > 0 then
                item.output = result.output
                item.failed = result_failed
                local partial_retry = tonumber(item.partial_retry_count) or 0
                if partial_retry < 1 then
                    item.partial_retry_count = partial_retry + 1
                    item.status = "queued"
                    item.error = "有段落翻译失败，正在自动续跑"
                    self:saveTranslationQueue()
                    pcall(function() UIManager:close(progress_dialog) end)
                    UIManager:scheduleIn(1, function()
                        self:startNextQueuedTranslation()
                    end)
                    return
                end
                item.status = "failed"
                item.error = string.format("仍有 %d 个段落未翻译，可从队列重试", result_failed)
                self:saveTranslationQueue()
                pcall(function() UIManager:close(progress_dialog) end)
                self:startNextQueuedTranslation()
                return
            end
            item.status = "done"
            item.output = result.output
            item.current = result.translated or item.current
            item.translated = result.translated or item.translated
            item.failed = result.failed or item.failed
            item.error = nil
            -- Chapter-mode follow: reaching the last spine chapter ends the
            -- session, otherwise page turns would keep re-queueing an
            -- already-complete final chapter forever.
            if not all_chapters and result.last_chapter then
                self._page_translation_follow_active = nil
            end
            self:saveTranslationQueue()
            -- Drop the finished entry from memory too; it is already
            -- excluded from disk and from the queue dialog, and keeping it
            -- would accumulate one dead entry per finished job.
            for index, queued_item in ipairs(self._translation_queue or {}) do
                if queued_item == item then
                    table.remove(self._translation_queue, index)
                    break
                end
            end
            pcall(function() UIManager:close(progress_dialog) end)
            if not item.silent and not item.auto then
                local done_text = string.format("翻译完成\n已翻译段落：%d\n失败段落：%d",
                    result.translated or 0, result.failed or 0)
                if (result.failed or 0) > 0 then
                    done_text = done_text .. "\n失败段落将在下次翻译时自动重试"
                end
                UIManager:show(Notification:new{
                    text = done_text,
                    timeout = 3,
                })
            end
            UIManager:scheduleIn(0.2, function()
                if self.ui and self.ui.document and self.ui.document.file == book_path then
                    self:saveSetting("translation_visible", true)
                    self:refreshDocumentStyles()
                end
                self:startNextQueuedTranslation()
            end)
        end)
        -- Trapper:wrap runs the worker in a coroutine and reports failures as
        -- resume_ok == false (coroutine error) or wrapped_ok == false (error
        -- caught by Trapper's xpcall).  On some platforms (Android in
        -- particular) a failing subprocess API would otherwise leave
        -- _translation_progress.active stuck at true, which makes every new
        -- translation queue forever without ever starting.  Recover here.
        if resume_ok == false or wrapped_ok == false then
            progress_active = false
            if self._translation_progress then
                self._translation_progress.active = false
            end
            item.status = "failed"
            item.error = "翻译进程异常退出，请查看日志后重试"
            self:saveTranslationQueue()
            pcall(function() UIManager:close(progress_dialog) end)
            logger.warn("dualtranslate: translation worker failed:", wrapped_ok)
            if not item.silent then
                UIManager:show(Notification:new{
                    text = "翻译进程异常退出，已从队列中移除。\n请查看日志后重试。",
                    timeout = 4,
                })
            end
            self:startNextQueuedTranslation()
        end
    end)
end

function dualtranslate:reopenTranslationProgress()
    local progress = self._translation_progress
    if not progress or not progress.active or not progress.dialog then return false end
    local dialog = progress.dialog
    -- Already on screen (the queue menu was merely covering it): nothing to
    -- reopen, the caller has closed the menu.
    if not dialog._dualtranslate_hidden then return true end
    pcall(function()
        dialog._dualtranslate_hidden = false
        dialog:init()
        UIManager:show(dialog)
    end)
    return true
end

function dualtranslate:isCacheEnabled()
    return self:getSetting("enable_cache", true)
end

function dualtranslate:inlineStyleMenu(key, title, choices)
    local items = {}
    for _, choice in ipairs(choices) do
        -- Lua 5.1: capture the per-iteration value; otherwise every menu
        -- entry's checked_func/callback would see the last choice.
        local value, label = choice.value, choice.label
        table.insert(items, {
            text = label,
            radio = true,
            checked_func = function() return self:getSetting(key) == value end,
            callback = function()
                self:saveSetting(key, value)
                self:refreshDocumentStyles()
            end,
        })
    end
    return {
        text = title,
        sub_item_table = items,
    }
end

function dualtranslate:getInlineFontSize()
    local value = tostring(self:getSetting("inline_font_size", 16))
    local number = tonumber(value:match("[%d%.]+")) or 16
    if value:match("%%$") then
        number = 16 * number / 100
    elseif value:match("em$") then
        number = 16 * number
    end
    return math.floor(number + 0.5)
end

function dualtranslate:getInlineFontCssSize()
    -- Treat 16 as the document's 1em base, matching KOReader's numeric font
    -- setting: 20 means 125% of the body text.
    return string.format("%.4gem", self:getInlineFontSize() / 16)
end

-- Translation font family.  "" means "follow the paragraph" (no font-family
-- in the generated CSS, so the ::after node inherits the source paragraph's
-- font); anything else is a CSS font stack injected into the translation CSS.
-- Semicolons/braces are stripped so a hand-edited value can never break the
-- generated stylesheet.
function dualtranslate:getInlineFontFamily()
    local value = tostring(self:getSetting("inline_font_family", ""))
    return value:gsub("[;{}]", "")
end

function dualtranslate:getInlineFontFamilyLabel()
    local value = self:getInlineFontFamily()
    if value == "" then return "跟随段落" end
    if value == "sans-serif" then return "无衬线" end
    if value == "serif" then return "衬线" end
    if value == "monospace" then return "等宽" end
    return value
end

function dualtranslate:showFontFamilyDialog()
    local dialog
    dialog = InputDialog:new{
        title = "自定义译文字体",
        input = self:getInlineFontFamily(),
        input_hint = "输入 CSS 字体栈，如：Noto Serif CJK SC, serif",
        buttons = {{
            {
                text = "取消",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "保存",
                is_enter_default = true,
                callback = function()
                    local value = dialog:getInputText()
                    if value then
                        value = value:gsub("[;{}]", "")
                        self:saveSetting("inline_font_family", value)
                        self:refreshDocumentStyles()
                    end
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function dualtranslate:buildFontFamilyMenu()
    local items = {
        {
            text = "跟随段落（默认）",
            radio = true,
            checked_func = function() return self:getInlineFontFamily() == "" end,
            callback = function()
                self:saveSetting("inline_font_family", "")
                self:refreshDocumentStyles()
            end,
        },
    }
    -- Use KOReader's own font registry (the same face list as the built-in
    -- font menu in 版面→字体): CREngine family names are directly usable as
    -- CSS font-family values.  A device with no CRE engine (unlikely) simply
    -- degrades to the default + custom entry.
    local ok, faces = pcall(function()
        local cre = require("document/credocument"):engineInit()
        return cre.getFontFaces()
    end)
    if ok and faces and #faces > 0 then
        local FontList = require("fontlist")
        local seen = {}
        table.sort(faces)
        for _, face in ipairs(faces) do
            -- Lua 5.1: capture the per-iteration value.
            local face_copy = face
            if not seen[face_copy] then
                seen[face_copy] = true
                local text = face_copy
                -- Prefer the localized display name when CREngine can map the
                -- face back to a font file (mirrors readerfont.lua).
                local ok_name, filename, faceindex = pcall(function()
                    return cre.getFontFaceFilenameAndFaceIndex(face_copy)
                end)
                if ok_name and filename and faceindex then
                    local localized = FontList:getLocalizedFontName(filename, faceindex)
                    if localized then text = localized end
                end
                table.insert(items, {
                    text = text,
                    radio = true,
                    checked_func = function() return self:getInlineFontFamily() == face_copy end,
                    callback = function()
                        self:saveSetting("inline_font_family", face_copy)
                        self:refreshDocumentStyles()
                    end,
                })
            end
        end
    end
    table.insert(items, {
        text = "自定义字体…",
        callback = function() self:showFontFamilyDialog() end,
    })
    return items
end

-- Microsoft Edge accepts an array of texts and returns one translation per
-- item. Batch short paragraphs to reduce network round trips while keeping
-- the original paragraph boundaries for EPUB insertion.
function dualtranslate:translateTextBatchForEpub(texts)
    if self:getMode() ~= "microsoft_free" then
        local results = {}
        local first_error
        for index, text in ipairs(texts) do
            local translated, err = self:translateTextForEpub(text)
            if translated then
                results[index] = translated
            else
                results[index] = false
                first_error = first_error or err
            end
        end
        return results, first_error
    end

    local results = {}
    local pending = {}
    local first_error
    local limit = self:getTranslationChunkLimit()
    for index, text in ipairs(texts) do
        if #text > limit then
            local translated, err = self:translateTextForEpub(text)
            if translated then
                results[index] = translated
            else
                results[index] = false
                first_error = first_error or err
            end
        elseif self:isCacheEnabled() then
            local cached = self.cache:lookupForBook(self._active_translation_book,
                self:getSourceLang(), self:getTargetLang(), text)
            if cached and cached.translated_text then
                results[index] = cached.translated_text
            else
                table.insert(pending, { index = index, text = text })
            end
        else
            table.insert(pending, { index = index, text = text })
        end
    end

    local batch_start = 1
    while batch_start <= #pending do
        local batch, batch_texts = {}, {}
        local total_bytes = 0
        while batch_start <= #pending and #batch < 12 do
            local item = pending[batch_start]
            if #batch > 0 and total_bytes + #item.text > 4000 then break end
            table.insert(batch, item)
            table.insert(batch_texts, item.text)
            total_bytes = total_bytes + #item.text
            batch_start = batch_start + 1
        end
        local mode = self:getMode()
        local translated, err
        translated, err = Providers.translate_microsoft_free_batch(
            batch_texts, self:getSourceLang(), self:getTargetLang())
        if not translated then
            -- One immediate retry handles transient resets without falling
            -- back to a slow request for every paragraph.
            translated, err = Providers.translate_microsoft_free_batch(
                batch_texts, self:getSourceLang(), self:getTargetLang())
        end
        if not translated then
            -- A batch request can time out even though the single-text Edge
            -- endpoint is still responsive. Retry each item only after the
            -- two batch attempts failed; this keeps normal translation fast
            -- while allowing a long English book to recover from a transient
            -- batch failure instead of producing no EPUB at all.
            if err and (err.code ~= nil or err.message) then
                for _, item in ipairs(batch) do
                    local single, single_err = self:translateTextForEpub(item.text)
                    if single then
                        results[item.index] = single
                    else
                        results[item.index] = false
                        first_error = first_error or single_err or err
                    end
                end
            else
                for _, item in ipairs(batch) do results[item.index] = false end
                first_error = first_error or err or { message = "翻译服务连接失败" }
            end
        else
            for offset, item in ipairs(batch) do
                local value = translated[offset]
                if value and value ~= "" then
                    results[item.index] = value
                    if self:isCacheEnabled() then
                        self.cache:storeForBook(self._active_translation_book,
                            self:getSourceLang(), self:getTargetLang(), item.text,
                            value, mode)
                    end
                else
                    results[item.index] = false
                    first_error = first_error or { message = "翻译服务返回了空译文" }
                end
            end
        end
    end
    return results, first_error
end

-- Apply the translation layer styles (non-destructive overlay) without
-- touching the EPUB archive.  Rebuilding this CSS only changes the visible
-- layer; the reading position and the document are left alone.
function dualtranslate:refreshDocumentStyles()
    local document = self.ui and self.ui.document
    local typeset = self.ui and self.ui.typeset
    if not document or not typeset or not document.setStyleSheet then return false end
    local css = typeset.css or document.default_css or ""
    local tweaks = self.ui.styletweak and self.ui.styletweak:getCssText() or ""
    local color = tostring(self:getSetting("inline_color", "#666666"))
    if not color:match("^#%x%x%x%x%x%x$") then color = "#666666" end
    local font_size = self:getInlineFontCssSize()
    local font_family = self:getInlineFontFamily()
    local plugin_enabled = self:isPluginEnabled()
    local book_path = document.file
    local overlay_css = ""
    if book_path then
        -- Visibility (translation_visible + plugin_enabled) is enforced here:
        -- buildCss omits the ::after rules entirely when hidden, so the
        -- source text stays untouched and no empty layer is laid out.
        overlay_css = Overlay.buildCss(self:getTranslationOverlayPath(book_path), {
            translation_visible = plugin_enabled
                and self:getSetting("translation_visible", true) == true,
            translation_color = color,
            translation_size = font_size,
            translation_font_family = font_family,
        })
    end
    local extra_css = tweaks .. "\n" .. overlay_css
    -- Keep this marker on the document object, which survives the rerender
    -- that setStyleSheet itself initiates.  A plugin instance may be rebuilt
    -- during that rerender, so an instance-local flag cannot stop the loop.
    if document._dualtranslate_extra_css == extra_css then return true end
    document._dualtranslate_extra_css = extra_css
    local ok = pcall(function()
        document:setStyleSheet(css, extra_css)
    end)
    if not ok then
        document._dualtranslate_extra_css = nil
    else
        -- setStyleSheet triggers a full re-render.  The reader's pagination
        -- state (page_states in scroll mode, current_page in paging mode) is
        -- not rebuilt by that re-render, so stale page numbers can make the
        -- next page turn mis-fire EndOfBook ("end of book" dialog) while the
        -- book is still mid-way.  Re-sync the way the reader itself does
        -- after a layout change (rotation / resize): refresh the current
        -- page, recalculate the view, then rebuild the scroll page states.
        UIManager:nextTick(function()
            local ui = self.ui
            if not ui or not ui.view then return end
            pcall(function()
                local new_page = document:getCurrentPage()
                if new_page then
                    ui:handleEvent(Event:new("PageUpdate", new_page))
                end
                ui.view:recalculate()
                ui:handleEvent(Event:new("InitScrollPageStates"))
            end)
        end)
    end
    return ok
end


function dualtranslate:showInlineFontSpin()
    local spin
    spin = SpinWidget:new{
        title_text = "译文字号",
        info_text = "点按 - / + 调整，或点按数字直接输入（8–40）",
        value = self:getInlineFontSize(),
        value_min = 8,
        value_max = 40,
        value_step = 1,
        precision = "%d",
        callback = function()
            local size = math.floor(spin.value_widget.value + 0.5)
            size = math.max(8, math.min(40, size))
            self:saveSetting("inline_font_size", size)
            self:refreshDocumentStyles()
        end,
    }
    UIManager:show(spin)
end

end

return Reader
