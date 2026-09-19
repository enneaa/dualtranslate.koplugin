-- The small, keyless provider core used by DualTranslate.
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local socketutil = require("socketutil")
local _ = require("gettext")

local Providers = {}

Providers.list = {
    { id = "system", name = "KOReader 内置翻译（跟随系统设置）", requires_api_key = false,
      description = _("Use KOReader's built-in translator engine (configured in KOReader -> Translation)") },
    { id = "microsoft_free", name = "Microsoft Edge（免费）", requires_api_key = false,
      description = _("Microsoft Edge web endpoint (no API key)") },
}

-- ---------------------------------------------------------------------------
-- KOReader built-in translator (frontend/ui/translator.lua).
-- Uses whatever engine the user picked in KOReader -> Translation settings
-- (the built-in only ships Google, but users may point trans_server at a
-- mirror/custom endpoint).  It exposes single-text translate() only, so the
-- batch path below loops over it.
-- ---------------------------------------------------------------------------
local function getSystemTranslator()
    local ok, Translator = pcall(require, "ui/translator")
    if ok and Translator then return Translator end
    return nil
end

-- Map DualTranslate's BCP-47 codes onto the codes the built-in translator
-- expects (its SUPPORTED_LANGUAGES table uses "zh"/"zh-TW"; Google accepts
-- the plain forms too).  Anything unknown passes through untouched.
local function normalizeLangForSystem(lang)
    if lang == "zh-Hans" then return "zh" end
    if lang == "zh-Hant" then return "zh-TW" end
    return lang
end

function Providers.translate_system(text, source_lang, target_lang)
    local Translator = getSystemTranslator()
    if not Translator then
        return nil, { message = _("KOReader 内置翻译器不可用（ui/translator 加载失败）") }
    end
    -- The built-in translator manages its own target/source language from
    -- G_reader_settings.  We still forward explicit langs when provided, so
    -- DualTranslate's per-book settings win when set.
    local ok, translated = pcall(Translator.translate, Translator, text,
        normalizeLangForSystem(target_lang), normalizeLangForSystem(source_lang))
    if not ok or not translated or translated == "" then
        logger.warn("dualtranslate: system translator failed:", translated)
        return nil, { message = _("KOReader 内置翻译失败，请检查 KOReader 翻译设置与网络") }
    end
    return { translated_text = translated, source_lang = source_lang,
        target_lang = target_lang, provider = "system" }
end

-- Batch loop over the built-in translator.  The built-in translator exposes
-- only a single-text translate(), so system mode always loops one request per
-- paragraph; it never uses a native batch endpoint.  (The separately
-- selectable Microsoft Edge provider has its own native batch path.)
function Providers.translate_system_batch(texts, source_lang, target_lang)
    local result = {}
    for i, text in ipairs(texts) do
        local translated, err = Providers.translate_system(text, source_lang, target_lang)
        if not translated then
            return nil, err
        end
        result[i] = translated.translated_text
    end
    return result
end

local function httpRequest(method, url, body, headers)
    local response_body = {}
    headers = headers or {}
    headers["Accept"] = headers["Accept"] or "application/json"
    if body and not headers["Content-Length"] then
        headers["Content-Length"] = tostring(#body)
    end
    socketutil:set_timeout(15, 15)
    local code, resp_headers, status = http.request{
        url = url, method = method, headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response_body),
    }
    socketutil:reset_timeout()
    local raw = table.concat(response_body)
    local ok, data = pcall(json.decode, raw)
    if not ok or not data then
        logger.warn("dualtranslate: provider HTTP error", code, status, raw:sub(1, 160))
        return nil, { code = code,
            message = (not code or code == 1)
                and "翻译服务连接失败，请检查网络"
                or string.format("翻译服务返回 HTTP %s", tostring(code)) }
    end
    if data.error then
        local message = type(data.error) == "table" and data.error.message or data.error
        return nil, { code = code, message = tostring(message or "翻译服务错误") }
    end
    return data
end

local function urlEncode(value)
    return require("socket.url").escape(tostring(value or ""))
end

local function jsonPost(url, payload)
    return httpRequest("POST", url, json.encode(payload), {
        ["Content-Type"] = "application/json",
    })
end

function Providers.translate_microsoft_free(text, source_lang, target_lang)
    local url = "https://edge.microsoft.com/translate/translatetext?isEnterpriseClient=false&to="
        .. urlEncode(target_lang)
    if source_lang and source_lang ~= "auto" then
        url = url .. "&from=" .. urlEncode(source_lang)
    end
    local data, err = jsonPost(url, { text })
    if not data then return nil, err end
    if data[1] and data[1].translations and data[1].translations[1] then
        return { translated_text = data[1].translations[1].text,
            source_lang = source_lang, target_lang = target_lang,
            provider = "microsoft_free" }
    end
    return nil, { message = _("Microsoft Edge returned no translation") }
end

function Providers.translate_microsoft_free_batch(texts, source_lang, target_lang)
    local url = "https://edge.microsoft.com/translate/translatetext?isEnterpriseClient=false&to="
        .. urlEncode(target_lang)
    if source_lang and source_lang ~= "auto" then
        url = url .. "&from=" .. urlEncode(source_lang)
    end
    local data, err = jsonPost(url, texts)
    if not data then return nil, err end
    local result = {}
    for index, item in ipairs(data) do
        if not item.translations or not item.translations[1]
            or not item.translations[1].text then
            return nil, { message = _("Microsoft Edge returned an incomplete batch") }
        end
        result[index] = item.translations[1].text
    end
    if #result ~= #texts then
        return nil, { message = _("Microsoft Edge returned an incomplete batch") }
    end
    return result
end

function Providers.translate(provider_id, text, source_lang, target_lang)
    if provider_id == "system" then
        return Providers.translate_system(text, source_lang, target_lang)
    elseif provider_id == "microsoft_free" then
        return Providers.translate_microsoft_free(text, source_lang, target_lang)
    end
    return nil, { message = "未知翻译服务，请选择 KOReader 内置或 Microsoft Edge" }
end

function Providers.getProviderById(id)
    for _, provider in ipairs(Providers.list) do
        if provider.id == id then return provider end
    end
end

function Providers.getProviderName(id)
    local provider = Providers.getProviderById(id)
    return provider and provider.name or "未知翻译服务"
end

function Providers.isProviderEnabled(id)
    return Providers.getProviderById(id) ~= nil
end

return Providers
