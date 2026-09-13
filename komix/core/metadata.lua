-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Part of komix (see LICENSE).
--[[
    Pure metadata helpers for komix.
    Author filtering (writer / artist / both / none) and description resolution
    (book summary, with the containing series' summary as fallback).
--]]

local Metadata = {}

-- Author roles grouped for the metadata author filter.
Metadata.AUTHOR_ROLE_SETS = {
    writer = { author = true, co_author = true, writer = true },
    artist = {
        illustrator = true, penciller = true, inker = true,
        colorist = true, letterer = true, cover_artist = true,
    },
}

local function role_matches(mode, role)
    if mode == "both" then return true end
    -- An author without a role can't be classified: keep it rather than drop it.
    if role == nil or role == "" then return true end
    local set = Metadata.AUTHOR_ROLE_SETS[mode]
    if not set then return true end
    return set[role] == true
end

-- Build the "authors" string from book metadata honouring the configured mode
-- ("writer" | "artist" | "both" | "none"). Returns nil when nothing applies.
function Metadata.collect_authors(book, mode)
    if mode == "none" then return nil end
    local md = book and book.metadata
    if type(md) ~= "table" then return nil end

    local names, seen = {}, {}
    local function add(n)
        if type(n) == "string" and n ~= "" and not seen[n] then
            seen[n] = true
            table.insert(names, n)
        end
    end

    if type(md.authors) == "table" and #md.authors > 0 then
        for _, a in ipairs(md.authors) do
            if type(a) == "table" and role_matches(mode, a.role) then
                add(a.name)
            end
        end
    else
        -- Fallback to the convenience arrays when the authors list is absent.
        -- Iterate key names (never an array of possibly-nil values: holes would
        -- truncate ipairs).
        local keys
        if mode == "writer" then
            keys = { "writers" }
        elseif mode == "artist" then
            keys = { "pencillers", "inkers", "colorists", "letterers", "coverArtists" }
        else
            keys = { "writers", "pencillers", "inkers", "colorists", "letterers", "coverArtists" }
        end
        for _, k in ipairs(keys) do
            local arr = md[k]
            if type(arr) == "table" then
                for _, n in ipairs(arr) do add(n) end
            end
        end
    end

    if #names == 0 then return nil end
    return table.concat(names, ", ")
end

local function nonempty_summary(md)
    if type(md) == "table" and type(md.summary) == "string" and md.summary ~= "" then
        return md.summary
    end
    return nil
end

-- Description of a book: its own summary, else the series summary when provided.
function Metadata.description(book, series)
    local own = nonempty_summary(book and book.metadata)
    if own then return own end
    return nonempty_summary(series and series.metadata)
end

-- True when the given book already carries its own (non-empty) summary, i.e. no
-- series lookup is needed.
function Metadata.has_own_description(book)
    return nonempty_summary(book and book.metadata) ~= nil
end

return Metadata
