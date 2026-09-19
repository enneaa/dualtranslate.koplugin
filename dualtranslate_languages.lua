local languages = {
    { code = "af", name = "Afrikaans" },
    { code = "ar", name = "Arabic" },
    { code = "be", name = "Belarusian" },
    { code = "bg", name = "Bulgarian" },
    { code = "bn", name = "Bengali" },
    { code = "ca", name = "Catalan" },
    { code = "cs", name = "Czech" },
    { code = "cy", name = "Welsh" },
    { code = "da", name = "Danish" },
    { code = "de", name = "German" },
    { code = "el", name = "Greek" },
    { code = "en", name = "English" },
    { code = "eo", name = "Esperanto" },
    { code = "es", name = "Spanish" },
    { code = "et", name = "Estonian" },
    { code = "fa", name = "Persian" },
    { code = "fi", name = "Finnish" },
    { code = "fr", name = "French" },
    { code = "ga", name = "Irish" },
    { code = "gl", name = "Galician" },
    { code = "gu", name = "Gujarati" },
    { code = "hi", name = "Hindi" },
    { code = "hr", name = "Croatian" },
    { code = "hu", name = "Hungarian" },
    { code = "id", name = "Indonesian" },
    { code = "is", name = "Icelandic" },
    { code = "it", name = "Italian" },
    { code = "ja", name = "Japanese" },
    { code = "ka", name = "Georgian" },
    { code = "kn", name = "Kannada" },
    { code = "ko", name = "Korean" },
    { code = "lt", name = "Lithuanian" },
    { code = "lv", name = "Latvian" },
    { code = "mk", name = "Macedonian" },
    { code = "mr", name = "Marathi" },
    { code = "ms", name = "Malay" },
    { code = "mt", name = "Maltese" },
    { code = "nl", name = "Dutch" },
    { code = "no", name = "Norwegian" },
    { code = "pl", name = "Polish" },
    { code = "pt", name = "Portuguese" },
    { code = "ro", name = "Romanian" },
    { code = "ru", name = "Russian" },
    { code = "sk", name = "Slovak" },
    { code = "sl", name = "Slovenian" },
    { code = "sq", name = "Albanian" },
    { code = "sv", name = "Swedish" },
    { code = "sw", name = "Swahili" },
    { code = "ta", name = "Tamil" },
    { code = "te", name = "Telugu" },
    { code = "th", name = "Thai" },
    { code = "tl", name = "Tagalog" },
    { code = "tr", name = "Turkish" },
    { code = "uk", name = "Ukrainian" },
    { code = "ur", name = "Urdu" },
    { code = "vi", name = "Vietnamese" },
    { code = "zh", name = "Chinese" },
    { code = "zh-Hans", name = "简体中文" },
    { code = "zh-Hant", name = "繁體中文" },
}

local LanguageUtils = {}

LanguageUtils.list = languages

local by_code = {}
for _, lang in ipairs(languages) do
    by_code[lang.code] = lang.name
end

function LanguageUtils.getNameByCode(code)
    return by_code[code] or code
end

return LanguageUtils
