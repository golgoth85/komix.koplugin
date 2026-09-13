-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Part of komix (see LICENSE).
--[[
    "Comics disappeared from your subscriptions" confirmation.

    A ConfirmBox with an added checkbox, the usual KOReader pattern: the main
    choice is Delete / Keep, and ticking the box before answering Keep turns the
    check off for good (the equivalent of the menu option), so the user is not
    asked again on every sync.
--]]

local CheckButton = require("ui/widget/checkbutton")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local RemovalDialog = {}

-- opts.text            message body
-- opts.delete_text     label of the OK button
-- opts.keep_text       label of the Cancel button
-- opts.checkbox_text   label of the "don't ask again" checkbox
-- opts.on_answer(delete, dont_ask_again)
function RemovalDialog:show(opts)
    -- The checkbox takes its width from the box, so the box comes first; the
    -- callbacks only read the checkbox once the user taps a button.
    local check_button
    local dialog = ConfirmBox:new{
        text = opts.text,
        ok_text = opts.delete_text or _("Delete"),
        cancel_text = opts.keep_text or _("Keep"),
        ok_callback = function()
            if opts.on_answer then opts.on_answer(true, check_button.checked) end
        end,
        cancel_callback = function()
            if opts.on_answer then opts.on_answer(false, check_button.checked) end
        end,
    }
    check_button = CheckButton:new{
        text = opts.checkbox_text,
        checked = false,
        parent = dialog,
    }
    dialog:addWidget(check_button)
    UIManager:show(dialog)
end

return RemovalDialog
