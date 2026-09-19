local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local TranslationUI = {}

function TranslationUI.showError(message)
    UIManager:show(Notification:new{
        text = message,
        timeout = 5,
    })
end

function TranslationUI.showInfo(message, timeout)
    UIManager:show(Notification:new{
        text = message,
        timeout = timeout or 3,
    })
end

return TranslationUI
