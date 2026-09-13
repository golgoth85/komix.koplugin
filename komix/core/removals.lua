-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Part of komix (see LICENSE).
--[[
    Comics that disappeared from a subscribed category.

    A comic downloaded by a subscription, then removed from the read list /
    collection on the server, would otherwise stay on the device forever. The
    sync remembers which books each subscription contained last time; anything
    that was there, is gone now and still exists locally becomes a candidate for
    deletion, and the user is asked before anything is removed.

    Only the files of the disappeared comics are deleted — a series folder is
    dropped only when it is left empty, so the other volumes of a series that is
    still subscribed are never touched.
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local Removals = {}
Removals.__index = Removals

-- Keep the confirmation dialog readable on a small screen.
local MAX_SERIES_LISTED = 6
local MAX_FILES_PER_SERIES = 4

function Removals:new(plugin)
    return setmetatable({ plugin = plugin }, self)
end

-- Local paths of every known Komga book. matched_books_cache maps the other
-- way round (local path -> book id), and a book may exist under two paths when
-- it was downloaded before a naming-template change, so keep all of them.
function Removals:localPathsByBookId()
    local paths = {}
    for path, book_id in pairs(self.plugin.settings.matched_books_cache or {}) do
        if book_id then
            paths[book_id] = paths[book_id] or {}
            table.insert(paths[book_id], path)
        end
    end
    return paths
end

-- `known` is the remembered content of each subscription; `present` holds the
-- book ids the server returned in this sync (union of all subscriptions, so a
-- book moved from one subscribed list to another is not a candidate).
-- Returns a list of { id, path, series, title, filename }, sorted by series.
function Removals:findRemoved(known, present)
    local paths = self:localPathsByBookId()
    local found = {}

    for sub_key, entries in pairs(known or {}) do
        for book_id, info in pairs(entries) do
            if not present[book_id] then
                for _i, path in ipairs(paths[book_id] or {}) do
                    if lfs.attributes(path, "mode") == "file" then
                        table.insert(found, {
                            id = book_id,
                            path = path,
                            series = info.series or "",
                            title = info.title or "",
                            filename = path:match("([^/]+)$") or path,
                            subscription = sub_key,
                        })
                    end
                end
            end
        end
    end

    table.sort(found, function(a, b)
        if a.series ~= b.series then return a.series:lower() < b.series:lower() end
        return a.filename < b.filename
    end)
    return found
end

-- Candidates grouped by series, in the order they were found.
function Removals.groupBySeries(removed)
    local order, by_series = {}, {}
    for _i, item in ipairs(removed) do
        local name = item.series ~= "" and item.series or "?"
        if not by_series[name] then
            by_series[name] = {}
            table.insert(order, name)
        end
        table.insert(by_series[name], item)
    end
    return order, by_series
end

-- Confirmation text: the affected series, with the files that would go.
function Removals:message(removed)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local order, by_series = Removals.groupBySeries(removed)

    local lines = {}
    for i = 1, math.min(#order, MAX_SERIES_LISTED) do
        local name = order[i]
        local items = by_series[name]
        local names = {}
        for j = 1, math.min(#items, MAX_FILES_PER_SERIES) do
            table.insert(names, items[j].filename)
        end
        if #items > MAX_FILES_PER_SERIES then
            table.insert(names, T(_("and %1 more"), #items - MAX_FILES_PER_SERIES))
        end
        table.insert(lines, "• " .. name .. " — " .. table.concat(names, ", "))
    end
    if #order > MAX_SERIES_LISTED then
        table.insert(lines, T(_("… and %1 more series"), #order - MAX_SERIES_LISTED))
    end

    return T(_("These downloaded comics are no longer in your subscriptions:"))
        .. "\n\n" .. table.concat(lines, "\n")
        .. "\n\n" .. T(_("Delete these %1 files from the device?"), #removed)
end

function Removals:isEmptyDir(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then return false end
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then return false end
    end
    return true
end

-- Delete the candidate files (with their sidecars) and any series folder left
-- empty. Returns the number of files actually removed.
function Removals:deleteLocal(removed)
    local DocSettings = require("docsettings")
    local os = require("os")

    local deleted_paths, dirs = {}, {}
    for _i, item in ipairs(removed) do
        if lfs.attributes(item.path, "mode") == "file" then
            pcall(DocSettings.updateLocation, item.path) -- removes the .sdr sidecar
            if os.remove(item.path) then
                table.insert(deleted_paths, item.path)
                self.plugin.settings.matched_books_cache[item.path] = nil
                local dir = item.path:match("(.*)/[^/]+")
                if dir then dirs[dir] = true end
            else
                logger.warn("Komix removals: could not delete " .. item.path)
            end
        end
    end
    if #deleted_paths > 0 then
        self.plugin:saveSettings()
    end

    -- Never remove the download root: with flat naming that is the folder the
    -- series would otherwise resolve to.
    local root = self.plugin:getDownloadDir()
    for dir in pairs(dirs) do
        if dir ~= root and self:isEmptyDir(dir) then
            pcall(lfs.rmdir, dir)
        end
    end

    self:refreshFileManager(deleted_paths)
    return #deleted_paths
end

-- Tell KOReader the files are gone, so their cached metadata and the file
-- browser don't keep showing them.
function Removals:refreshFileManager(paths)
    if #paths == 0 then return end
    UIManager:nextTick(function()
        pcall(function()
            local BookInfoManager = require("plugins/coverbrowser.koplugin/bookinfomanager")
            if BookInfoManager and BookInfoManager.deleteBookInfo then
                for _i, path in ipairs(paths) do
                    BookInfoManager:deleteBookInfo(path)
                end
            end
        end)
        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        if ok and FileManager.instance then
            if FileManager.instance.file_chooser and FileManager.instance.file_chooser.resetBookInfoCache then
                for _i, path in ipairs(paths) do
                    pcall(function() FileManager.instance.file_chooser.resetBookInfoCache(path) end)
                end
            end
            FileManager.instance:onRefresh()
        end
    end)
end

return Removals
