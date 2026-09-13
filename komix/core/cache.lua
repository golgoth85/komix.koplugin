--[[
    Komga Metadata Cache & File Helpers
    Handles persistent offline storage of library structures and cover art.
--]]

local logger = require("logger")

local KomixCache = {}

-- Change-detection key for a catalog entry: series/books carry `lastModified`,
-- read lists carry `updatedAt`.
local function changeKey(item)
    return item.lastModified or item.updatedAt
end

function KomixCache:new(plugin)
    local o = { plugin = plugin }
    return setmetatable(o, { __index = self })
end

-- Helper to write binary files safely using Lua I/O
function KomixCache:write_file(filepath, content)
    local f = io.open(filepath, "wb")
    if f then
        f:write(content)
        f:close()
        return true
    end
    return false
end

-- Ensures cover-art cache table exists
function KomixCache:ensureStructure()
    if not self.plugin.settings.library_metadata_cache then
        self.plugin.settings.library_metadata_cache = {}
    end
    local cache = self.plugin.settings.library_metadata_cache
    if not cache.covers then cache.covers = {} end
end

function KomixCache:clear()
    self.plugin.settings.library_metadata_cache = {}
    self:ensureStructure()
    self.plugin:saveSettings()
    logger.info("[Komix Cache] Cleared metadata cache")
end

-- Downloads and maintains dynamic offline cover art inside downloads directory
function KomixCache:cacheThumbnail(type_label, id, lastModifiedString, force)
    if not force and not self.plugin.settings.cache_covers then return nil end
    
    self:ensureStructure()
    local cache = self.plugin.settings.library_metadata_cache
    local cache_key = type_label .. "_" .. id
    
    local DataStorage = require("datastorage")
    local covers_dir = DataStorage:getDataDir() .. "/komga_covers"
    local util = require("util")
    util.makePath(covers_dir .. "/")
    
    local local_path = covers_dir .. "/" .. cache_key .. ".jpg"
    
    -- Check if file already exists AND lastModified hasn't changed
    local file_exists = false
    local f_test = io.open(local_path, "rb")
    if f_test then
        file_exists = true
        f_test:close()
    end
    
    if file_exists then
        if self.plugin.settings.never_update_covers or cache.covers[cache_key] == lastModifiedString then
            return local_path
        end
    end
    
    logger.info("[Komix Cache] Fetching and caching cover: " .. cache_key)
    local img_data = nil
    if type_label == "series" then
        img_data = self.plugin.api:download_series_thumbnail(id)
    elseif type_label == "readlist" then
        img_data = self.plugin.api:download_readlist_thumbnail(id)
    else
        img_data = self.plugin.api:download_book_thumbnail(id)
    end
    
    if img_data and type(img_data) == "string" and #img_data > 0 then
        local ok = self:write_file(local_path, img_data)
        if ok then
            cache.covers[cache_key] = lastModifiedString
            self.plugin:saveSettings()
            return local_path
        end
    end
    return nil
end

-- Pre-flights a list of items to count missing covers, then downloads them sequentially with a UI blocker
function KomixCache:prefetchCovers(item_list, type_label)
    if not item_list or #item_list == 0 then return end
    
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    
    self:ensureStructure()
    local cache = self.plugin.settings.library_metadata_cache
    local DataStorage = require("datastorage")
    local covers_dir = DataStorage:getDataDir() .. "/komga_covers"
    
    local to_download = {}
    for _, item in ipairs(item_list) do
        local cache_key = type_label .. "_" .. item.id
        local local_path = covers_dir .. "/" .. cache_key .. ".jpg"
        
        local file_exists = false
        local f = io.open(local_path, "rb")
        if f then file_exists = true; f:close() end
        
        local needs_download = true
        if file_exists then
            if self.plugin.settings.never_update_covers or cache.covers[cache_key] == changeKey(item) then
                needs_download = false
            end
        end
        
        if needs_download then
            table.insert(to_download, item)
        end
    end
    
    if #to_download == 0 then return end
    
    logger.info("[Komix Cache] Pre-fetching " .. #to_download .. " covers for " .. type_label)
    local message = InfoMessage:new{ text = "Downloading " .. #to_download .. " new covers..." }
    UIManager:show(message)
    UIManager:forceRePaint()
    
    for _, item in ipairs(to_download) do
        self:cacheThumbnail(type_label, item.id, changeKey(item), true)
    end
    
    UIManager:close(message)
end

return KomixCache
