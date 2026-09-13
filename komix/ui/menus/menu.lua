--[[
    Komga UI Menu Generator
    Builds KOReader standard menu trees for libraries and settings.
--]]

local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local logger = require("logger")

local KomixMenu = {}

function KomixMenu:new(plugin)
    local o = { plugin = plugin }
    return setmetatable(o, { __index = self })
end

function KomixMenu:showBrowser()
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        if not self.plugin.settings.server_url or self.plugin.settings.server_url == "" or
           not self.plugin.settings.api_key or self.plugin.settings.api_key == "" then
            self:promptSetup(function()
                local KomixBrowser = require("komix/ui/browser")
                local browser = KomixBrowser:new{ plugin = self.plugin }
                UIManager:show(browser)
            end)
        else
            local KomixBrowser = require("komix/ui/browser")
            local browser = KomixBrowser:new{ plugin = self.plugin }
            UIManager:show(browser)
        end
    end)
end


-- Plugin settings sub-menu
function KomixMenu:createSettingsMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local submenu = {}
    
    table.insert(submenu, {
        text = _("Server Setup"),
        keep_menu_open = true,
        sub_item_table_func = function()
            return {
                {
                    text = _("Server URL"),
                    keep_menu_open = true,
                    callback = function() self:promptInput(_("Server URL"), "server_url") end
                },
                {
                    text = _("API Key"),
                    keep_menu_open = true,
                    callback = function() self:promptInput(_("API Key"), "api_key") end
                },
                {
                    text = _("Auto-Generate API Key"),
                    keep_menu_open = true,
                    callback = function() self:promptAutoGenerate() end
                }
            }
        end
    })

    table.insert(submenu, {
        text = _("Options"),
        keep_menu_open = true,
        sub_item_table_func = function()
            return {
                {
                    text = _("Use Komga server progress when available"),
                    checked_func = function() return self.plugin.settings.use_komga_sync end,
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.settings.use_komga_sync = not self.plugin.settings.use_komga_sync
                        self.plugin:saveSettings()
                    end
                },
                {
                    text = _("Auto RTL for Komga books"),
                    checked_func = function() return self.plugin.settings.auto_rtl_direction end,
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.settings.auto_rtl_direction = not self.plugin.settings.auto_rtl_direction
                        self.plugin:saveSettings()
                    end
                },
                {
                    text_func = function()
                        local count = self.plugin.settings.auto_download_next or 0
                        if count == 0 then
                            return _("Pre-download next chapters: Disabled")
                        elseif count == 1 then
                            return _("Pre-download next chapters: 1 chapter")
                        else
                            return T(_("Pre-download next chapters: %1 chapters"), count)
                        end
                    end,
                    keep_menu_open = true,
                    callback = function()
                        self:promptInput(_("Pre-download next chapters (0 to disable)"), "auto_download_next", true)
                    end
                },
                {
                    text = _("Skip end-of-book prompt (directly open next book)"),
                    checked_func = function() return self.plugin.settings.skip_end_of_book_prompt end,
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.settings.skip_end_of_book_prompt = not self.plugin.settings.skip_end_of_book_prompt
                        self.plugin:saveSettings()
                    end
                },
                {
                    text_func = function()
                        local dir = self.plugin.settings.download_dir
                        if not dir or dir == "" then
                            dir = (G_reader_settings and G_reader_settings:readSetting("home_dir")) or ""
                        end
                        return T(_("Download folder: %1"), dir)
                    end,
                    keep_menu_open = true,
                    callback = function() self:pickDownloadDir() end
                },
                {
                    text = _("Download into Series Subfolders"),
                    checked_func = function() return self.plugin.settings.download_to_subfolder end,
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.settings.download_to_subfolder = not self.plugin.settings.download_to_subfolder
                        self.plugin:saveSettings()
                    end
                },
                {
                    text_func = function()
                        return T(_("Filename template: %1"), self.plugin.settings.filename_template or "{number}")
                    end,
                    keep_menu_open = true,
                    callback = function() self:editFilenameTemplate() end
                },
                {
                    text = _("Download timeouts"),
                    keep_menu_open = true,
                    callback = function() self:editDownloadTimeouts() end
                },
                {
                    text = _("Metadata"),
                    keep_menu_open = true,
                    sub_item_table_func = function()
                        local function author_mode_item(mode, label)
                            return {
                                text = label,
                                checked_func = function()
                                    return (self.plugin.settings.metadata_author_mode or "artist") == mode
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self.plugin.settings.metadata_author_mode = mode
                                    self.plugin:saveSettings()
                                    if touchmenu_instance and touchmenu_instance.updateItems then
                                        touchmenu_instance:updateItems()
                                    end
                                end,
                            }
                        end
                        return {
                            {
                                text = _("Authors"),
                                keep_menu_open = true,
                                sub_item_table = {
                                    author_mode_item("artist", _("Artist only")),
                                    author_mode_item("writer", _("Writer only")),
                                    author_mode_item("both", _("Writer and artist")),
                                    author_mode_item("none", _("None")),
                                },
                            },
                            {
                                text = _("Use series description when a chapter has none"),
                                checked_func = function() return self.plugin.settings.metadata_summary_from_series end,
                                keep_menu_open = true,
                                callback = function()
                                    self.plugin.settings.metadata_summary_from_series =
                                        not self.plugin.settings.metadata_summary_from_series
                                    self.plugin:saveSettings()
                                end,
                            },
                        }
                    end,
                },
                {
                    text = _("Layout Options"),
                    keep_menu_open = true,
                    sub_item_table_func = function()
                        return {
                            {
                                text_func = function()
                                    return self.plugin.settings.view_mode == "grid" and _("Default View Mode: Grid") or _("Default View Mode: List")
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self.plugin.settings.view_mode = self.plugin.settings.view_mode == "grid" and "list" or "grid"
                                    self.plugin:saveSettings()
                                    if touchmenu_instance and touchmenu_instance.updateItems then
                                        touchmenu_instance:updateItems()
                                    end
                                end
                            },
                            {
                                text_func = function() return T(_("List Mode Rows (%1)"), self.plugin.settings.list_rows or 5) end,
                                keep_menu_open = true,
                                callback = function() self:promptInput(_("List Rows"), "list_rows", true) end
                            },
                            {
                                text_func = function() return T(_("Grid Mode Columns (%1)"), self.plugin.settings.grid_columns or 3) end,
                                keep_menu_open = true,
                                callback = function() self:promptInput(_("Grid Columns"), "grid_columns", true) end
                            },
                            {
                                text_func = function() return T(_("Grid Mode Rows (%1)"), self.plugin.settings.grid_rows or 3) end,
                                keep_menu_open = true,
                                callback = function() self:promptInput(_("Grid Rows"), "grid_rows", true) end
                            }
                        }
                    end
                },
                {
                    text = _("Never update cached covers"),
                    checked_func = function() return self.plugin.settings.never_update_covers end,
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.settings.never_update_covers = not self.plugin.settings.never_update_covers
                        self.plugin:saveSettings()
                    end
                },
                {
                    text = _("Clean Cache"),
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.cache:clear()
                        self.plugin:notify(_("Cache cleared"), "info")
                    end
                }
            }
        end
    })

    table.insert(submenu, {
        text = _("Home screen"),
        keep_menu_open = true,
        sub_item_table_func = function()
            local KomixBrowser = require("komix/ui/browser")
            local items = {}
            -- index `_i` (not `_`, which shadows the gettext function)
            for _i, entry in ipairs(KomixBrowser.HOME_ITEMS) do
                table.insert(items, {
                    text = _(entry.label),
                    checked_func = function()
                        return not (self.plugin.settings.hidden_home_items or {})[entry.key]
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local hidden = self.plugin.settings.hidden_home_items or {}
                        if hidden[entry.key] then
                            hidden[entry.key] = nil   -- show
                        else
                            hidden[entry.key] = true  -- hide
                        end
                        self.plugin.settings.hidden_home_items = hidden
                        self.plugin:saveSettings()
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
            end
            return items
        end,
    })

    table.insert(submenu, {
        text = _("Subscriptions"),
        keep_menu_open = true,
        sub_item_table_func = function()
            local items = {
                {
                    text = _("Sync subscriptions now"),
                    keep_menu_open = true,
                    callback = function() self.plugin.subscriptions:syncAll() end,
                },
                {
                    text = _("Auto-sync when online"),
                    checked_func = function() return self.plugin.settings.auto_sync_subscriptions end,
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.settings.auto_sync_subscriptions = not self.plugin.settings.auto_sync_subscriptions
                        self.plugin:saveSettings()
                    end,
                },
                {
                    -- Off = no check at all, so nothing is ever deleted locally.
                    text = _("Offer to delete comics removed from subscriptions"),
                    checked_func = function() return self.plugin.settings.subscriptions_check_removed end,
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.settings.subscriptions_check_removed =
                            not self.plugin.settings.subscriptions_check_removed
                        self.plugin:saveSettings()
                    end,
                },
                {
                    text = _("Add read list"),
                    keep_menu_open = true,
                    callback = function() self:pickSubscription("readlist") end,
                },
                {
                    text = _("Add collection"),
                    keep_menu_open = true,
                    callback = function() self:pickSubscription("collection") end,
                },
            }
            -- index `_i` (not `_`, which shadows the gettext function)
            for _i, s in ipairs(self.plugin.subscriptions:list()) do
                table.insert(items, {
                    text = T(_("Remove %1"), s.name or s.id),
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self.plugin.subscriptions:remove(s.kind, s.id)
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
            end
            return items
        end,
    })

    if self.plugin.ui and self.plugin.ui.document then
        local filepath = self.plugin.ui.document.file
        local is_linked = false
        if filepath then
            local book_id = self.plugin.sync:getOrMatchBook(filepath)
            if book_id then
                is_linked = true
            end
        end

        if not is_linked then
            table.insert(submenu, {
                text = _("Manual Match Current Book"),
                callback = function()
                    self.plugin.sync:matchCurrentBook()
                end
            })
        else
            table.insert(submenu, {
                text = _("Unlink Current Book"),
                callback = function()
                    self.plugin.sync:unlinkCurrentBook()
                end
            })
        end
    end

    table.insert(submenu, {
        text = _("Komga Browser"),
        callback = function(touchmenu_instance)
            if touchmenu_instance and touchmenu_instance.onCloseAllMenus then
                touchmenu_instance:onCloseAllMenus()
            end
            self:showBrowser()
        end
    })

    -- Recall the download window after minimizing it (or when it scrolled away).
    local function has_active_download()
        return self.plugin.sync ~= nil and self.plugin.sync:hasActiveDownload()
    end
    table.insert(submenu, {
        text_func = function()
            return has_active_download() and _("Active downloads") or _("Active downloads: none")
        end,
        enabled_func = has_active_download,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            if touchmenu_instance and touchmenu_instance.onCloseAllMenus then
                touchmenu_instance:onCloseAllMenus()
            end
            self.plugin.sync:showActiveDownloads()
        end
    })

    return submenu
end


-- Download folder picker (PathChooser, from the komga plugin)
function KomixMenu:pickDownloadDir()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local PathChooser = require("ui/widget/pathchooser")
    local current = self.plugin.settings.download_dir
    if not current or current == "" then
        current = (G_reader_settings and G_reader_settings:readSetting("home_dir")) or nil
    end
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        path = current,
        onConfirm = function(path)
            self.plugin.settings.download_dir = path
            self.plugin:saveSettings()
            self.plugin:notify(T(_("Download folder: %1"), path), "info")
        end,
    })
end

-- Filename template editor (from the komga plugin)
function KomixMenu:editFilenameTemplate()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local Naming = require("komix/core/naming")
    local dialog
    dialog = InputDialog:new{
        title = _("Filename template"),
        input = self.plugin.settings.filename_template or Naming.DEFAULT_TEMPLATE,
        description = _("Placeholders: {series}, {title}, {number}.\nExample: {series}-{title}-{number}"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                local template = dialog:getInputText():gsub("^%s*(.-)%s*$", "%1")
                local ok, kind, detail = Naming.validate(template,
                    { flat = not self.plugin.settings.download_to_subfolder })
                if not ok then
                    local msg
                    if kind == "unknown" then
                        msg = T(_("Unknown placeholder: {%1}"), detail)
                    elseif kind == "missing_number" then
                        msg = _("The template must contain {number}.")
                    else
                        msg = _("Without per-series subfolders the template must contain {series}.")
                    end
                    self.plugin:notify(msg, "error")
                    return
                end
                self.plugin.settings.filename_template = template
                self.plugin:saveSettings()
                self.plugin:notify(_("Saved"), "info")
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Download timeouts editor (from the komga plugin)
function KomixMenu:editDownloadTimeouts()
    local _ = self.plugin.i18n._
    local function current(key)
        local v = self.plugin.settings[key]
        return v and tostring(v) or ""
    end
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Download timeouts"),
        fields = {
            { description = _("Stall timeout (seconds)"), text = current("download_block_timeout"), input_type = "number" },
            { description = _("Total timeout (seconds)"), text = current("download_total_timeout"), input_type = "number" },
        },
        description = _("A download is aborted when no data arrives for the stall timeout, or when it exceeds the total timeout.\nLeave empty for the defaults (15 s stall, no total limit)."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                local f = dialog:getFields()
                local function positive(v)
                    local n = tonumber(v)
                    if n and n > 0 then return math.floor(n) end
                end
                self.plugin.settings.download_block_timeout = positive(f[1])
                self.plugin.settings.download_total_timeout = positive(f[2])
                self.plugin:saveSettings()
                self.plugin:initAPI()
                self.plugin:notify(_("Saved"), "info")
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Pick a read list / collection to subscribe to.
function KomixMenu:pickSubscription(kind)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local api = self.plugin.api
    if not api then
        self.plugin:notify(_("Configure the Komga server first"), "error")
        return
    end
    local res
    if kind == "readlist" then
        res = api:get_readlists(0, 200)
    else
        res = api:get_collections(0, 200)
    end
    local entries = (type(res) == "table" and res.content) or {}
    if #entries == 0 then
        self.plugin:notify(_("Nothing found"), "info")
        return
    end

    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen
    local item_table = {}
    -- index `_i` (not `_`, which shadows the gettext function)
    for _i, e in ipairs(entries) do
        table.insert(item_table, { text = e.name or e.id, entry = e })
    end
    local menu
    menu = Menu:new{
        title = kind == "readlist" and _("Add read list") or _("Add collection"),
        item_table = item_table,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_self, item)
            if not item.entry then return end
            local name = item.entry.name or item.entry.id
            if self.plugin.subscriptions:add(kind, item.entry.id, name) then
                self.plugin:notify(T(_("Subscribed to %1"), name), "info")
            else
                self.plugin:notify(_("Already subscribed"), "info")
            end
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
end


-- UI prompt helper
function KomixMenu:promptInput(title, setting_key, is_number)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local input
    input = InputDialog:new{
        title = title,
        input = tostring(self.plugin.settings[setting_key] or ""),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local value = input:getInputValue()
                        if is_number then
                            value = tonumber(value)
                            if not value then
                                self.plugin:notify(_("Invalid number"), "error")
                                return
                            end
                        end
                        self.plugin.settings[setting_key] = value
                        self.plugin:saveSettings()
                        if setting_key == "server_url" or setting_key == "api_key" then
                            self.plugin:initAPI()
                        end
                        self.plugin:notify(T(_("Updated %1"), title), "info")
                        UIManager:close(input)
                    end,
                },
            },
        },
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

function KomixMenu:promptSetup(on_success_callback)
    local _ = self.plugin.i18n._
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = _("Komga is not configured. Please set up connection."),
        buttons = {
            {
                {
                    text = _("Manual Setup"),
                    callback = function()
                        UIManager:close(dialog)
                        self:promptManualSetup(on_success_callback)
                    end
                },
                {
                    text = _("Auto-Generate API Key"),
                    callback = function()
                        UIManager:close(dialog)
                        self:promptAutoGenerate(on_success_callback)
                    end
                }
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end
                }
            }
        }
    }
    UIManager:show(dialog)
end

function KomixMenu:promptManualSetup(on_success_callback)
    local _ = self.plugin.i18n._
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Manual Server Setup"),
        fields = {
            {
                text = self.plugin.settings.server_url or "http://",
                hint = _("Server URL"),
            },
            {
                text = self.plugin.settings.api_key or "",
                hint = _("API Key"),
            }
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local url, api_key = unpack(dialog:getFields())
                        local util = require("util")
                        url = util.trim(url)
                        api_key = util.trim(api_key)
                        
                        if url == "" then
                            self.plugin:notify(_("Server URL cannot be empty"), "error")
                            return
                        end
                        if api_key == "" then
                            self.plugin:notify(_("API Key cannot be empty"), "error")
                            return
                        end
                        
                        self.plugin.settings.server_url = url
                        self.plugin.settings.api_key = api_key
                        self.plugin:saveSettings()
                        self.plugin:initAPI()
                        
                        UIManager:close(dialog)
                        self.plugin:notify(_("Server connection saved"), "info")
                        if on_success_callback then
                            on_success_callback()
                        end
                    end
                }
            }
        }
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KomixMenu:promptAutoGenerate(on_success_callback)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Auto-Generate API Key"),
        fields = {
            {
                text = self.plugin.settings.server_url or "http://",
                hint = _("Server URL"),
            },
            {
                hint = _("Username/Email"),
            },
            {
                hint = _("Password"),
                text_type = "password",
            }
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end
                },
                {
                    text = _("Generate"),
                    is_enter_default = true,
                    callback = function()
                        local url, username, password = unpack(dialog:getFields())
                        local util = require("util")
                        url = util.trim(url)
                        username = util.trim(username)
                        
                        if url == "" then
                            self.plugin:notify(_("Server URL cannot be empty"), "error")
                            return
                        end
                        if username == "" or password == "" then
                            self.plugin:notify(_("Username and Password are required"), "error")
                            return
                        end
                        
                        UIManager:close(dialog)
                        
                        local NetworkMgr = require("ui/network/manager")
                        NetworkMgr:runWhenOnline(function()
                            UIManager:show(require("ui/widget/infomessage"):new{
                                text = _("Generating API Key. Please wait..."),
                                timeout = 2
                            })
                            
                            UIManager:scheduleIn(0.5, function()
                                local KomixAPI = require("komix/core/api")
                                local api = KomixAPI:new(url, "")
                                api:set_basic_auth(username, password)
                                
                                local Device = require("device")
                                local key_comment = "KOReader komix (" .. (Device.model or "Unknown Device") .. ")"
                                
                                local result, err = api:generate_api_key(key_comment)
                                if result and type(result) == "table" and result.key then
                                    self.plugin.settings.server_url = url
                                    self.plugin.settings.api_key = result.key
                                    self.plugin:saveSettings()
                                    self.plugin:initAPI()
                                    self.plugin:notify(_("API Key generated successfully!"), "info")
                                    if on_success_callback then
                                        on_success_callback()
                                    end
                                else
                                    self.plugin:notify(T(_("Generation failed: %1"), err or "Unknown error"), "error")
                                end
                            end)
                        end)
                    end
                }
            }
        }
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return KomixMenu
