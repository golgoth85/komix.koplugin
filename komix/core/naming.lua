-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Ported from the komga KOReader plugin, Copyright (C) 2026 Jonathan Willian.
--[[
    komix naming engine.
    Fusion of the komga plugin's path/naming modules (pathutil, chapter_name,
    name_template, download_path) with kokomga's media-type extension logic.

    A single planPath() is used both by the downloader and by the
    "already downloaded" check, so the two never disagree.
--]]

local Naming = {}

-- Illegal on FAT32/exFAT (Kobo) plus control chars.
local ILLEGAL = '[\\/:%*%?"<>|%c]'
local SEP = "[%-_%. ]"
local KNOWN = { series = true, title = true, number = true }

Naming.DEFAULT_TEMPLATE = "{number}"

function Naming.sanitizeComponent(name)
    if not name or name == "" then return "_" end
    local out = name:gsub(ILLEGAL, " ")
    out = out:gsub("%s+", " ")
    out = out:gsub("^%s+", "")
    out = out:gsub("[%.%s]+$", "")
    if out == "" then return "_" end
    return out
end

-- Zero-padded chapter name from a numeric sort: 1 -> "0001", 16.5 -> "0016.5",
-- -2 -> "-0002". %04d keeps it identical on LuaJIT and host Lua.
function Naming.numberFor(sort)
    sort = sort or 0
    local sign = sort < 0 and "-" or ""
    local abs = math.abs(sort)
    local int = math.floor(abs)
    if abs == int then
        return sign .. string.format("%04d", int)
    end
    local frac = tostring(abs):match("%.(%d+)$") or ""
    return sign .. string.format("%04d", int) .. "." .. frac
end

-- Numeric sort value for a book: metadata.numberSort wins, then metadata.number.
function Naming.sortFor(book)
    local md = book and book.metadata
    if type(md) == "table" then
        local s = md.numberSort
        if s ~= nil then
            local n = tonumber(s)
            if n then return n end
        end
        local num = md.number
        if num ~= nil then
            local n = tonumber(num)
            if n then return n end
        end
    end
    return nil
end

-- Extension derived from the media type; falls back to an existing valid
-- (non purely numeric) extension on the filename, then ".cbz".
function Naming.extensionFor(book)
    local mt = book and book.media and book.media.mediaType
    if mt == "application/zip" or mt == "application/x-zip-compressed" then return ".cbz" end
    if mt == "application/pdf" then return ".pdf" end
    if mt == "application/epub+zip" then return ".epub" end
    if mt == "application/x-rar-compressed" or mt == "application/x-rar" then return ".cbr" end
    local name = (book and book.name) or ""
    local ext = name:match("%.([a-zA-Z0-9]+)$")
    if ext and not ext:match("^%d+$") then return "." .. ext:lower() end
    return ".cbz"
end

-- Returns true, or false + kind ("unknown"|"missing_number"|"missing_series") + detail.
function Naming.validate(template, opts)
    if type(template) ~= "string" then return false, "unknown", "" end
    for key in template:gmatch("{(%w*)}") do
        if not KNOWN[key] then return false, "unknown", key end
    end
    if not template:find("{number}", 1, true) then return false, "missing_number" end
    if opts and opts.flat and not template:find("{series}", 1, true) then
        return false, "missing_series"
    end
    return true
end

-- Renders the template; empty fields eat an adjacent separator. Falls back to
-- `ctx.fallback` when nothing usable remains.
function Naming.render(template, ctx)
    ctx = ctx or {}
    local name = template:gsub("{(%w+)}", function(key)
        local v = ctx[key]
        if v == nil or v == "" then return "\1" end
        return v
    end)
    name = name:gsub(SEP .. "\1", ""):gsub("\1" .. SEP .. "?", "")
    if name:gsub(SEP, "") == "" then name = ctx.fallback or ctx.number or "" end
    return Naming.sanitizeComponent(name)
end

-- Root directory for a book: <root>/<sanitized series> unless flat naming.
function Naming.dirFor(root, series_title, opts)
    if opts and opts.flat then return root end
    return root .. "/" .. Naming.sanitizeComponent(series_title)
end

-- Absolute path a book downloads to. opts = { template, flat, title }.
-- Returns path, filename.
function Naming.planPath(root, book, series_title, opts)
    opts = opts or {}
    if not root or root == "" then return nil, nil end

    local series = series_title or (book and book.seriesTitle)
        or (book and book.metadata and book.metadata.series) or ""
    local title = (book and book.metadata and book.metadata.title) or (book and book.name) or ""
    local sort = Naming.sortFor(book)
    local number = sort and Naming.numberFor(sort) or ""

    local template = opts.template or Naming.DEFAULT_TEMPLATE
    local fallback = title ~= "" and title or (book and book.name) or (book and book.id) or ""
    local name = Naming.render(template, {
        series = series,
        title = opts.title or title,
        number = number,
        fallback = fallback,
    })

    local filename = name .. Naming.extensionFor(book)
    local dir = Naming.dirFor(root, series, opts)
    return dir .. "/" .. filename, filename
end

return Naming
