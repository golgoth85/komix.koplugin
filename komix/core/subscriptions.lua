-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Part of komix (see LICENSE).
--[[
    komix category subscriptions.
    Lets the user subscribe to one or more read lists / collections; new books
    appearing in them are downloaded locally. Runs manually (menu / dispatcher)
    and automatically when the network comes back online.
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Removals = require("komix/core/removals")

local PAGE_SIZE = 100
local MAX_PAGES = 200

local Subscriptions = {}
Subscriptions.__index = Subscriptions

function Subscriptions:new(plugin)
    return setmetatable({
        plugin = plugin,
        running = false,
        auto_scheduled = false,
        removals = Removals:new(plugin),
    }, self)
end

function Subscriptions:list()
    return self.plugin.settings.subscriptions or {}
end

function Subscriptions:isEmpty()
    return #self:list() == 0
end

function Subscriptions:add(kind, id, name)
    if not id or (kind ~= "readlist" and kind ~= "collection") then return false end
    local subs = self.plugin.settings.subscriptions or {}
    for _, s in ipairs(subs) do
        if s.kind == kind and s.id == id then return false end
    end
    table.insert(subs, { kind = kind, id = id, name = name or id })
    self.plugin.settings.subscriptions = subs
    self.plugin:saveSettings()
    return true
end

-- Stable key for a subscription: names change, ids don't.
function Subscriptions:key(sub)
    return sub.kind .. ":" .. sub.id
end

function Subscriptions:remove(kind, id)
    local subs = self.plugin.settings.subscriptions or {}
    for i, s in ipairs(subs) do
        if s.kind == kind and s.id == id then
            table.remove(subs, i)
            -- Forget what this subscription contained: it no longer exists, so
            -- its books must not be proposed for deletion later.
            local known = self.plugin.settings.subscription_known or {}
            known[self:key(s)] = nil
            self.plugin.settings.subscription_known = known
            self.plugin:saveSettings()
            return true
        end
    end
    return false
end

function Subscriptions:has(kind, id)
    for _, s in ipairs(self:list()) do
        if s.kind == kind and s.id == id then return true end
    end
    return false
end

-- Fetch every book belonging to a subscription (paginating the whole way).
function Subscriptions:collectBooks(sub)
    local api = self.plugin.api
    if not api then return {} end
    local books = {}

    local function paginate(fetch, on_page)
        local page = 0
        while page < MAX_PAGES do
            local res = fetch(page)
            if type(res) ~= "table" then break end
            local content = res.content or {}
            if #content == 0 then break end
            on_page(content)
            local total = res.totalPages or 1
            page = page + 1
            if page >= total then break end
        end
    end

    if sub.kind == "readlist" then
        paginate(function(page)
            return api:get_readlist_books(sub.id, page, PAGE_SIZE)
        end, function(content)
            for _, b in ipairs(content) do table.insert(books, b) end
        end)
    elseif sub.kind == "collection" then
        paginate(function(page)
            return api:get_collection_series(sub.id, page, PAGE_SIZE)
        end, function(series_list)
            for _, s in ipairs(series_list) do
                paginate(function(bpage)
                    return api:get_books_for_series(s.id, nil, bpage, PAGE_SIZE)
                end, function(content)
                    for _, b in ipairs(content) do table.insert(books, b) end
                end)
            end
        end)
    end

    return books
end

-- Books each subscription contained at the end of the previous sync.
function Subscriptions:knownBooks()
    return self.plugin.settings.subscription_known or {}
end

-- Replace the remembered content with what the server just returned. Called on
-- every sync, also when the removal check is off: were it kept stale, turning
-- the check back on would later propose deleting books removed long ago.
function Subscriptions:rememberBooks(per_sub)
    local known = {}
    for key, books in pairs(per_sub) do
        local entries = {}
        for _i, b in ipairs(books) do
            local md = type(b.metadata) == "table" and b.metadata or {}
            entries[b.id] = {
                series = b.seriesTitle or md.series or "",
                title = md.title or b.name or "",
            }
        end
        known[key] = entries
    end
    self.plugin.settings.subscription_known = known
    self.plugin:saveSettings()
end

-- Fetch every subscription once, splitting the catalogue into what is new
-- locally and what each subscription holds. Returns the books per subscription,
-- the union of book ids seen, the books to download and their total count.
function Subscriptions:collectAll()
    local per_sub, seen, to_download = {}, {}, {}
    local total_found = 0
    self.last_counts = {}

    for _i, sub in ipairs(self:list()) do
        local books = self:collectBooks(sub)
        local held, new_count = {}, 0
        for _j, b in ipairs(books) do
            if b.id then
                table.insert(held, b)
                if not seen[b.id] then
                    seen[b.id] = true
                    total_found = total_found + 1
                    if not self.plugin.sync:isBookDownloaded(b) then
                        table.insert(to_download, b)
                        new_count = new_count + 1
                    end
                end
            end
        end
        per_sub[self:key(sub)] = held
        self.last_counts[sub.name or sub.id] = new_count
    end

    return per_sub, seen, to_download, total_found
end

-- Ask what to do with comics that left the subscriptions but are still on the
-- device; on_done() runs once the question is answered.
function Subscriptions:askAboutRemoved(removed, on_done)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local RemovalDialog = require("komix/ui/removal_dialog")

    RemovalDialog:show{
        text = self.removals:message(removed),
        delete_text = _("Delete"),
        keep_text = _("Keep"),
        checkbox_text = _("Don't ask again (always keep local files)"),
        on_answer = function(delete, dont_ask_again)
            if delete then
                local n = self.removals:deleteLocal(removed)
                self.plugin:notify(T(_("Deleted %1 file(s)"), n), "info")
            elseif dont_ask_again then
                self.plugin.settings.subscriptions_check_removed = false
                self.plugin:saveSettings()
                self.plugin:notify(_("Local files removed from subscriptions will be kept."), "info")
            end
            if on_done then on_done() end
        end,
    }
end

-- Download every not-yet-local book from the subscribed categories, after
-- asking about the comics that disappeared from them.
-- opts.on_done() is called when the (possibly empty) download queue finishes.
function Subscriptions:syncAll(opts)
    opts = opts or {}
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T

    if self.running then
        if not opts.silent then self.plugin:notify(_("Subscription sync already running"), "info") end
        return
    end
    if not self.plugin.api then
        if not opts.silent then self.plugin:notify(_("Configure the Komga server first"), "error") end
        return
    end
    if self:isEmpty() then
        if not opts.silent then self.plugin:notify(_("No subscribed categories"), "info") end
        return
    end

    self.running = true
    local message = InfoMessage:new{ text = _("Checking subscriptions...") }
    UIManager:show(message)
    UIManager:forceRePaint()

    UIManager:nextTick(function()
        local per_sub, seen, to_download, total_found = self:collectAll()

        -- Compute the candidates against the previous sync's content, then
        -- remember the current one.
        local removed = self.plugin.settings.subscriptions_check_removed
            and self.removals:findRemoved(self:knownBooks(), seen) or {}
        self:rememberBooks(per_sub)

        UIManager:close(message)

        local function proceed()
            if #to_download == 0 then
                self.running = false
                if not opts.silent then
                    self.plugin:notify(T(_("Subscriptions up to date (%1 books)"), total_found), "info")
                end
                if opts.on_done then opts.on_done(0) end
                return
            end

            if not opts.silent then
                self.plugin:notify(T(_("Downloading %1 new book(s) from subscriptions"), #to_download), "info")
            end

            self.plugin.sync:downloadBooksSeq(to_download, 1, function()
                self.running = false
                self.plugin:notify(T(_("Subscription sync finished (%1 new)"), #to_download), "info")
                if opts.on_done then opts.on_done(#to_download) end
            end, { silent = true })
        end

        if #removed > 0 then
            self:askAboutRemoved(removed, proceed)
        else
            proceed()
        end
    end)
end

-- Called on the NetworkConnected event: if auto-sync is on and we have
-- subscriptions, wait a moment for the connection to settle then sync.
function Subscriptions:maybeAutoSync()
    if not self.plugin.settings.auto_sync_subscriptions then return end
    if self:isEmpty() then return end
    if self.running or self.auto_scheduled then return end
    if not NetworkMgr:isOnline() then return end

    self.auto_scheduled = true
    UIManager:scheduleIn(3, function()
        self.auto_scheduled = false
        if NetworkMgr:isOnline() and not self.running then
            logger.info("Komix: auto-syncing subscriptions after network connect")
            self:syncAll({ auto = true, silent = true })
        end
    end)
end

return Subscriptions
