-- Per-page translation, document-flow edition.
--
-- Instead of painting framebuffer overlays with a line cap, page translation
-- now reuses the full-book overlay pipeline: translating the current chapter
-- writes entries into the per-book overlay.json, which refreshDocumentStyles
-- exposes to CREngine as generated ::after CSS.  The translation therefore
-- lives in the document flow exactly like the book-level overlay: complete
-- text, toggleable visibility, persistent across reopens, no line limit.
--
-- Exposed as the "逐章模式" checkbox next to "翻译本书": checking it is a
-- preference only.  Tapping "翻译本书" while it is checked translates the
-- current chapter (with the normal progress dialog) and arms the follow
-- mode; turning pages then keeps translating each newly reached chapter
-- silently through the serial queue.  Already translated paragraphs are
-- reused by the overlay merge and never re-requested.
local UIManager = require("ui/uimanager")
local Overlay = require("dualtranslate_overlay")

local PageTrans = {}

function PageTrans.attach(plugin)
    plugin.isPageTranslationEnabled = function()
        return plugin:getSetting("page_translation", false) == true
    end

    -- "逐章模式" is a preference only: checking it does not translate
    -- anything.  Tapping "翻译本书" while it is checked translates the
    -- current chapter and arms the follow mode; turning the checkbox off
    -- disarms it so page turns stop scheduling new chapters.
    plugin.togglePageTranslation = function(self, menu)
        local enabled = not self:isPageTranslationEnabled()
        self:saveSetting("page_translation", enabled)
        if not enabled then
            self._page_translation_follow_active = nil
        end
        UIManager:setDirty("all", "ui")
        if menu and menu.updateItems then menu:updateItems() end
    end

    -- Called from onPageUpdate / onPosUpdate / onDocumentRerendered (silent,
    -- auto-continue) and from translateBook in follow mode (silent=false, so
    -- the initial chapter translation shows its progress dialog).
    -- Queues the current chapter when this book has no complete overlay yet.
    -- The serial queue deduplicates by book, and the overlay merge is
    -- idempotent, so repeated page turns never re-translate already-covered
    -- paragraphs.
    plugin.maybeSchedulePageTranslation = function(self, silent)
        if not self:isPageTranslationEnabled() then return end
        -- Only auto-continue while a follow session was explicitly started
        -- from "翻译本书" (or its chapter-mode variant).
        if not self._page_translation_follow_active then return end
        if not self:isEpub() then return end
        -- Never compete with a running full-book/chapter worker writing
        -- overlay.json.
        if self._translation_progress and self._translation_progress.active then
            return
        end
        local book_path = self.ui and self.ui.document and self.ui.document.file
        if not book_path then return end
        -- Same-chapter guard: page turns inside the current chapter must not
        -- re-queue it after its job finished (the job is idempotent, but the
        -- queue entry and the completion toast would be pure noise).  When
        -- the chapter resolver is unavailable the fragment is nil; use a
        -- sentinel so we still de-duplicate instead of re-queueing chapter 1
        -- on every page turn.
        local fragment = self:getCurrentFragment()
        local fragment_key = fragment or "__unknown_fragment__"
        if fragment_key == self._page_translation_last_fragment then return end
        -- The whole book is already translated: nothing left to schedule.
        -- Cache the overlay's complete flag briefly so ordinary page turns
        -- do not re-read and re-parse overlay.json every time.
        local get_overlay = self.getTranslationOverlayPath
        local overlay = get_overlay and get_overlay(self, book_path)
        if overlay then
            local cached = self._page_translation_overlay_state
            local now = os.time()
            if not cached or cached.path ~= overlay or now - cached.at > 3 then
                local data = Overlay.load(overlay)
                cached = {
                    path = overlay,
                    complete = data and data.complete == true or false,
                    chapters = data and data.chapters or nil,
                    at = now,
                }
                self._page_translation_overlay_state = cached
            end
            if cached.complete then return end
            -- Chapter-mode runs never set complete, so "this chapter is
            -- already translated" is tracked through the overlay's chapters
            -- list.  Without this check, turning back into a covered chapter
            -- (or a mis-resolved fragment pointing at one) re-queues it and
            -- the overlay merge finishes it instantly at 100% with zero
            -- requests — the "点翻页直接显示翻完了" symptom.
            if cached.chapters and type(cached.chapters) == "table" then
                local fragment_index = tonumber(fragment_key)
                if fragment_index then
                    for _, covered in ipairs(cached.chapters) do
                        if covered == fragment_index then return end
                    end
                end
            end
        end
        -- Queue the current chapter; silent only for auto-continue page turns.
        -- auto marks the job as page-turn driven so the completion toast is
        -- suppressed (the progress dialog is still shown — that was an
        -- explicit user request — but a toast on every chapter is noise).
        self._page_translation_last_fragment = fragment_key
        self:translateBook(false, silent == true, nil, true)
    end
end

return PageTrans
