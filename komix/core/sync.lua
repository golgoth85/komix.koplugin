--[[
    Komga Sync & Matching Engine
    Coordinates progress updates and book file acquisition.
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Naming = require("komix/core/naming")
local Metadata = require("komix/core/metadata")

local KomixSync = {}

-- Confirmation toast after a successful download, falling back to InfoMessage.
local function notifyDownloaded(plugin, text)
    local ok, Notification = pcall(require, "ui/widget/notification")
    if ok and Notification and Notification.notify and Notification.SOURCE_ALWAYS_SHOW then
        local shown_ok, shown = pcall(function()
            return Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW, true)
        end)
        if shown_ok and shown then return end
    end
    plugin:notify(text, "info")
end

-- POSIX signal numbers (Linux/Android: the platforms KOReader ships on).
local SIGCONT, SIGSTOP = 18, 19

-- Send a signal to the download subprocess and its group. The group matters:
-- runInSubProcess() puts the child in its own group (setpgid(0,0)), so -pid
-- reaches any helper it might spawn.
local function signalSubProcess(pid, sig)
    local ok, ffi = pcall(require, "ffi")
    if not ok then return false end
    pcall(require, "ffi/posix_h")  -- declares kill() for ffi.C
    return pcall(function() return ffi.C.kill(-pid, sig) end)
end

function KomixSync:new(plugin)
    local o = {
        plugin = plugin,
        bg_processes = {},
        bg_collector_scheduled = false,
        queue = {},              -- downloads waiting for the current one to end
        current = nil,           -- { book, paths, pid, paused, dialog, ... }
        cancel_sequence = false, -- set by cancel, consumed by downloadBooksSeq
    }
    return setmetatable(o, { __index = self })
end

-- Helper to get custom_metadata.lua file paths
local function get_custom_metadata_paths(filepath)
    -- Try replacing extension (e.g. .cbz -> .sdr)
    local sdr_dir1 = filepath:gsub("%.%w+$", "") .. ".sdr"
    local path1 = sdr_dir1 .. "/custom_metadata.lua"
    
    -- Try appending .sdr (e.g. .cbz -> .cbz.sdr)
    local sdr_dir2 = filepath .. ".sdr"
    local path2 = sdr_dir2 .. "/custom_metadata.lua"
    
    return path1, path2
end

-- Helper to recursively serialize Lua values to a string
local function serialize_value(v, indent_level)
    indent_level = indent_level or 1
    local indent = string.rep("    ", indent_level)
    if type(v) == "string" then
        return string.format("%q", v)
    elseif type(v) == "number" or type(v) == "boolean" then
        return tostring(v)
    elseif type(v) == "table" then
        local parts = {}
        table.insert(parts, "{\n")
        for k2, v2 in pairs(v) do
            local key_str
            if type(k2) == "string" then
                key_str = string.format("[%q]", k2)
            else
                key_str = string.format("[%s]", tostring(k2))
            end
            local val_str = serialize_value(v2, indent_level + 1)
            if val_str then
                table.insert(parts, string.format("%s    %s = %s,\n", indent, key_str, val_str))
            end
        end
        table.insert(parts, indent .. "}")
        return table.concat(parts)
    else
        return nil
    end
end

-- Helper to load custom_metadata.lua table directly using standard Lua
local function load_custom_metadata(filepath)
    local path1, path2 = get_custom_metadata_paths(filepath)
    for _, path in ipairs({path1, path2}) do
        local f = io.open(path, "r")
        if f then
            f:close()
            logger.info("[Komix Sync] Found custom_metadata.lua file at:", path)
            local func, err = loadfile(path)
            if func then
                local ok, data = pcall(func)
                if ok and type(data) == "table" then
                    logger.info("[Komix Sync] Successfully loaded custom metadata table from:", path)
                    for k, v in pairs(data) do
                        logger.info("[Komix Sync] custom_metadata key:", tostring(k), "value_type:", type(v), "value:", tostring(v))
                    end
                    return data, path
                else
                    logger.warn("[Komix Sync] Failed to run custom metadata file:", tostring(err or data))
                end
            else
                logger.warn("[Komix Sync] Failed to load custom metadata file:", tostring(err))
            end
        end
    end
    return nil
end

-- Helper to save a key-value pair to custom_metadata.lua
local function save_custom_metadata(filepath, key_or_table, value)
    local path1, _ = get_custom_metadata_paths(filepath)
    local data = {}
    local loaded_data, found_path = load_custom_metadata(filepath)
    if loaded_data then
        data = loaded_data
        path1 = found_path or path1
    end
    
    if type(key_or_table) == "table" then
        for k, v in pairs(key_or_table) do
            data[k] = v
        end
    else
        data[key_or_table] = value
    end
    
    local util = pcall(require, "util") and require("util")
    if util and util.makePath then
        local dir = path1:match("(.*)/[^/]+")
        if dir then pcall(util.makePath, dir .. "/") end
    end
    
    local f_write, err = io.open(path1, "w")
    if f_write then
        f_write:write("return {\n")
        for k, v in pairs(data) do
            local val_str = serialize_value(v, 1)
            if val_str then
                f_write:write(string.format("    [%q] = %s,\n", k, val_str))
            end
        end
        f_write:write("}\n")
        f_write:close()
        logger.info("[Komix Sync] Successfully wrote custom_metadata to:", path1)
        return true
    else
        logger.warn("[Komix Sync] Failed to open custom_metadata.lua for writing:", tostring(err))
        return false
    end
end

-- Resolve a description: the book's own summary, else (optionally) the summary
-- of the series that contains it.
local function resolve_description(book, ctx)
    if Metadata.has_own_description(book) then
        return Metadata.description(book)
    end
    if ctx and ctx.summary_from_series and ctx.api and book.seriesId then
        local series = ctx.api:get_series_by_id(book.seriesId)
        return Metadata.description(book, series)
    end
    return Metadata.description(book)
end

-- Helper to save book metadata both to KOReader's docsettings and to custom_metadata.lua
local function save_book_metadata(filepath, book, series_title, ctx)
    if not filepath or not book then return end

    local DocSettings = require("docsettings")
    local custom_doc_settings = DocSettings.openSettingsFile and DocSettings:openSettingsFile(filepath)

    local custom_props = {}
    local doc_props = {}
    if custom_doc_settings then
        custom_props = custom_doc_settings:readSetting("custom_props") or {}
        doc_props = custom_doc_settings:readSetting("doc_props") or {}
    end

    if type(book.metadata) == "table" then
        if type(book.metadata.title) == "string" and book.metadata.title ~= "" then
            custom_props.title = book.metadata.title
            doc_props.title = book.metadata.title
        end
        local description = resolve_description(book, ctx)
        if description then
            custom_props.description = description
            doc_props.description = description
        end
        if book.metadata.number ~= nil then
            custom_props.series_index = tostring(book.metadata.number)
            doc_props.series_index = tostring(book.metadata.number)
        elseif book.metadata.numberSort ~= nil then
            custom_props.series_index = tostring(book.metadata.numberSort)
            doc_props.series_index = tostring(book.metadata.numberSort)
        end
    end

    local authors = Metadata.collect_authors(book, ctx and ctx.author_mode)
    if authors then
        custom_props.authors = authors
        doc_props.authors = authors
    end

    local s_title = series_title or book.seriesTitle
    if s_title and s_title ~= "" then
        custom_props.series = s_title
        doc_props.series = s_title
    end
    
    if custom_doc_settings then
        custom_doc_settings:saveSetting("komga_book_id", book.id)
        if custom_doc_settings.flushCustomMetadata then
            custom_doc_settings:saveSetting("custom_props", custom_props)
            custom_doc_settings:saveSetting("doc_props", doc_props)
            custom_doc_settings:flushCustomMetadata(filepath)
        else
            custom_doc_settings:saveSetting("custom_props", custom_props)
            custom_doc_settings:saveSetting("doc_props", doc_props)
            if custom_doc_settings.flush then custom_doc_settings:flush() end
        end
    end
    
    -- Save directly to custom_metadata.lua for maximum reliability and direct fallback loading
    save_custom_metadata(filepath, {
        komga_book_id = book.id,
        custom_props = custom_props,
        doc_props = doc_props
    })
end

-- Helper to find or cache book matching
function KomixSync:getOrMatchBook(filepath)
    if not self.plugin.api or not filepath then
        return nil, "Plugin not configured."
    end
    
    local cached_id = self.plugin.settings.matched_books_cache[filepath]
    if cached_id then
        return cached_id
    end

    -- Try reading from KOReader's document metadata (.sdr)
    local DocSettings = require("docsettings")
    logger.info("[Komix Sync] getOrMatchBook for filepath:", filepath)
    logger.info("[Komix Sync] DocSettings module loaded. Type:", type(DocSettings))
    logger.info("[Komix Sync] DocSettings.openSettingsFile exists:", type(DocSettings.openSettingsFile) == "function")

    local custom_doc_settings = nil
    if DocSettings.openSettingsFile then
        local ok, res = pcall(DocSettings.openSettingsFile, DocSettings, filepath)
        logger.info("[Komix Sync] pcall openSettingsFile ok:", ok, "result:", tostring(res))
        if ok and res then
            custom_doc_settings = res
        end
    end
    if custom_doc_settings then
        local meta_id = custom_doc_settings:readSetting("komga_book_id") 
            or custom_doc_settings:readSetting("komga_id")
        logger.info("[Komix Sync] custom_doc_settings komga_book_id / komga_id:", tostring(meta_id))
        if meta_id and meta_id ~= "" then
            logger.info("[Komix Sync] Matched via custom_doc_settings:", meta_id)
            self.plugin.settings.matched_books_cache[filepath] = meta_id
            self.plugin:saveSettings()
            return meta_id
        end
    else
        logger.info("[Komix Sync] No custom_doc_settings loaded.")
    end

    -- Fallback: Directly read custom_metadata.lua using standard Lua
    local custom_metadata = load_custom_metadata(filepath)
    if custom_metadata then
        local meta_id = custom_metadata.komga_book_id or custom_metadata.komga_id
        if meta_id and meta_id ~= "" then
            logger.info("[Komix Sync] Matched via custom_metadata.lua table fallback:", meta_id)
            self.plugin.settings.matched_books_cache[filepath] = meta_id
            self.plugin:saveSettings()
            return meta_id
        end
    end

    -- Skip sidecar creation if it doesn't already exist
    local has_sidecar = false
    if DocSettings.hasSidecarFile then
        local ok, res = pcall(DocSettings.hasSidecarFile, DocSettings, filepath)
        logger.info("[Komix Sync] hasSidecarFile ok:", ok, "result:", tostring(res))
        if ok then
            has_sidecar = res
        end
    else
        logger.info("[Komix Sync] DocSettings.hasSidecarFile does not exist.")
    end
    
    local doc_settings = nil
    if has_sidecar or not DocSettings.hasSidecarFile then
        local ok, res = pcall(DocSettings.open, DocSettings, filepath)
        logger.info("[Komix Sync] pcall open ok:", ok, "result:", tostring(res))
        if ok and res then
            doc_settings = res
        end
    end
    if doc_settings then
        local meta_id = doc_settings:readSetting("komga_book_id") 
            or doc_settings:readSetting("komga_id") 
        logger.info("[Komix Sync] doc_settings komga_book_id / komga_id:", tostring(meta_id))
        if meta_id and meta_id ~= "" then
            logger.info("[Komix Sync] Matched via doc_settings:", meta_id)
            self.plugin.settings.matched_books_cache[filepath] = meta_id
            self.plugin:saveSettings()
            return meta_id
        end
    else
        logger.info("[Komix Sync] No doc_settings loaded.")
    end
    
    logger.info("[Komix Sync] getOrMatchBook returning nil (Not linked)")
    return nil, "Not linked"
end

local function get_series_from_metadata(filepath, doc)
    local DocSettings = require("docsettings")
    logger.info("[Komix Sync] get_series_from_metadata for filepath:", filepath)
    logger.info("[Komix Sync] DocSettings.openSettingsFile exists:", type(DocSettings.openSettingsFile) == "function")

    local custom_doc_settings = nil
    if DocSettings.openSettingsFile then
        local ok, res = pcall(DocSettings.openSettingsFile, DocSettings, filepath)
        logger.info("[Komix Sync] get_series_from_metadata pcall openSettingsFile ok:", ok, "result:", tostring(res))
        if ok and res then
            custom_doc_settings = res
        end
    end
    if custom_doc_settings then
        local doc_props = custom_doc_settings:readSetting("doc_props") or {}
        logger.info("[Komix Sync] doc_props series:", tostring(doc_props.series))
        if doc_props.series and doc_props.series ~= "" then
            return doc_props.series
        end
        local custom_props = custom_doc_settings:readSetting("custom_props") or {}
        logger.info("[Komix Sync] custom_props series:", tostring(custom_props.series))
        if custom_props.series and custom_props.series ~= "" then
            return custom_props.series
        end
    else
        logger.info("[Komix Sync] No custom_doc_settings loaded for series retrieval.")
    end

    -- Direct load custom_metadata.lua fallback for series metadata
    local custom_metadata = load_custom_metadata(filepath)
    if custom_metadata then
        if custom_metadata.series and custom_metadata.series ~= "" then
            logger.info("[Komix Sync] Found series in custom_metadata table:", tostring(custom_metadata.series))
            return custom_metadata.series
        end
        local doc_props = custom_metadata.doc_props or {}
        if doc_props.series and doc_props.series ~= "" then
            logger.info("[Komix Sync] Found series in custom_metadata.doc_props table:", tostring(doc_props.series))
            return doc_props.series
        end
        local custom_props = custom_metadata.custom_props or {}
        if custom_props.series and custom_props.series ~= "" then
            logger.info("[Komix Sync] Found series in custom_metadata.custom_props table:", tostring(custom_props.series))
            return custom_props.series
        end
    end

    if doc and doc.getProps then
        local success, props = pcall(doc.getProps, doc)
        logger.info("[Komix Sync] getProps ok:", success)
        if success and props then
            logger.info("[Komix Sync] props.series:", tostring(props.series))
            if props.series and props.series ~= "" then
                return props.series
            end
        end
    end
    logger.info("[Komix Sync] get_series_from_metadata returning nil")
    return nil
end

-- Matches the current open book manual
function KomixSync:matchCurrentBook()
    local doc = self.plugin.ui and self.plugin.ui.document
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    if not doc or not doc.file then
        self.plugin:notify(_("No active book open to match."), "error")
        return
    end

    local filepath = doc.file
    local filename = filepath:match("([^/\\]+)$") or filepath
    local parent_dir = filepath:match("([^/\\]+)[/\\][^/\\]+$") or ""

    local InfoMessage = require("ui/widget/infomessage")
    local search_msg = InfoMessage:new{ text = "[komix] " .. T(_("Searching Komga for: %1"), filename) }
    UIManager:show(search_msg)

    local results, err
    local matched_series_id = nil

    -- a. First search the parent folder as the series
    if parent_dir ~= "" then
        local s_results, s_err = self.plugin.api:search_series(parent_dir)
        if s_results and s_results.content and #s_results.content > 0 then
            local p_lower = parent_dir:lower()
            for _, s in ipairs(s_results.content) do
                local s_name = s.name or ""
                local s_title = (s.metadata and s.metadata.title) or ""
                if s_name:lower() == p_lower or s_title:lower() == p_lower then
                    matched_series_id = s.id
                    break
                end
            end
            if not matched_series_id then
                matched_series_id = s_results.content[1].id
            end
        end
    end

    -- If not look at book metadata for series and search for series
    if not matched_series_id then
        local meta_series = get_series_from_metadata(filepath, doc)
        if meta_series and meta_series ~= "" then
            local s_results, s_err = self.plugin.api:search_series(meta_series)
            if s_results and s_results.content and #s_results.content > 0 then
                local ms_lower = meta_series:lower()
                for _, s in ipairs(s_results.content) do
                    local s_name = s.name or ""
                    local s_title = (s.metadata and s.metadata.title) or ""
                    if s_name:lower() == ms_lower or s_title:lower() == ms_lower then
                        matched_series_id = s.id
                        break
                    end
                end
                if not matched_series_id then
                    matched_series_id = s_results.content[1].id
                end
            end
        end
    end

    -- b. If there is a matched series, search filename in that series using the search API.
    if matched_series_id then
        local s_books, s_err = self.plugin.api:search_books(filename, matched_series_id)
        if s_books and s_books.content and #s_books.content > 0 then
            results = s_books
        end
    end

    -- c. If a / b failed, then we search the filename itself.
    if not results or not results.content or #results.content == 0 then
        results, err = self.plugin.api:search_books(filename)
    end

    if search_msg then
        UIManager:close(search_msg)
    end

    if not results or not results.content or #results.content == 0 then
        self.plugin:notify(_("No matching book found on Komga server"), "error")
        return
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")

    local total_books = #results.content
    local page_size = 10
    local total_pages = math.ceil(total_books / page_size)

    local dialog
    local function showPage(page_num)
        local start_idx = (page_num - 1) * page_size + 1
        local end_idx = math.min(start_idx + page_size - 1, total_books)

        local buttons = {}
        for i = start_idx, end_idx do
            local book = results.content[i]
            local series = book.seriesTitle or book.seriesName or ""
            local title = (book.metadata and book.metadata.title) or book.name or "Untitled"
            local label = ""
            if series ~= "" then
                label = "[" .. series .. "] " .. title
            else
                label = title
            end

            table.insert(buttons, {
                {
                    text = label,
                    callback = function()
                        UIManager:close(dialog)
                        self.plugin.settings.matched_books_cache[filepath] = book.id
                        self.plugin:saveSettings()
                        
                        pcall(save_book_metadata, filepath, book, nil, self:metadataContext())
                        
                        self.plugin:notify(T(_("Matched with: %1"), label), "info")
                    end
                }
            })
        end

        -- Add navigation row if we have multiple pages
        local nav_buttons = {}
        if page_num > 1 then
            table.insert(nav_buttons, {
                text = "<< " .. _("Prev"),
                callback = function()
                    UIManager:close(dialog)
                    showPage(page_num - 1)
                end
            })
        end
        if page_num < total_pages then
            table.insert(nav_buttons, {
                text = _("Next") .. " >>",
                callback = function()
                    UIManager:close(dialog)
                    showPage(page_num + 1)
                end
            })
        end

        if #nav_buttons > 0 then
            table.insert(buttons, nav_buttons)
        end

        -- Add a Cancel button
        table.insert(buttons, {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end
            }
        })

        local title_text = _("Select Matching Komga Book")
        if total_pages > 1 then
            title_text = title_text .. " (" .. page_num .. "/" .. total_pages .. ")"
        end

        dialog = ButtonDialog:new{
            title = title_text,
            buttons = buttons
        }
        UIManager:show(dialog)
    end

    showPage(1)
