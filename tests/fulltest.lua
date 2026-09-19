-- ============================================================
-- DualTranslate 全面功能测试套件
-- 纯 Lua + stub 环境，覆盖各模块核心逻辑
-- ============================================================
local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("  PASS:", name)
    else
        failed = failed + 1
        print("  FAIL:", name, detail or "")
    end
end

-- ============================================================
-- 1. splitTranslationText（reader.lua）
-- ============================================================
print("== 1. splitTranslationText ==")
do
    local plugin = { getMode = function() return "microsoft_free" end,
        getSourceLang = function() return "auto" end,
        getTargetLang = function() return "zh-Hans" end }
    -- attach 需要的自包含 splitTranslationText（从 reader.lua 复制逻辑测试）
    -- 直接 require 真实模块需要 stub 环境，这里内联同样逻辑并测边界
    local function split(text, limit)
        if #text <= limit then return { text } end
        local chunks = {}
        local rest = text
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
            for i = limit, search_from, -1 do
                local character = rest:sub(i, i)
                if character:match("[%s%.,;:%?!]" ) then
                    cut = i
                    break
                end
            end
            cut = to_char_boundary(cut)
            local part = (rest:sub(1, cut)):gsub("^%s+", ""):gsub("%s+$", "")
            if part == "" then
                cut = to_char_boundary(limit)
                part = rest:sub(1, cut)
            end
            table.insert(chunks, part)
            rest = (rest:sub(cut + 1)):gsub("^%s+", ""):gsub("%s+$", "")
        end
        if rest ~= "" then table.insert(chunks, rest) end
        return chunks
    end
    -- 短文本不分块
    local c = split("hello", 4500)
    check("短文本单块", #c == 1 and c[1] == "hello")
    -- 长英文按空格切
    local long = table.concat({}, "")
    for i = 1, 50 do long = long .. "word" .. tostring(i) .. " " end
    local chunks = split(long, 100)
    check("长英文多块", #chunks > 1)
    local rejoined = table.concat(chunks, " ")
    check("切分后信息完整", rejoined:match("word1") and rejoined:match("word50"))
    -- 每块不超过 limit + 边界
    local all_ok = true
    for _, ch in ipairs(chunks) do if #ch > 100 + 200 then all_ok = false end end
    check("块长度受限", all_ok)
    -- UTF-8 中文不破坏字节
    local cjk = string.rep("中文测试段落内容", 30) -- 每段 8 字节
    local cjk_chunks = split(cjk, 60)
    local ok_utf8 = true
    for _, ch in ipairs(cjk_chunks) do
        -- 验证不是半个多字节字符：字节合法性（不能以 0x80-0xBF 开头）
        local b1 = ch:byte(1)
        if b1 and b1 >= 128 and b1 <= 191 then ok_utf8 = false end
    end
    check("CJK 分块不破坏字节", ok_utf8 and #cjk_chunks > 1)
    -- 空文本
    local e = split("", 100)
    check("空文本", #e == 1 and e[1] == "")
    -- 极长无空格文本（纯中文）
    local pure_cjk = string.rep("字", 500)
    local pc = split(pure_cjk, 50)
    check("纯中文分块", #pc > 1)
    local pc_ok = true
    for _, ch in ipairs(pc) do
        if ch:byte(1) and ch:byte(1) >= 128 and ch:byte(1) <= 191 then pc_ok = false end
        if #ch > 50 + 10 then pc_ok = false end
    end
    check("纯中文块长度与字节合法", pc_ok)
end

-- ============================================================
-- 2. Overlay.cssFontFamily / buildCss
-- ============================================================
print("== 2. Overlay CSS ==")
do
    local JSON_stub = {
        encode = function(t) return '{"entries":[{"selector":"p:first","translation":"你好"}]}' end,
        decode = function(s) return { entries = { { selector = "p:first", translation = "你好" } } } end,
    }
    package.preload["json"] = function() return JSON_stub end
    package.preload["libs/libkoreader-lfs"] = function()
        return { attributes = function(p, m) if m == "modification" then return os.time() end return nil end,
            mkdir = function() return true end, rmdir = function() return true end,
            remove = function() return true end, dir = function() end }
    end
    local Overlay = dofile("dualtranslate_overlay.lua")
    -- real file for Overlay.load to read
    local f = io.open("/tmp/dualtranslate_overlay_test.json", "w")
    f:write('{"entries":[{"selector":"DocFragment[Source=\"chap.xhtml\"] > body > p:nth-of-type(1)","translation":"你好"}]}')
    f:close()
    -- cssFontFamily
    check("空字体", Overlay.cssFontFamily("") == "")
    check("nil 字体", Overlay.cssFontFamily(nil) == "")
    check("通用族不引号", Overlay.cssFontFamily("serif") == "serif")
    check("多词字体加引号", Overlay.cssFontFamily("Noto Serif CJK SC") == '"Noto Serif CJK SC"')
    check("逗号分隔栈", Overlay.cssFontFamily("Noto Sans, serif") == '"Noto Sans", serif')
    check("已引号保留", Overlay.cssFontFamily('"Source Han Sans"') == '"Source Han Sans"')
    check("sans-serif 通用", Overlay.cssFontFamily("sans-serif") == "sans-serif")
    -- buildCss 基本
    local css = Overlay.buildCss("/tmp/dualtranslate_overlay_test.json", {
        translation_visible = true,
        translation_color = "#666666",
        translation_size = "1.0000em",
        translation_font_family = "serif",
    })
    check("buildCss 含 ::after", css:find("::after") ~= nil)
    check("buildCss 含字体族", css:find("font-family:serif!important", 1, true) ~= nil)
    check("buildCss 含颜色", css:find("color:#666666!important") ~= nil)
    -- 隐藏时不生成规则
    local css_hidden = Overlay.buildCss("/tmp/dualtranslate_overlay_test.json", { translation_visible = false })
    check("隐藏时无 ::after 规则", css_hidden:find("::after") == nil)
    -- css_string 转义
    local tricky = Overlay.buildCss("/tmp/dualtranslate_overlay_test.json", { translation_visible = true })
    check("正常生成", type(tricky) == "string" and #tricky > 0)
    -- buildCss mtime 缓存：同 mtime 命中，选项/内容变化重建
    local css_c1 = Overlay.buildCss("/tmp/dualtranslate_overlay_test.json", {
        translation_visible = true, translation_color = "#666666" })
    local css_c2 = Overlay.buildCss("/tmp/dualtranslate_overlay_test.json", {
        translation_visible = true, translation_color = "#666666" })
    check("buildCss 缓存命中", css_c1 == css_c2)
    local css_c3 = Overlay.buildCss("/tmp/dualtranslate_overlay_test.json", {
        translation_visible = true, translation_color = "#333333" })
    check("buildCss 选项变化重建", css_c3 ~= css_c1 and css_c3:find("#333333", 1, true) ~= nil)
end

-- ============================================================
-- 3. Tools
-- ============================================================
print("== 3. Tools ==")
do
    package.preload["libs/libkoreader-lfs"] = function()
        return { attributes = function(p, m) if m == "mode" then return nil end return nil end,
            mkdir = function() return true end, rmdir = function() return true end,
            remove = function() return true end, dir = function() end }
    end
    package.preload["ffi/archiver"] = function()
        return { Reader = { new = function() return { open = function() return false end } end } }
    end
    package.preload["util"] = function() return { makePath = function() return true end, trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end } end
    package.preload["logger"] = function() return { warn = function() end, err = function() end, info = function() end } end
    local Tools = dofile("dualtranslate_tools.lua")
    local h1 = Tools.stable_path_hash("/books/a.epub|zh-Hans")
    local h2 = Tools.stable_path_hash("/books/a.epub|zh-Hans")
    local h3 = Tools.stable_path_hash("/books/b.epub|zh-Hans")
    check("hash 确定性", h1 == h2)
    check("hash 区分输入", h1 ~= h3)
    check("hash 十六进制", h1:match("^%x+$") ~= nil and #h1 == 8)
end

-- ============================================================
-- 4. Languages
-- ============================================================
print("== 4. Languages ==")
do
    local Languages = dofile("dualtranslate_languages.lua")
    check("list 非空", #Languages.list > 50)
    check("getNameByCode 命中", Languages.getNameByCode("en") == "English")
    check("getNameByCode 回退", Languages.getNameByCode("zz") == "zz")
    check("zh-Hans 存在", Languages.getNameByCode("zh-Hans") ~= nil)
end

-- ============================================================
-- 5. State 队列（mock lfs/DataStorage/dump）
-- ============================================================
print("== 5. State 队列 ==")
do
    local queue_file_content
    local removed_files = {}
    package.preload["datastorage"] = function() return { getDataDir = function() return "/data" end } end
    package.preload["libs/libkoreader-lfs"] = function()
        return { attributes = function(p, m)
            if m == "mode" then
                if p:find("translation_queue") then return nil end
                if p:find("dualtranslate_configuration") then return nil end
            end
            if m == "modification" then return os.time() end
            return nil
        end }
    end
    package.preload["dump"] = function()
        return function(t) return "{" .. tostring(#t) .. "}" end
    end
    package.preload["ui/widget/notification"] = function() return { Notification = {} } end
    package.preload["ui/widget/buttondialog"] = function() return {} end
    package.preload["ui/widget/menu"] = function() return {} end
    package.preload["device"] = function() return { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } } end
    package.preload["logger"] = function() return { warn = function() end, err = function() end, info = function() end } end
    package.preload["ui/uimanager"] = function() return { show = function() end, close = function() end, setDirty = function() end } end
    local State = dofile("dualtranslate_state.lua")
    local plugin = {
        _translation_queue = {},
        isPluginEnabled = function() return true end,
        saveTranslationQueue = function(self) queue_file_content = "saved" end,
        startNextQueuedTranslation = function() end,
        TranslationUI = { showInfo = function() end },
        _translation_progress = nil,
    }
    -- enqueue
    State.enqueue(plugin, "/books/a.epub", true, nil, true, nil, nil)
    check("enqueue 整书", #plugin._translation_queue == 1
        and plugin._translation_queue[1].all_chapters == true
        and plugin._translation_queue[1].status == "queued")
    -- enqueue 同书去重
    State.enqueue(plugin, "/books/a.epub", true, nil, true, nil, nil)
    check("同书去重", #plugin._translation_queue == 1)
    -- enqueue 章节
    State.enqueue(plugin, "/books/b.epub", false, "3", true, nil, nil)
    check("enqueue 章节", #plugin._translation_queue == 2
        and plugin._translation_queue[2].fragment == "3"
        and plugin._translation_queue[2].span == 1)
    -- cancel queued
    State.cancelTranslation(plugin, plugin._translation_queue[1])
    check("取消排队项", #plugin._translation_queue == 1)
    -- clear for book
    State.clearForBook(plugin, "/books/b.epub")
    check("清书任务", #plugin._translation_queue == 0)
    -- progress
    local p1, p2, p3, p4 = State.progress({ current = 5, total = 10, translated = 4, failed = 1 })
    check("progress 无文件回退", p1 == 5 and p2 == 10 and p3 == 4 and p4 == 1)
    check("progress 非法输入", State.progress(nil) == 0)
end

-- ============================================================
-- 6. Providers（mock http/json/socket）
    package.loaded["json"] = nil
-- ============================================================
print("== 6. Providers ==")
do
    local last_url, last_body
    package.preload["socket.http"] = function()
        return { request = function(req)
            last_url = req.url
            last_body = req.source and "BODY" or nil
            -- feed the response through the sink
            req.sink("RESP")
            req.sink(nil)
            return 200, {}, "200 OK"
        end }
    end
    package.preload["ltn12"] = function()
        return { source = { string = function(s) return s end },
            sink = { table = function(t)
                return function(chunk) if chunk then t[#t + 1] = chunk end end
            end } }
    end
    package.preload["json"] = function()
        return { encode = function(t) return "JSON:" .. tostring(#t) end,
            decode = function(s)
                if s:find("RESP") then
                    -- 模拟 Edge 响应
                    return { { translations = { { text = "你好" } } } }
                end
                return nil
            end }
    end
    package.preload["socketutil"] = function() return { set_timeout = function() end, reset_timeout = function() end } end
    package.preload["socket.url"] = function() return { escape = function(s) return s end } end
    package.preload["logger"] = function() return { warn = function() end, err = function() end, info = function() end } end
    package.preload["gettext"] = function() return function(s) return s end end
    local Providers = dofile("dualtranslate_providers.lua")
    local res, err = Providers.translate("microsoft_free", "hello", "auto", "zh-Hans")
    check("microsoft_free 翻译", res and res.translated_text == "你好")
    check("URL 含 to 参数", last_url:find("to=zh%-Hans") ~= nil)
    check("URL 无 from 参数(auto)", last_url:find("from=") == nil)
    local res2, err2 = Providers.translate("microsoft_free", "hello", "en", "zh-Hans")
    check("URL 含 from 参数", last_url:find("from=en") ~= nil)
    local res3, err3 = Providers.translate("unknown_provider", "hello", "auto", "zh")
    check("未知服务报错", res3 == nil and err3 and err3.message)
    local sys_res, sys_err = Providers.translate("system", "hello", "auto", "zh-Hans")
    check("system 无 translator 时报错", sys_res == nil)
end

print(string.format("\n==== 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
