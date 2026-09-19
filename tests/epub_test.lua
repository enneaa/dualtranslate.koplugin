-- ============================================================
-- EPUB 专项测试：resolve / html_to_text / collect_overlay_candidates
-- / translate_overlay 完整流程
-- ============================================================
local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("  PASS:", name)
    else failed = failed + 1; print("  FAIL:", name, detail or "") end
end

local TEST_DIR = "/tmp/dualtranslate_epub_test"
os.execute("rm -rf " .. TEST_DIR)
os.execute("mkdir -p " .. TEST_DIR .. "/META-INF")
os.execute("mkdir -p " .. TEST_DIR .. "/OEBPS")

-- 构造 EPUB 结构：container.xml + OPF + 两章 XHTML
local function write(p, content)
    local f = io.open(TEST_DIR .. "/" .. p, "w")
    f:write(content); f:close()
end
write("META-INF/container.xml", [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]])
write("OEBPS/content.opf", [[<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <manifest>
    <item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="chap2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>]])
write("OEBPS/chap1.xhtml", [[<?xml version="1.0"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter 1</title></head>
<body>
  <h1>Hello World</h1>
  <p>This is the first paragraph.</p>
  <p>Second paragraph with <b>bold</b> and <i>italic</i> text.</p>
  <p>日本語のテキストです。</p>
  <p><img src="a.png"/></p>
  <p>  &nbsp; &amp; &lt; entities &gt; &quot;quoted&quot; &#39;apos&#39;  </p>
</body>
</html>]])
write("OEBPS/chap2.xhtml", [[<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter 2</title></head>
<body><p>Chapter two content.</p></body></html>]])

-- ============================================================
-- 1. Epub.resolve
-- ============================================================
print("== 1. Epub.resolve ==")
do
    package.preload["ffi/archiver"] = function() return {} end
    package.preload["dualtranslate_overlay"] = function() return {} end
    package.preload["dualtranslate_tools"] = function() return { mkdir_p = function() return true end, unzip_to = function() return true end, rmtree = function() return true end, stable_path_hash = function() return "x" end } end
    package.preload["datastorage"] = function() return { getDataDir = function() return "/tmp/dt_data" end } end
    package.preload["socket.url"] = function() return { escape = function(s) return s end, unescape = function(s) return s end } end
    local Epub = dofile("dualtranslate_epub.lua")
    local res, err = Epub:resolve("/books/x.epub", TEST_DIR, "1")
    check("resolve 成功", res ~= nil, tostring(err))
    check("resolve 第一章", res and res.relative == "OEBPS/chap1.xhtml")
    check("resolve spine_count", res and res.spine_count == 2)
    check("resolve absolute", res and res.absolute == TEST_DIR .. "/OEBPS/chap1.xhtml")
    local res2 = Epub:resolve("/books/x.epub", TEST_DIR, "2")
    check("resolve 第二章", res2 and res2.relative == "OEBPS/chap2.xhtml")
    local res3 = Epub:resolve("/books/x.epub", TEST_DIR, nil)
    check("resolve 默认第一章", res3 and res3.relative == "OEBPS/chap1.xhtml")
    local res4 = Epub:resolve("/books/x.epub", TEST_DIR, "/body/DocFragment[2]/body")
    check("resolve xpointer 带索引", res4 and res4.relative == "OEBPS/chap2.xhtml")
    -- 不存在目录
    local bad = Epub:resolve("/books/x.epub", "/nonexistent", "1")
    check("resolve 找不到 container", bad == nil)
end

-- ============================================================
-- 2. html_to_text + collect_overlay_candidates（内联副本）
-- ============================================================
print("== 2. collect_overlay_candidates ==")
do
    -- 从 epub.lua 复制关键局部函数（与源码一致的逻辑）
    local function html_to_text(html)
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
    local overlay_target_tags = { p = true, h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true, figcaption = true, dt = true, dd = true }
    local void_tags = { area = true, base = true, br = true, col = true, embed = true, hr = true, img = true, input = true, link = true, meta = true, param = true, source = true, track = true, wbr = true }
    local function css_attribute(value) return tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"') end
    local function looks_translatable(text)
        if not text or text == "" then return false end
        if text:match("%a") then return true end
        return text:match("[\128-\255]") ~= nil
    end
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
                                        selector = 'DocFragment[Source="' .. css_attribute(relative) .. '"] > body' .. node.path,
                                        xpointer = "/body/DocFragment" .. (fragment_index > 1 and ("[" .. tostring(fragment_index) .. "]") or "") .. "/body" .. node.xpath,
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
                            path = ""; xpath = ""
                        elseif in_body then
                            path = path .. " > " .. name .. ":nth-of-type(" .. tostring(parent.counts[name]) .. ")"
                            xpath = xpath .. "/" .. name .. (parent.counts[name] > 1 and ("[" .. tostring(parent.counts[name]) .. "]") or "")
                        end
                        local node = { name = name, counts = {}, in_body = in_body, path = path, xpath = xpath, inner_start = tag_end + 1, target = in_body and targets[name] == true }
                        local self_closing = raw:match("/%s*>$") ~= nil or void_tags[name]
                        if not self_closing then table.insert(stack, node) end
                    end
                end
            end
        end
        return candidates
    end
    local doc = io.open(TEST_DIR .. "/OEBPS/chap1.xhtml", "r"):read("*a")
    local candidates = collect_overlay_candidates(doc, "OEBPS/chap1.xhtml", 1, false)
    for i, c in ipairs(candidates) do print("    candidate[" .. i .. "]:", c.source) end
    check("candidates 数量", #candidates == 5, "got " .. #candidates)
    -- h1 + 3 个 p（img 段落无文字跳过、实体段落是纯符号跳过）
    -- h1
    check("h1 捕获", candidates[1] and candidates[1].source == "Hello World")
    check("h1 selector 正确", candidates[1] and candidates[1].selector == 'DocFragment[Source="OEBPS/chap1.xhtml"] > body > h1:nth-of-type(1)')
    check("h1 xpointer", candidates[1] and candidates[1].xpointer == "/body/DocFragment/body/h1")
    -- p 的 nth-of-type
    check("p1 捕获", candidates[2] and candidates[2].source == "This is the first paragraph.")
    check("p1 selector", candidates[2] and candidates[2].selector:find("> p:nth-of-type(1)", 1, true) ~= nil)
    -- 嵌套 b/i 标签剥离
    check("嵌套标签剥离", candidates[3] and candidates[3].source == "Second paragraph with bold and italic text.")
    -- CJK
    check("CJK 捕获", candidates[4] and candidates[4].source == "日本語のテキストです。")
    -- div_fallback
    local doc2 = io.open(TEST_DIR .. "/OEBPS/chap2.xhtml", "r"):read("*a")
    local c2 = collect_overlay_candidates(doc2, "OEBPS/chap2.xhtml", 2, false)
    check("chap2 捕获", #c2 == 1 and c2[1].source == "Chapter two content.")
    check("chap2 xpointer 带索引", c2[1].xpointer == "/body/DocFragment[2]/body/p")
end

-- ============================================================
-- 3. translate_overlay 完整流程（mock 解压 + mock 翻译）
-- ============================================================
print("== 3. translate_overlay 流程 ==")
do
    -- 复用 epub.lua 真实模块（重新加载，避免上面 dofile 的副本干扰）
    package.preload["ffi/archiver"] = function() return {} end
    package.preload["dualtranslate_overlay"] = function()
        return { save = function(path, data) return true end, load = function(path) return nil end }
    end
    package.preload["dualtranslate_tools"] = function()
        return {
            mkdir_p = function(p) os.execute("mkdir -p " .. p) return true end,
            unzip_to = function(src, dest) return true end, -- 测试环境 work_dir 已预置
            rmtree = function(p) os.execute("rm -rf " .. p) return true end,
            stable_path_hash = function() return "x" end,
        }
    end
    package.preload["datastorage"] = function() return { getDataDir = function() return "/tmp/dt_data" end } end
    package.preload["socket.url"] = function() return { escape = function(s) return s end, unescape = function(s) return s end } end
    local Epub = dofile("dualtranslate_epub.lua")

    -- 构造 work_dir（模拟解压结果）指向 TEST_DIR
    -- translate_overlay 内部用 data_dir .. "/cache/dualtranslate/overlay_<nonce>" 作为 work_dir，
    -- 并调用 Tools.unzip_to(book_path, work_dir)。mock unzip_to 把 TEST_DIR 内容拷过去。
    -- 简单起见：mock unzip_to 直接把 book_path 当 work_dir 源。
    -- 这里重写 mock：unzip_to 返回 true，并在调用后把 TEST_DIR 拷到 dest
    package.preload["dualtranslate_tools"] = function()
        return {
            mkdir_p = function(p) os.execute("mkdir -p " .. p) return true end,
            unzip_to = function(src, dest)
                os.execute("rm -rf " .. dest)
                os.execute("mkdir -p " .. dest)
                os.execute("cp -r " .. TEST_DIR .. "/. " .. dest .. "/")
                return true
            end,
            rmtree = function(p) os.execute("rm -rf " .. p) return true end,
            stable_path_hash = function() return "x" end,
        }
    end
    -- Overlay.save 记录到真实文件
    package.preload["dualtranslate_overlay"] = function()
        return {
            save = function(path, data)
                local f = io.open(path, "w"); f:write("saved:" .. tostring(data.complete) .. ":" .. tostring(#data.entries) .. ":" .. tostring(data.chapters and #data.chapters or 0)); f:close()
                return true
            end,
            load = function(path) return nil end,
        }
    end
    -- 重新加载 Epub（Tools mock 变了；require 缓存也要清）
    package.loaded["dualtranslate_epub"] = nil
    package.loaded["dualtranslate_tools"] = nil
    package.loaded["dualtranslate_overlay"] = nil
    package.loaded["datastorage"] = nil
    local Epub2 = dofile("dualtranslate_epub.lua")

    -- 运行：整书翻译
    local output_dir = "/tmp/dualtranslate_out1"
    os.execute("rm -rf " .. output_dir)
    local translated_texts = {}
    local progress_path = "/tmp/dualtranslate_prog.txt"
    local progress_seen
    local result, err = Epub2:translate_overlay("/books/x.epub", "1", "zh-Hans", "auto",
        function(text)
            if not progress_seen then
                local f = io.open(progress_path, "r")
                if f then progress_seen = f:read("*l"); f:close() end
            end
            return "T:" .. text
        end, -- 单条翻译
        true, -- all_chapters
        progress_path,
        function(texts) -- 批量翻译（真实主路径）
            if not progress_seen then
                local f = io.open(progress_path, "r")
                if f then progress_seen = f:read("*l"); f:close() end
            end
            local out = {}
            for i, t in ipairs(texts) do out[i] = "B:" .. t end
            return out
        end,
        output_dir,
        nil, -- span
        nil) -- cancel_path
    check("整书翻译成功", result ~= nil, tostring(err))
    check("整书翻译输出", result and result.overlay == true)
    check("整书翻译章节数", result and result.chapters == 2)
    check("整书翻译段落数", result and result.translated == 6, "got " .. tostring(result and result.translated))
    -- overlay 持久化 chapters 覆盖标记（整书=2 章）
    local saved1 = io.open("/tmp/dualtranslate_out1/overlay.json", "r")
    local saved1_line = saved1 and saved1:read("*l")
    if saved1 then saved1:close() end
    check("整书 chapters 覆盖标记", saved1_line and saved1_line:match(":2$") ~= nil, tostring(saved1_line))
    -- 进度文件存在且格式正确
    check("进度文件在过程中写入", progress_seen ~= nil, tostring(progress_seen))
    check("进度文件格式", progress_seen and progress_seen:match("^(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)$") ~= nil, tostring(progress_seen))

    -- 章节模式（span=1）
    local output_dir2 = "/tmp/dualtranslate_out2"
    os.execute("rm -rf " .. output_dir2)
    local progress_path2 = "/tmp/dualtranslate_prog2.txt"
    local result2, err2 = Epub2:translate_overlay("/books/x.epub", "2", "zh-Hans", "auto",
        function(text) return "T:" .. text end,
        false, -- 章节
        progress_path2,
        function(texts) local out = {} for i, t in ipairs(texts) do out[i] = "B:" .. t end return out end,
        output_dir2, 1, nil)
    check("章节模式成功", result2 ~= nil, tostring(err2))
    check("章节模式只翻一章", result2 and result2.chapters == 1)
    check("章节模式段落数", result2 and result2.translated == 1)
    -- 章节模式写 chapters=[2]（本次只覆盖第 2 章）且不写 complete
    local saved2 = io.open("/tmp/dualtranslate_out2/overlay.json", "r")
    local saved2_line = saved2 and saved2:read("*l")
    if saved2 then saved2:close() end
    check("章节模式 chapters 覆盖标记", saved2_line and saved2_line:match("^saved:false:%d+:1$") ~= nil, tostring(saved2_line))

    -- 取消标志
    local output_dir3 = "/tmp/dualtranslate_out3"
    os.execute("rm -rf " .. output_dir3)
    local cancel_flag = "/tmp/dualtranslate_cancel.txt"
    local f = io.open(cancel_flag, "w"); f:write("x"); f:close()
    local result3 = Epub2:translate_overlay("/books/x.epub", "1", "zh-Hans", "auto",
        function(text) return "T:" .. text end, true, "/tmp/dualtranslate_prog3.txt",
        function(texts) local out = {} for i, t in ipairs(texts) do out[i] = "B:" .. t end return out end,
        output_dir3, nil, cancel_flag)
    check("取消标志生效", result3 and result3.cancelled == true)
    os.remove(cancel_flag)

    -- 非 EPUB 报错
    local bad_res, bad_err = Epub2:translate_overlay("/books/x.txt", "1", "zh-Hans", "auto",
        function(text) return "T" end, true, "/tmp/p.txt",
        function(texts) return {} end, "/tmp/out4", nil, nil)
    check("非 EPUB 报错", bad_res == nil and bad_err and bad_err:find("EPUB") ~= nil)
end

print(string.format("\n==== EPUB 结果：%d 通过，%d 失败 ====", passed, failed))
os.exit(failed == 0 and 0 or 1)