end

-- Unlinks the current open book from Komga
function KomixSync:unlinkCurrentBook()
    local doc = self.plugin.ui and self.plugin.ui.document
    local _ = self.plugin.i18n._
    if not doc or not doc.file then
        self.plugin:notify(_("No active book open to unlink."), "error")
        return
    end

    local filepath = doc.file
    self.plugin.settings.matched_books_cache[filepath] = nil
    self.plugin:saveSettings()

    pcall(function()
        local DocSettings = require("docsettings")
        local custom_doc_settings = DocSettings.openSettingsFile and DocSettings:openSettingsFile(filepath)
        if custom_doc_settings then
            custom_doc_settings:saveSetting("komga_book_id", nil)
            if custom_doc_settings.flush then custom_doc_settings:flush() end
        end
        save_custom_metadata(filepath, "komga_book_id", nil)
    end)

    self.plugin:notify(_("Unlinked from Komga successfully."), "info")
end

-- Sync progress from Komga
function KomixSync:pullProgress(ui, is_manual, ensure_networking)
    if not self.plugin.settings.use_komga_sync then return false end
    if not self.plugin.api or not ui or not ui.document then return false end
    
    local filepath = ui.document.file
    if not filepath then return false end
    
    local book_id, err = self:getOrMatchBook(filepath)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    
    if not book_id then
        if is_manual then self.plugin:notify(_("Click 'Match' first."), "error") end
        return false
    end
    
    local function do_pull()
        if is_manual then self.plugin:notify(_("Checking server progress..."), "info") end
        
        logger.info("KomixSync: Executing pullProgress for book", book_id)
        
        local progress, p_err = self.plugin.api:get_read_progress(book_id)
        if p_err then 
            logger.err("KomixSync: Failed to pull progress -", tostring(p_err))
            if is_manual then
                self.plugin:notify(T(_("Failed to pull progress - %1"), tostring(p_err)), "error")
            end
            return false -- FAILED to get komga progress
        end
        if type(progress) ~= "table" then
            logger.info("KomixSync: Book found but no progress recorded on server (progress type is", type(progress), ")")
            return true
        end
        
        logger.info("KomixSync: Pulled progress from server:", progress.page or "None")
        
        if not progress.page then 
            logger.info("KomixSync: Book found but progress.page is missing")
            return true -- Server responded successfully but 0% progress
        end
        
        local remote_page = progress.page
        local current_page = ui.view and ui.view.state and ui.view.state.page or 1
        
        if remote_page == current_page then
            if is_manual then self.plugin:notify(_("Already at server progress"), "info") end
            return true
        end
        
        local PluginLoader = require("pluginloader")
        local kosync = PluginLoader:getPluginInstance("kosync")
        
        local strategy
        local text
        if remote_page > current_page then
            strategy = (kosync and kosync.settings.sync_forward) or 1
            text = T(_("Server is ahead (Page %1). Jump?"), remote_page)
        else
            strategy = (kosync and kosync.settings.sync_backward) or 1
            text = T(_("Server is behind (Page %1). Jump?"), remote_page)
        end
        
        if strategy == 1 then -- Prompt
            local ConfirmBox = require("ui/widget/confirmbox")
            local UIManager = require("ui/uimanager")
            local Event = require("ui/event")
            UIManager:show(ConfirmBox:new{
                text = text,
                ok_callback = function()
                    UIManager:broadcastEvent(Event:new("GotoPage", remote_page))
                end,
            })
        elseif strategy == 2 then -- Silently update
            local UIManager = require("ui/uimanager")
            local Event = require("ui/event")
            UIManager:broadcastEvent(Event:new("GotoPage", remote_page))
            if is_manual then self.plugin:notify(T(_("Jumped to Page %1"), remote_page), "info") end
        end
        
        return true
    end

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        if is_manual then
            if NetworkMgr:willRerunWhenOnline(do_pull) then
                logger.info("KomixSync: Network offline, manual pullProgress queued for when online.")
                return false
            end
        else
            logger.info("KomixSync: Network offline, silently skipping background pullProgress.")
            return false
        end
    end

    return do_pull()
