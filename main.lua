--[[
    KOReader Plugin: Komga Sync & Download Bridge
    Modularized Entry Point
--]]

-- Lua 5.3 compatibility fallback for unpack
if not unpack then
    unpack = table.unpack
end

-- Robust requirement of KOReader modules
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")

-- Internal modules live under the uniquely-named "komix/" namespace so they can
-- never collide with those of other Komga plugins installed alongside.
local KomixAPI = require("komix/core/api")
local KomixCache = require("komix/core/cache")
local KomixSync = require("komix/core/sync")
local KomixSubscriptions = require("komix/core/subscriptions")
local KomixMenu = require("komix/ui/menus/menu")
local i18n = require("komix/core/i18n")

local Komix = WidgetContainer:extend{
    name = "komix",
    is_active = false,
    settings = nil,
    api = nil,
    cache = nil,
    sync = nil,
    menu = nil,
    last_synced_page = 0
}

-- Default local settings template
local DEFAULT_SETTINGS = {
    server_url = "http://192.168.1.100:8080",
    api_key = "",
    use_komga_sync = true,
    cache_expiry_policy = "smart", 
    cache_expiry_mins = 60,
    cache_covers = false,
    never_update_covers = false,
    view_mode = "list",
    list_rows = 5,
    grid_columns = 3,
    grid_rows = 3,
    library_metadata_cache = {},
    matched_books_cache = {},
    download_dir = "",
    download_to_subfolder = true,
    auto_rtl_direction = false,
    auto_download_next = 0,
    skip_end_of_book_prompt = false,
    -- Fused from the komga plugin:
    filename_template = "{number}",
    -- Home screen entries hidden by the user (key -> true); absent = visible.
    hidden_home_items = {},
    -- Metadata options:
    metadata_author_mode = "artist",
    metadata_summary_from_series = true,
    -- Category subscriptions:
    subscriptions = {},
    auto_sync_subscriptions = true,
    -- Ask before deleting local files for comics that left a subscription.
    subscriptions_check_removed = true,
    -- What each subscription held at the end of the last sync (kind:id -> books).
    subscription_known = {}
}

function Komix:init()
    logger.info("Komix: Initializing...")
    self.i18n = i18n
    self:loadSettings()
    self:initAPI()
    
    -- Initialize sub-modules
    self.cache = KomixCache:new(self)
    self.sync = KomixSync:new(self)
    self.subscriptions = KomixSubscriptions:new(self)
    self.menu = KomixMenu:new(self)
    
    self.ui.menu:registerToMainMenu(self)
    self:registerEvents()
    logger.info("Komix: Initialized successfully")
end

function Komix:loadSettings()
    local settings_path = DataStorage:getSettingsDir() .. "/komix.lua"
    logger.dbg("Komix: Loading settings from", settings_path)
    
    -- Safety check for LuaSettings
    if not LuaSettings then
        self:notify(self.i18n._("Incompatible system: LuaSettings not found."), "error")
        self.settings = DEFAULT_SETTINGS
        return
    end

    self.settings_file = LuaSettings:open(settings_path)
    self.settings = {}
    for k, v in pairs(DEFAULT_SETTINGS) do
        local saved = self.settings_file:readSetting(k)
        if saved ~= nil then
            self.settings[k] = saved
        else
            self.settings[k] = v
        end
    end
    logger.info("Komix: Settings loaded")
end

function Komix:saveSettings()
    if not self.settings_file then return end
    for k, v in pairs(self.settings) do
        self.settings_file:saveSetting(k, v)
    end
    self.settings_file:flush()
end

function Komix:initAPI()
    if self.settings.server_url and self.settings.server_url ~= "" and self.settings.api_key and self.settings.api_key ~= "" then
        logger.info("Komix: Initializing API with URL:", self.settings.server_url)
        self.api = KomixAPI:new(
            self.settings.server_url,
            self.settings.api_key,
            {
                block_timeout = self.settings.download_block_timeout,
                total_timeout = self.settings.download_total_timeout,
            }
        )
    else
        logger.warn("Komix: API not initialized (missing server URL or API key)")
        self.api = nil
    end
end

function Komix:registerEvents()
    Dispatcher:registerAction("komix_sync_now", {
        category = "none",
        title = self.i18n._("Manual Komga Sync"),
        event = "KomixSyncNow",
        general = true,
    })
    Dispatcher:registerAction("komix_browse", {
        category = "none",
        title = self.i18n._("Browse Komga library"),
        event = "KomixBrowse",
        general = true,
    })
    Dispatcher:registerAction("komix_sync_subscriptions", {
        category = "none",
        title = self.i18n._("Sync subscription categories"),
        event = "KomixSyncSubscriptions",
        general = true,
    })
end

function Komix:onKomixSyncNow()
    self.sync:matchCurrentBook()
end

function Komix:onKomixBrowse()
    self.menu:showBrowser()
end

function Komix:onKomixSyncSubscriptions()
    self.subscriptions:syncAll()
end

-- Automatic subscription sync when the network becomes available again.
function Komix:onNetworkConnected()
    if self.subscriptions then
        self.subscriptions:maybeAutoSync()
    end
