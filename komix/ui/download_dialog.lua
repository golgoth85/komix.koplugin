-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Part of komix (see LICENSE).
--[[
    Download progress dialog with Pause/Resume, Cancel and Hide.

    Pause/Resume and Cancel are delegated to the sync module, which owns the
    download subprocess. Hide closes the dialog only: the download keeps going
    in the background and can be recalled from komix -> Active downloads.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local _ = require("gettext")

local DownloadDialog = InputContainer:extend{
    title = nil,
    subtitle = nil,
    status = nil,
    percentage = nil,      -- 0..1, nil hides the bar (unknown total size)
    paused = false,
    on_pause = nil,        -- toggles pause/resume
    on_cancel = nil,
    on_minimize = nil,     -- hides the dialog, keeps the download running
}

function DownloadDialog:init()
    self.align = "center"
    self.vertical_align = "center"
    self.dimen = Screen:getSize()

    local bar_width = Screen:getWidth() - Screen:scaleBySize(80)
    local group = VerticalGroup:new{ align = "center" }

    if self.title then
        table.insert(group, TextWidget:new{
            text = self.title,
            face = Font:getFace("ffont"),
            bold = true,
            max_width = bar_width,
        })
    end
    if self.subtitle then
        table.insert(group, TextWidget:new{
            text = self.subtitle,
            face = Font:getFace("smallffont"),
            max_width = bar_width,
        })
    end

    table.insert(group, VerticalSpan:new{ width = Size.span.vertical_large })

    if self.percentage then
        self.progress_bar = ProgressWidget:new{
            width = bar_width,
            height = Screen:scaleBySize(18),
            percentage = self.percentage,
            fillcolor = Blitbuffer.COLOR_BLACK,
            padding = Size.padding.large,
            margin = Size.margin.tiny,
        }
        table.insert(group, self.progress_bar)
    end

    self.status_widget = TextWidget:new{
        text = self.status or "",
        face = Font:getFace("smallinfofont"),
        max_width = bar_width,
    }
    table.insert(group, self.status_widget)

    table.insert(group, VerticalSpan:new{ width = Size.span.vertical_large })
    table.insert(group, self:buildButtonRow())

    self[1] = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        group,
    }
end

function DownloadDialog:buildButtonRow()
    self.pause_button = Button:new{
        text_func = function() return self.paused and _("Resume") or _("Pause") end,
        callback = function()
            if self.on_pause then self.on_pause() end
        end,
        show_parent = self,
    }
    local cancel_button = Button:new{
        text = _("Cancel"),
        callback = function()
            if self.on_cancel then self.on_cancel() end
        end,
        show_parent = self,
    }
    local hide_button = Button:new{
        text = _("Hide"),
        callback = function()
            if self.on_minimize then self.on_minimize() end
        end,
        show_parent = self,
    }

    return HorizontalGroup:new{
        align = "center",
        self.pause_button,
        HorizontalSpan:new{ width = Size.span.horizontal_default },
        cancel_button,
        HorizontalSpan:new{ width = Size.span.horizontal_default },
        hide_button,
    }
end

-- Human-readable byte count (1.2 MB); used for the progress line.
local function formatSize(bytes)
    if not bytes or bytes < 1024 then
        return string.format("%d B", bytes or 0)
    elseif bytes < 1024 * 1024 then
        return string.format("%.0f KB", bytes / 1024)
    else
        return string.format("%.1f MB", bytes / (1024 * 1024))
    end
end

-- Update the progress bar and the status line. `got`/`total` are bytes;
-- `total` may be nil when the server didn't report a file size.
function DownloadDialog:setProgress(got, total)
    local status
    if total and total > 0 then
        local pct = math.min(100, math.floor(got / total * 100))
        status = string.format("%s / %s (%d%%)", formatSize(got), formatSize(total), pct)
        if self.progress_bar then
            self.progress_bar:setPercentage(math.min(1, got / total))
        end
    else
        status = formatSize(got)
    end
    if self.paused then
        status = status .. "  " .. _("(paused)")
    end
    self:setStatus(status)
end

function DownloadDialog:setStatus(text)
    if not self.status_widget or self._status == text then return end
    self._status = text
    self.status_widget:setText(text)
    self:refresh()
end

function DownloadDialog:refresh()
    UIManager:setDirty(self, function() return "fast", self.dimen end)
    UIManager:forceRePaint()
end

-- UIManager:show/close without an explicit refresh mode is a no-op paint-wise
-- (it only updates the window stack), so the dialog would linger on screen.
function DownloadDialog:show()
    UIManager:show(self, "ui")
end

function DownloadDialog:close()
    UIManager:close(self, "ui")
end

return DownloadDialog