end

-- Push progress to Komga
function KomixSync:pushProgress(book_id, current_page, total_pages, is_quiet)
    if not self.plugin.api then return end
    local completed = current_page >= total_pages
    local success, err = self.plugin.api:patch_read_progress(book_id, current_page, completed)
    if success then
        logger.info("[Komix Sync] Saved page " .. current_page)
    else
        logger.err("[Komix Sync] Save failed: " .. tostring(err))
    end
end

function KomixSync:pushProgressForDocument(ui, is_quiet, ensure_networking)
    if not self.plugin.api or not ui or not ui.document then return end
    local filepath = ui.document.file
    if not filepath then return end
    
    local book_id = self:getOrMatchBook(filepath)
    if not book_id then return end
    
    local current_page = ui.view and ui.view.state and ui.view.state.page or 1
    local total_pages = ui.view and ui.view.state and ui.view.state.page_count or (ui.document and ui.document.getPageCount and ui.document:getPageCount()) or current_page
    
    local function do_push()
        logger.info("KomixSync: Executing pushProgress for book", book_id, "page", current_page)
        self:pushProgress(book_id, current_page, total_pages, is_quiet)
    end
    
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        logger.info("KomixSync: Network offline, silently skipping pushProgressForDocument.")
        return
    end
    
    do_push()