end


function Komix:notify(message, type)
    type = type or "info"
    logger.info("[Komix] " .. message)
    UIManager:show(InfoMessage:new{ text = "[komix] " .. message, timeout = 3 })
end

function Komix:getDownloadDir()
    logger.info("Komix: getDownloadDir called")
    if self.settings.download_dir and self.settings.download_dir ~= "" then
        logger.info("Komix: using custom download_dir:", self.settings.download_dir)
        return self.settings.download_dir
    end
    local path = G_reader_settings and G_reader_settings:readSetting("home_dir")
    
    if path and path ~= "" then
        logger.info("Komix: using home_dir as download_dir:", path)
        return path
    end

    -- Silent: this is also called while merely browsing (to mark already
    -- downloaded books), where a popup would be noise. The user-facing warning
    -- is raised by downloadBook when a download is actually attempted.
    logger.dbg("Komix: no download directory configured")
    return nil
end

-- Lifecycle hooks
function Komix:onReaderReady()
    local ui = self.ui
    
    if self.ui.status and not self.ui.status.orig_onEndOfBook then
        self.ui.status.orig_onEndOfBook = self.ui.status.onEndOfBook
        self.ui.status.onEndOfBook = function(this_module, ...)
            if self.is_active and self.ui then
                local args = {...}
                local show_native = function()
                    if this_module.orig_onEndOfBook then
                        this_module.orig_onEndOfBook(this_module, unpack(args))
                    end
                end
                
                if self.sync:promptNextChapter(self.ui, show_native) then
                    return true
                end
            end
            if this_module.orig_onEndOfBook then
                return this_module.orig_onEndOfBook(this_module, ...)
            end
        end
    end
    local document = ui and ui.document
    local filepath = document and document.file
    logger.info("Komix: onReaderReady triggered for", tostring(filepath))
    self.is_active = true
    self.last_synced_page = ui and ui.view and ui.view.state and ui.view.state.page or 1
    
    if self.settings.auto_rtl_direction then
        local book_id = self.sync:getOrMatchBook(filepath)
        if book_id then
            if ui.view and not ui.view.inverse_reading_order then
                ui.view:onToggleReadingOrder(true)
                if ui.doc_settings then
                    ui.doc_settings:saveSetting("inverse_reading_order", true)
                end
                logger.info("Komix: Automatically switched reading order to RTL")
            end
        end
    end

    if self.settings.auto_download_next and self.settings.auto_download_next > 0 then
        self.sync:preDownloadNextBook(filepath)
    end
    
    if self.ui.kosync and not self.orig_kosync_getProgress then
        self.orig_kosync_getProgress = self.ui.kosync.getProgress
        
        self.ui.kosync.getProgress = function(kosync_instance, ensure_networking, interactive)
            logger.info("Komix: Intercepted KOSync:getProgress (ensure_networking=" .. tostring(ensure_networking) .. ")")
            
            local current_filepath = self.ui.document and self.ui.document.file
            local book_id = current_filepath and self.sync:getOrMatchBook(current_filepath)
            
            local NetworkMgr = require("ui/network/manager")
            if NetworkMgr:isOnline() and book_id then
                local success = self.sync:pullProgress(self.ui, interactive, false)
                if success then
                    logger.info("Komix: Intercepted KOSync and pulled progress from Komga")
                    return
                end
            end
            
            -- Fallback to native KOSync when offline, not matched, or pull failed.
            -- This allows native KOSync to handle queueing and prompting, and once online,
            -- it will trigger getProgress again, which we will intercept while online.
            logger.info("Komix: Falling back to native KOSync:getProgress")
            return self.orig_kosync_getProgress(kosync_instance, ensure_networking, interactive)
        end
    end

    if self.ui.kosync and not self.orig_kosync_updateProgress then
        self.orig_kosync_updateProgress = self.ui.kosync.updateProgress
        
        self.ui.kosync.updateProgress = function(kosync_instance, ensure_networking, interactive, on_suspend)
            logger.info("Komix: Intercepted KOSync:updateProgress (ensure_networking=" .. tostring(ensure_networking) .. ")")
            local current_filepath = self.ui.document and self.ui.document.file
            if current_filepath then
                local book_id = self.sync:getOrMatchBook(current_filepath)
                if book_id then
                    -- Pass ensure_networking = false to avoid duplicate willRerunWhenOnline prompts/queues.
                    -- The chained native KOSync will trigger prompts if needed and rerun when online, re-triggering us.
                    self.sync:pushProgressForDocument(self.ui, not interactive, false)
                end
            end
            
            -- Fallback to native KOSync
            logger.info("Komix: Falling back to native KOSync:updateProgress")
            return self.orig_kosync_updateProgress(kosync_instance, ensure_networking, interactive, on_suspend)
        end
    end
end

function Komix:addToMainMenu(menu_items)
    menu_items.komix_plugin = {
        text = "komix",
        sorting_hint = "search",
        search = true,
        keep_menu_open = true,
        sub_item_table_func = function() return self.menu:createSettingsMenu() end
    }
end

return Komix