end

-- Helper to check if a filename has a valid (non-numeric) file extension
-- Settings context passed to metadata writing (author filter + description fallback).
function KomixSync:metadataContext()
    return {
        api = self.plugin.api,
        author_mode = self.plugin.settings.metadata_author_mode,
        summary_from_series = self.plugin.settings.metadata_summary_from_series,
    }
end

-- Get expected local path for a book (shared by download and "already downloaded"
-- checks, so the two always agree). Filename/dir come from core/naming (template
-- + optional per-series subfolder).
function KomixSync:getBookLocalPath(book, series_title)
    local download_dir = self.plugin:getDownloadDir()
    if not download_dir then return nil, nil end
    return Naming.planPath(download_dir, book, series_title or book.seriesTitle, {
        template = self.plugin.settings.filename_template or Naming.DEFAULT_TEMPLATE,
        flat = not self.plugin.settings.download_to_subfolder,
    })
end

-- Legacy (kokomga) local path: "<dir>[/<series>]/<book.name><ext>". Only used by
-- isBookDownloaded, so library files downloaded by the old plugin are still
-- recognised (and not downloaded again under the new template naming).
function KomixSync:getLegacyLocalPath(book, series_title)
    local download_dir = self.plugin:getDownloadDir()
    if not download_dir then return nil end
    local filename = book.name or book.id
    local ext = Naming.extensionFor(book)
    if filename:sub(-#ext):lower() ~= ext:lower() then
        filename = filename .. ext
    end
    filename = filename:gsub('[/%\\%:%*%?%"%<%>%|]', '_')
    if self.plugin.settings.download_to_subfolder and series_title and series_title ~= "" then
        local clean_series = series_title:gsub('[/%\\%:%*%?%"%<%>%|]', '_')
        download_dir = download_dir .. "/" .. clean_series
    end
    return download_dir .. "/" .. filename
end

function KomixSync:isBookDownloaded(book)
    local lfs = require("libs/libkoreader-lfs")
    local local_path = self:getBookLocalPath(book, book.seriesTitle)
    if local_path and lfs.attributes(local_path, "mode") == "file" then return true end
    local legacy_path = self:getLegacyLocalPath(book, book.seriesTitle)
    if legacy_path and lfs.attributes(legacy_path, "mode") == "file" then return true end
    return false
end

-- Download book
function KomixSync:downloadBook(book, series_title, on_success_callback, on_failure_callback, ctx)
    if not self.plugin.api then return end
    ctx = ctx or {}

    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T

    local local_path, filename = self:getBookLocalPath(book, series_title)
    if not local_path then
        logger.err("KomixSync: No download directory available, bailing out of downloadBook")
        if not ctx.silent then
            self.plugin:notify(_("No download folder set. Choose one in komix → Options."), "error")
        end
        if on_failure_callback then
            on_failure_callback("No download directory")
        end
        return
    end

    -- Check if there is an active background process pre-downloading
    local is_bg_downloading = false
    local bg_proc = nil
    if self.bg_processes and #self.bg_processes > 0 then
        bg_proc = self.bg_processes[1]
        is_bg_downloading = true
    end

    if is_bg_downloading and bg_proc then
        logger.info("KomixSync: Next book is already downloading in background (PID: " .. tostring(bg_proc.pid) .. "). Polling it.")
        self.plugin:notify(T(_("Finishing background download of %1..."), filename), "info")
        
        local lfs = require("libs/libkoreader-lfs")
        local UIManager = require("ui/uimanager")

        local function check_ready()
            if lfs.attributes(local_path, "mode") == "file" then
                logger.info("KomixSync: Background download completed successfully. Opening: " .. local_path)
                if on_success_callback then
                    UIManager:nextTick(function()
                        on_success_callback(local_path)
                    end)
                end
            else
                -- Check if the process is still in our active list
                local still_active = false
                for _, proc in ipairs(self.bg_processes) do
                    if proc.pid == bg_proc.pid then
                        still_active = true
                        break
                    end
                end
                
                if not still_active then
                    logger.err("KomixSync: Background download subprocess failed or was cancelled.")
                    if on_failure_callback then
                        UIManager:nextTick(function()
                            on_failure_callback("Background download failed")
                        end)
                    end
                else
                    -- Still running, check again in 1 second
                    UIManager:scheduleIn(1, check_ready)
                end
            end
        end
        UIManager:scheduleIn(1, check_ready)
        return
    end
    
    local util = require("util")
    local final_dir = local_path:match("(.*)/[^/]+")
    util.makePath(final_dir .. "/")

    logger.info("KomixSync: Queued download of book", book.id, "to", local_path)

    -- Lead with the series when there is one: in a bulk download the file name
    -- alone doesn't tell which series is being fetched.
    local series = series_title or book.seriesTitle
    local subtitle = filename
    if series and series ~= "" then
        subtitle = series .. " - " .. filename
    end
    if ctx and ctx.total and ctx.total > 1 then
        subtitle = subtitle .. " " .. T(_("(%1 of %2)"), ctx.index or 1, ctx.total)
    end

    table.insert(self.queue, {
        book = book,
        series_title = series_title,
        filename = filename,
        local_path = local_path,
        final_dir = final_dir,
        subtitle = subtitle,
        size = self:getRemoteFileSize(book),
        silent = ctx.silent,
        on_success_callback = on_success_callback,
        on_failure_callback = on_failure_callback,
    })
    self:_pumpQueue()
end

-- Size in bytes of the remote file, or nil when the server doesn't report it
-- (in that case the progress dialog shows a byte counter with no bar).
function KomixSync:getRemoteFileSize(book)
    if not self.plugin.api or not self.plugin.api.get_file_size then return nil end
    local ok, size = pcall(function() return self.plugin.api:get_file_size(book.id) end)
    if ok then return size end
    return nil
end

-- ---------------------------------------------------------------------------
-- Download manager: background, pausable, cancellable
-- ---------------------------------------------------------------------------
-- The transfer runs in a child process so the parent UI stays responsive: it
-- only polls the .part file size (progress) and the child's exit status. The
-- child's pid is the handle for pause (SIGSTOP), resume (SIGCONT) and cancel.

function KomixSync:hasActiveDownload()
    return self.current ~= nil
end

function KomixSync:_pumpQueue()
    if self.current then return end
    local rec = table.remove(self.queue, 1)
    if not rec then return end
    self:_startDownload(rec)
end

function KomixSync:_startDownload(rec)
    local ffiutil = require("ffi/util")
    local JSON = require("json")
    local os = require("os")

    rec.tmp_path = rec.local_path .. ".part"
    pcall(os.remove, rec.tmp_path)

    local api = self.plugin.api
    local book_id = rec.book.id
    local tmp_path = rec.tmp_path

    local pid, parent_read_fd = ffiutil.runInSubProcess(function(child_pid, child_write_fd)
        local ok, err = api:download_book(book_id, tmp_path)
        ffiutil.writeToFD(child_write_fd, JSON.encode({ ok = ok and true or false, err = err }), true)
    end, true)

    if not pid then
        logger.err("KomixSync: Failed to fork download subprocess")
        if not rec.silent then
            self.plugin:notify(self.plugin.i18n._("Failed to start download"), "error")
        end
        if rec.on_failure_callback then
            UIManager:nextTick(function() rec.on_failure_callback("fork failed") end)
        end
        return
    end

    logger.info("KomixSync: Download subprocess started. PID: " .. tostring(pid))

    rec.pid = pid
    rec.parent_read_fd = parent_read_fd
    rec.paused = false
    self.current = rec
    UIManager:preventStandby()

    self:_showDialog(rec)
    self:_schedulePoll()
end

function KomixSync:_showDialog(rec)
    local _ = self.plugin.i18n._
    local DownloadDialog = require("komix/ui/download_dialog")
    rec.dialog = DownloadDialog:new{
        title = _("Downloading"),
        subtitle = rec.subtitle,
        status = rec.size and "" or _("Starting..."),
        percentage = rec.size and 0 or nil,
        paused = rec.paused,
        on_pause = function() self:togglePause() end,
        on_cancel = function() self:cancelCurrent() end,
        on_minimize = function() self:minimizeCurrent() end,
    }
    rec.dialog:show()
end

function KomixSync:_schedulePoll()
    if self._poll_pending then return end
    self._poll_pending = true
    UIManager:scheduleIn(1, function()
        self._poll_pending = false
        self:_pollDownload()
    end)
end

function KomixSync:_pollDownload()
    local rec = self.current
    if not rec then return end
    local ffiutil = require("ffi/util")

    if ffiutil.isSubProcessDone(rec.pid) then
        local payload = rec.parent_read_fd and ffiutil.readAllFromFD(rec.parent_read_fd) or ""
        self.current = nil
        UIManager:allowStandby()
        self:_finishDownload(rec, payload)
        self:_pumpQueue()
        return
    end

    if not rec.paused and rec.dialog then
        local lfs = require("libs/libkoreader-lfs")
        rec.dialog:setProgress(lfs.attributes(rec.tmp_path, "size") or 0, rec.size)
    end
    self:_schedulePoll()
end

function KomixSync:_finishDownload(rec, payload)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local JSON = require("json")
    local os = require("os")

    if rec.dialog then
        rec.dialog:close()
        rec.dialog = nil
    end

    local ok, result = pcall(JSON.decode, payload or "")
    local success = ok and type(result) == "table" and result.ok
    local err = (ok and type(result) == "table") and result.err or "download failed"

    if not success then
        logger.err("KomixSync: Download failed", tostring(err))
        pcall(os.remove, rec.tmp_path)
        if not rec.cancelled then
            self.plugin:notify(T(_("Failed: %1"), tostring(err)), "error")
        end
        if rec.on_failure_callback then
            UIManager:nextTick(function() rec.on_failure_callback(tostring(err)) end)
        end
        return
    end

    logger.info("KomixSync: Download successful for", rec.local_path)
    notifyDownloaded(self.plugin, T(_("Downloaded: %1"), rec.filename))
    self.plugin.settings.matched_books_cache[rec.local_path] = rec.book.id
    self.plugin:saveSettings()

    pcall(save_book_metadata, rec.local_path, rec.book, rec.series_title, self:metadataContext())

    -- Move file into place after sidecar metadata is fully written
    os.rename(rec.tmp_path, rec.local_path)

    -- Download series cover if missing and downloading to a subdir
    self:downloadSeriesCoverIfMissing(rec.book, rec.final_dir, rec.series_title)

    if rec.on_success_callback then
        UIManager:nextTick(function()
            rec.on_success_callback(rec.local_path)
        end)
    end

    -- Tell FileBrowser to refresh directory and reload file items
    UIManager:nextTick(function()
        pcall(function()
            local BookInfoManager = require("plugins/coverbrowser.koplugin/bookinfomanager")
            if BookInfoManager and BookInfoManager.deleteBookInfo then
                BookInfoManager:deleteBookInfo(rec.local_path)
            end
        end)
        local fm_ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        if fm_ok and FileManager.instance then
            if FileManager.instance.file_chooser and FileManager.instance.file_chooser.resetBookInfoCache then
                pcall(function() FileManager.instance.file_chooser.resetBookInfoCache(rec.local_path) end)
            end
            FileManager.instance:onRefresh()
        end
    end)
end

-- Pause/resume the transfer. SIGSTOP freezes the child: the TCP window closes
-- and the server pauses sending until SIGCONT.
function KomixSync:togglePause()
    local rec = self.current
    if not rec or not rec.pid then return end
    rec.paused = not rec.paused
    signalSubProcess(rec.pid, rec.paused and SIGSTOP or SIGCONT)
    logger.info("KomixSync: Download " .. (rec.paused and "paused" or "resumed") .. ": " .. rec.filename)

    -- Rebuild the dialog so the Pause/Resume label and its geometry are
    -- consistent (Button has no in-place relayout).
    if rec.dialog then
        rec.dialog:close()
        rec.dialog = nil
        self:_showDialog(rec)
        local lfs = require("libs/libkoreader-lfs")
        rec.dialog:setProgress(lfs.attributes(rec.tmp_path, "size") or 0, rec.size)
    end
end

-- Kill the running transfer and drop everything still queued: cancelling a
-- subscription sync must not leave it half-done.
function KomixSync:cancelCurrent()
    local rec = self.current
    if not rec then return end
    local ffiutil = require("ffi/util")
    local os = require("os")

    rec.cancelled = true
    pcall(ffiutil.terminateSubProcess, rec.pid)
    self.current = nil
    self.cancel_sequence = true
    self.queue = {}
    UIManager:allowStandby()

    if rec.dialog then
        rec.dialog:close()
        rec.dialog = nil
    end
    pcall(os.remove, rec.tmp_path)

    -- The killed child still has to be reaped (and its pipe closed) or it
    -- lingers as a zombie.
    local pid, fd = rec.pid, rec.parent_read_fd
    local collect
    collect = function()
        if not ffiutil.isSubProcessDone(pid) then
            UIManager:scheduleIn(1, collect)
            return
        end
        if fd then pcall(ffiutil.readAllFromFD, fd) end
    end
    UIManager:scheduleIn(1, collect)

    if rec.on_failure_callback then
        UIManager:nextTick(function() rec.on_failure_callback("cancelled") end)
    end
end

-- Hide the progress dialog but keep the transfer running.
function KomixSync:minimizeCurrent()
    local rec = self.current
    if not rec then return end
    if rec.dialog then
        rec.dialog:close()
        rec.dialog = nil
    end
    self.plugin:notify(self.plugin.i18n._("Download moved to the background"), "info")
end

-- Bring the download window back (komix → Active downloads).
function KomixSync:showActiveDownloads()
    local _ = self.plugin.i18n._
    local rec = self.current
    if not rec then
        self.plugin:notify(_("No active downloads"), "info")
        return
    end
    if rec.dialog then
        rec.dialog:refresh()
        return
    end
    self:_showDialog(rec)
    local lfs = require("libs/libkoreader-lfs")
    rec.dialog:setProgress(lfs.attributes(rec.tmp_path, "size") or 0, rec.size)
end

function KomixSync:downloadBooksSeq(books, index, on_done_callback, opts)
    index = index or 1
    opts = opts or {}
    -- A cancel drops the rest of the queue; stop here and report completion so
    -- callers (subscriptions) can clear their "running" state.
    if self.cancel_sequence then
        self.cancel_sequence = false
        if on_done_callback then
            on_done_callback()
        end
        return
    end
    if index > #books then
        if on_done_callback then
            on_done_callback()
        end
        return
    end

    local book = books[index]
    local next_step = function()
        self:downloadBooksSeq(books, index + 1, on_done_callback, opts)
    end

    self:downloadBook(book, book.seriesTitle, next_step, next_step,
        { index = index, total = #books, silent = opts.silent })
end

function KomixSync:promptNextChapter(ui, show_native_func)
    if not self.plugin.api or not ui or not ui.document then return end
    local filepath = ui.document.file
    if not filepath then return end

    local book_id = self.plugin.settings.matched_books_cache[filepath]
    if not book_id then return end

    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T

    -- Respect KOReader's "Always mark as finished" setting
    logger.info("KomixSync: Checking auto mark. G_reader_settings exists:", G_reader_settings ~= nil)
    if G_reader_settings then
        local is_auto = G_reader_settings:isTrue("end_document_auto_mark")
        logger.info("KomixSync: end_document_auto_mark value:", is_auto)
        if is_auto then
            if ui.doc_settings then
                local summary = ui.doc_settings:readSetting("summary")
                if type(summary) == "table" then
                    summary.status = "complete"
                    summary.modified = os.date("%Y-%m-%d", os.time())
                    ui.doc_settings:saveSetting("summary", summary)
                    logger.info("KomixSync: Marked summary.status as complete.")
                end
            end
            pcall(function()
                local BookList = require("ui/widget/booklist")
                BookList.setBookInfoCacheProperty(filepath, "status", "complete")
                logger.info("KomixSync: Updated BookList cache.")
            end)
            -- Also push the 100% progress up to the Komga server
            self:pushProgressForDocument(ui, true)
        end
    end

    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")

    if not NetworkMgr:isOnline() then
        local dialog
        dialog = ButtonDialog:new{
            title = _("No Wi-Fi connection. Cannot check for the next chapter."),
            buttons = {
                {
                    {
                        text = _("Open Next Chapter"),
                        enabled = false,
                        callback = function() end
                    }
                },
                {
                    {
                        text = _("Default Action"),
                        callback = function()
                            UIManager:close(dialog)
                            if show_native_func then
                                show_native_func()
                            end
                        end
                    },
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
        return true
    end

    -- Get the next book directly using Komga's native endpoint (404 → nil = no next book)
    local next_book = self.plugin.api:get_next_book(book_id)

    if not next_book then
        logger.info("KomixSync: No next chapter found.")
        self.plugin:notify(_("No next chapter found."), "info")
        return false
    end

    local series_title = next_book.seriesTitle
    local local_path, filename = self:getBookLocalPath(next_book, series_title)
    if not local_path then return false end

    local lfs = require("libs/libkoreader-lfs")
    local is_downloaded = (lfs.attributes(local_path, "mode") == "file")

    local UIManager = require("ui/uimanager")

    if self.plugin.settings.skip_end_of_book_prompt and is_downloaded then
        logger.info("KomixSync: skip_end_of_book_prompt is enabled, opening next book directly: " .. tostring(local_path))
        UIManager:nextTick(function()
            local filemanagerutil = require("apps/filemanager/filemanagerutil")
            filemanagerutil.openFile(ui, local_path)
        end)
        return true
    end

    local Event = require("ui/event")
    
    local title = next_book.metadata and next_book.metadata.title or next_book.name or "Untitled"
    local prompt_msg = is_downloaded and 
        T(_("Next chapter is ready: %1"), title) or 
        T(_("Next chapter is not downloaded: %1"), title)

    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = prompt_msg,
        buttons = {
            {
                {
                    text = is_downloaded and _("Open Next Chapter") or _("Download & Open"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(dialog)
                        local function open_doc(path)
                            logger.info("KomixSync: Opening next chapter:", path)
                            UIManager:nextTick(function()
                                local filemanagerutil = require("apps/filemanager/filemanagerutil")
                                filemanagerutil.openFile(ui, path)
                            end)
                        end

                        if is_downloaded then
                            open_doc(local_path)
                        else
                            self:downloadBook(next_book, series_title, open_doc)
                        end
                    end
                }
            },
            {
                {
                    text = _("Default Action"),
                    callback = function()
                        UIManager:close(dialog)
                        if show_native_func then
                            show_native_func()
                        end
                    end
                },
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
    
    return true
end

function KomixSync:downloadSeriesCoverIfMissing(book, final_dir, series_title)
    if not self.plugin.api then return end
    
    -- Check if we are downloading to a subdir of the series
    local is_subdir = self.plugin.settings.download_to_subfolder and series_title and series_title ~= ""
    if not is_subdir then
        return
    end

    local lfs = require("libs/libkoreader-lfs")
    
    -- Check if final_dir is a valid directory
    local mode = lfs.attributes(final_dir, "mode")
    if mode ~= "directory" then
        return
    end

    -- Check if .cover* already exists in final_dir
    local has_cover = false
    for file in lfs.dir(final_dir) do
        if file:match("^%.cover%.") or file:match("^%.cover$") then
            has_cover = true
            break
        end
    end

    if has_cover then
        logger.info("KomixSync: Series cover already exists in directory", final_dir)
        return
    end

    -- Download the series cover if seriesId is available
    local series_id = book.seriesId
    if not series_id then
        logger.warn("KomixSync: Cannot download series cover, book.seriesId is missing")
        return
    end

    logger.info("KomixSync: Downloading series cover for series", series_id, "to", final_dir)
    local img_data, err = self.plugin.api:download_series_thumbnail(series_id)
    if not img_data or type(img_data) ~= "string" or #img_data == 0 then
        logger.err("KomixSync: Failed to download series cover:", tostring(err))
        return
    end

    -- Detect image format
    local ext = "jpg"
    if img_data:sub(1, 4) == "\137PNG" or img_data:sub(1, 4) == "\137\080\078\071" then
        ext = "png"
    elseif img_data:sub(1, 3) == "\255\216\255" or img_data:sub(1, 2) == "\255\216" then
        ext = "jpg"
    elseif img_data:sub(1, 4) == "RIFF" and img_data:sub(9, 12) == "WEBP" then
        ext = "webp"
    elseif img_data:sub(1, 3) == "GIF" then
        ext = "gif"
    end

    local cover_filename = ".cover." .. ext
    local cover_filepath = final_dir .. "/" .. cover_filename

    -- Write the cover image file
    local f, f_err = io.open(cover_filepath, "wb")
    if f then
        f:write(img_data)
        f:close()
        logger.info("KomixSync: Successfully saved series cover to", cover_filepath)
    else
        logger.err("KomixSync: Failed to write series cover file:", tostring(f_err))
    end
end

function KomixSync:preDownloadNextBook(filepath)
    local download_count = self.plugin.settings.auto_download_next or 0
    if download_count <= 0 then
        logger.info("KomixSync: auto_download_next is disabled, skipping pre-download")
        return
    end

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        logger.info("KomixSync: Offline, skipping background pre-download check")
        return
    end

    local book_id = self:getOrMatchBook(filepath)
    if not book_id then
        logger.warn("KomixSync: Current book not matched, cannot pre-download next book")
        return
    end

    -- Limit to 1 background pre-download subprocess at a time
    if not self.bg_processes then
        self.bg_processes = {}
    end
    if #self.bg_processes > 0 then
        logger.info("KomixSync: A background pre-download is already active. Skipping new spawn.")
        return
    end

    local ffiutil = require("ffi/util")
    local UIManager = require("ui/uimanager")
    local os = require("os")

    -- Call runInSubProcess with_pipe = true
    local pid, parent_read_fd = ffiutil.runInSubProcess(function(pid, child_write_fd)
        local success, result = pcall(function()
            local current_id = book_id
            local downloaded_books = {}
            local already_downloaded_count = 0
            local errors = {}

            for step = 1, download_count do
                local next_book = self.plugin.api:get_next_book(current_id)
                if not next_book then
                    logger.info("KomixSync bg: No next chapter found after book ID " .. tostring(current_id))
                    break
                end

                local series_title = next_book.seriesTitle
                local local_path, filename = self:getBookLocalPath(next_book, series_title)
                if not local_path then
                    table.insert(errors, "No download path available for " .. tostring(next_book.name))
                    break
                end

                local lfs = require("libs/libkoreader-lfs")
                if lfs.attributes(local_path, "mode") == "file" then
                    already_downloaded_count = already_downloaded_count + 1
                    current_id = next_book.id
                else
                    -- Start downloading
                    local tmp_path = local_path .. ".part"
                    local util = require("util")
                    local final_dir = local_path:match("(.*)/[^/]+")
                    util.makePath(final_dir .. "/")

                    logger.info("KomixSync bg: Downloading book " .. next_book.id .. " in background to " .. tmp_path)
                    local dl_success, dl_err = self.plugin.api:download_book(next_book.id, tmp_path)
                    if dl_success then
                        pcall(save_book_metadata, local_path, next_book, series_title, self:metadataContext())
                        local os = require("os")
                        os.rename(tmp_path, local_path)
                        self:downloadSeriesCoverIfMissing(next_book, final_dir, series_title)
                        logger.info("KomixSync bg: Finished downloading next chapter: " .. local_path)
                        table.insert(downloaded_books, {
                            local_path = local_path,
                            next_book_id = next_book.id,
                            filename = filename
                        })
                        current_id = next_book.id
                    else
                        logger.err("KomixSync bg: Failed to download book " .. next_book.id .. ": " .. tostring(dl_err))
                        table.insert(errors, tostring(dl_err))
                        break -- stop downloading subsequent ones if one fails
                    end
                end
            end

            return {
                status = "success",
                downloaded = downloaded_books,
                already_downloaded = already_downloaded_count,
                errors = errors
            }
        end)

        local JSON = require("json")
        local output_str
        if success then
            output_str = JSON.encode(result)
        else
            output_str = JSON.encode({ status = "error", message = tostring(result) })
        end
        ffiutil.writeToFD(child_write_fd, output_str, true)
    end, true) -- with_pipe = true

    if not pid then
        logger.err("KomixSync: Failed to fork background pre-download subprocess")
        return
    end

    logger.info("KomixSync: Spawning background pre-download subprocess. PID: " .. tostring(pid))
    UIManager:preventStandby()

    table.insert(self.bg_processes, {
        pid = pid,
        parent_read_fd = parent_read_fd,
        current_book_id = book_id,
        start_time = os.time()
    })

    if not self.bg_collector_scheduled then
        self.bg_collector_scheduled = true
        UIManager:scheduleIn(1, function()
            self:collectBgDownloads()
        end)
    end
end

function KomixSync:collectBgDownloads()
    if not self.bg_processes or #self.bg_processes == 0 then
        self.bg_collector_scheduled = false
        return
    end

    local ffiutil = require("ffi/util")
    local UIManager = require("ui/uimanager")
    local os = require("os")

    for i = #self.bg_processes, 1, -1 do
        local proc = self.bg_processes[i]
        if ffiutil.isSubProcessDone(proc.pid) then
            logger.info("KomixSync: Background pre-download subprocess done. PID: " .. tostring(proc.pid))
            table.remove(self.bg_processes, i)
            UIManager:allowStandby()

            -- Read pipe output
            local ret_str = ""
            if proc.parent_read_fd then
                ret_str = ffiutil.readAllFromFD(proc.parent_read_fd)
            end

            local JSON = require("json")
            local ok, result = pcall(JSON.decode, ret_str)
            if ok and result and type(result) == "table" then
                if result.status == "success" then
                    if result.downloaded and #result.downloaded > 0 then
                        for _, item in ipairs(result.downloaded) do
                            -- Update matched_books_cache in the parent process
                            self.plugin.settings.matched_books_cache[item.local_path] = item.next_book_id
                        end
                        self.plugin:saveSettings()

                        -- Log pre-download completion silently
                        if #result.downloaded == 1 then
                            logger.info("KomixSync: Next chapter downloaded in background: " .. tostring(result.downloaded[1].filename))
                        else
                            logger.info("KomixSync: Downloaded " .. tostring(#result.downloaded) .. " next chapters in background")
                        end

                        -- Trigger UI refresh if FileManager is open
                        UIManager:nextTick(function()
                            pcall(function()
                                local BookInfoManager = require("plugins/coverbrowser.koplugin/bookinfomanager")
                                if BookInfoManager and BookInfoManager.deleteBookInfo then
                                    for _, item in ipairs(result.downloaded) do
                                        BookInfoManager:deleteBookInfo(item.local_path)
                                    end
                                end
                            end)
                            local ok2, FileManager = pcall(require, "apps/filemanager/filemanager")
                            if ok2 and FileManager.instance then
                                if FileManager.instance.file_chooser and FileManager.instance.file_chooser.resetBookInfoCache then
                                    for _, item in ipairs(result.downloaded) do
                                        pcall(function() FileManager.instance.file_chooser.resetBookInfoCache(item.local_path) end)
                                    end
                                end
                                FileManager.instance:onRefresh()
                            end
                        end)
                    else
                        logger.info("KomixSync: Background check completed - no new chapters downloaded (already downloaded: " .. tostring(result.already_downloaded) .. ")")
                    end
                elseif result.status == "error" then
                    logger.warn("KomixSync: Background pre-download failed: " .. tostring(result.message))
                end
            else
                logger.err("KomixSync: Failed to parse result from background download subprocess. Error: " .. tostring(result) .. " | Raw Input: " .. tostring(ret_str))
            end

            -- Check if the user has switched chapters/books during the download.
            -- If so, trigger a new pre-download window check for the currently active book.
            local current_filepath = self.plugin.ui and self.plugin.ui.document and self.plugin.ui.document.file
            if current_filepath then
                local current_book_id = self:getOrMatchBook(current_filepath)
                if current_book_id and current_book_id ~= proc.current_book_id then
                    logger.info("KomixSync: User switched book during pre-download. Cascade triggering for new book.")
                    UIManager:nextTick(function()
                        self:preDownloadNextBook(current_filepath)
                    end)
                end
            end
        else
            local elapsed = os.time() - proc.start_time
            if elapsed > 600 then -- 10 minutes
                logger.warn("KomixSync: Background download subprocess PID: " .. tostring(proc.pid) .. " timed out. Terminating.")
                ffiutil.terminateSubProcess(proc.pid)
            end
        end
    end

    if #self.bg_processes > 0 then
        -- Schedule the next check
        UIManager:scheduleIn(1, function()
            self:collectBgDownloads()
        end)
    else
        self.bg_collector_scheduled = false
    end
end

return KomixSync
