--[[
    Komga API Connector for KOReader (komix).
    Handles communication with your Komga server, with retry/backoff and
    configurable download timeouts (fused from the komga plugin).
--]]

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local url_utils = require("socket.url")
local logger = require("logger")

local JSON = require("json")
local Retry = require("komix/core/retry")

-- Basic base64 encoding (if no lib is available, usually KOReader plugins use a fallback)
local function encode_base64(data)
    local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    return ((data:gsub('.', function(x)
        local r, b = '', x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2^i - b % 2^(i-1) > 0 and '1' or '0') end
        return r;
    end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i,i) == '1' and 2^(6-i) or 0) end
        return b:sub(c+1, c+1)
    end) .. ({ '', '==', '=' })[#data%3+1])
end

local KomixAPI = {}
KomixAPI.__index = KomixAPI

-- Universal HTTP Request Helper (Matching OPDS plugin pattern)
local function perform_request(args)
    local response_body = {}
    local request_params = {
        url = args.url,
        method = args.method or "GET",
        headers = args.headers or {},
        sink = args.sink or ltn12.sink.table(response_body),
        timeout = args.timeout or 10
    }

    if args.post_data then
        request_params.source = ltn12.source.string(args.post_data)
        request_params.headers["Content-Length"] = tostring(#args.post_data)
    end

    local res, code, headers, status
    if args.url:find("https://") == 1 then
        res, code, headers, status = https.request(request_params)
    else
        res, code, headers, status = http.request(request_params)
    end

    logger.dbg("Komga API URL:", args.url)
    logger.dbg("Komga API Request Method:", request_params.method)
    logger.dbg("Komga API Response Code:", code)
    logger.dbg("Komga API Response Status:", status)

    if not res then
        logger.err("Komga API Request failed:", tostring(code))
        return nil, code or "Network request failed"
    end

    return {
        code = tonumber(code) or code,
        body = not args.sink and table.concat(response_body) or nil,
        headers = headers,
        status = status
    }
end

-- Helper for URI escaping (Using socket.url like OPDS)
local function escape_uri(str)
    return url_utils.escape(str)
end

local function build_query(params)
    if not params or #params == 0 then return "" end
    return "?" .. table.concat(params, "&")
end

-- A response is worth retrying when the transport failed (nil) or the server
-- returned a flaky 5xx; anything below 500 is a definitive answer.
local function should_retry(a)
    if a == nil then return true end
    if type(a.code) ~= "number" then return true end
    return a.code >= 500
end

-- Initialize API details
-- opts (optional): { block_timeout, total_timeout, retry_attempts, sleep, on_retry }
function KomixAPI:new(base_url, api_key, opts)
    opts = opts or {}
    local o = setmetatable({}, self)

    -- Normalize URL
    if type(base_url) == "string" then
        o.base_url = base_url:gsub("/+$", "")
    else
        o.base_url = ""
    end
    o.api_key = api_key

    -- Cache for auth header
    o.auth_header = nil

    o.retry_attempts = opts.retry_attempts or Retry.DEFAULT_ATTEMPTS
    o.sleep = opts.sleep
    o.on_retry = opts.on_retry
    o.timeouts = {
        block = opts.block_timeout,
        total = opts.total_timeout,
    }

    return o
end

-- Create the request headers
function KomixAPI:get_headers()
    local headers = {
        ["Accept"] = "application/json",
        ["Content-Type"] = "application/json"
    }
    if self.api_key and self.api_key ~= "" then
        headers["X-API-Key"] = self.api_key
    elseif self.auth_header then
        headers["Authorization"] = self.auth_header
    end
    return headers
end

-- Helper to perform a synchronized HTTP request (with retry/backoff)
function KomixAPI:request(path, method, body_data)
    local url = self.base_url .. path
    local headers = self:get_headers()

    local post_data = nil
    if body_data then
        post_data = JSON.encode(body_data)
    end

    local function attempt()
        return perform_request({
            url = url,
            method = method or "GET",
            headers = headers,
            post_data = post_data,
            timeout = self.timeouts.block or 10,
        })
    end

    local res, err = Retry.run(attempt, {
        attempts = self.retry_attempts,
        should_retry = should_retry,
        sleep = self.sleep,
        on_retry = self.on_retry,
    })

    if not res then
        logger.warn("KomixAPI:request error", tostring(err), "URL:", url)
        return nil, err
    end

    if res.code < 200 or res.code >= 300 then
        logger.warn("KomixAPI:request bad status", tostring(res.code), "URL:", url)
        if res.body then logger.dbg("Response body:", string.sub(res.body, 1, 500)) end
        return nil, "Server returned status " .. (res.code or "unknown")
    end

    if res.code == 204 then return true end

    local parsed, result = pcall(function()
        return JSON.decode(res.body)
    end)
    if not parsed then
        logger.warn("KomixAPI:request failed to parse JSON from", url, "error:", tostring(result))
        return nil, "JSON parsing failed: " .. tostring(result)
    end
    return result
end

-- Check server credentials & connect (handles both v1 and v2 API versions)
function KomixAPI:ping()
    local result, err = self:request("/api/v2/users/me")
    if not result then
        -- Fallback to v1 for older Komga instances
        result, err = self:request("/api/v1/users/me")
    end
    if not result then
        return false, err
    end
    return true, result
end

-- Get all Libraries
function KomixAPI:get_libraries()
    return self:request("/api/v1/libraries")
end

-- Search books by filename or metadata, optionally filtered by series_id
function KomixAPI:search_books(filename, series_id)
    local query = "search=" .. escape_uri(filename)
    if series_id then
        query = query .. "&series_id=" .. escape_uri(series_id)
    end
    return self:request("/api/v1/books?" .. query)
end

-- Retrieve user progress for a book
function KomixAPI:get_read_progress(book_id)
    local book, err = self:request("/api/v1/books/" .. book_id)
    if not book then
        return nil, err
    end
    return book.readProgress
end

-- Update read progress on Komga
function KomixAPI:patch_read_progress(book_id, page, completed)
    local payload = {
        page = page,
        completed = completed or false
    }
    return self:request("/api/v1/books/" .. book_id .. "/read-progress", "PATCH", payload)
end

-- Get series, optionally filtered by library
function KomixAPI:get_series(library_id, page, size)
    local params = {}
    if library_id then table.insert(params, "library_id=" .. escape_uri(library_id)) end
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    return self:request("/api/v1/series" .. build_query(params))
end

-- Get a single series (used for the series-summary metadata fallback)
function KomixAPI:get_series_by_id(series_id)
    return self:request("/api/v1/series/" .. escape_uri(series_id))
end

-- Search series by name or query. Optional page/size and sort (e.g.
-- "metadata.titleSort,asc").
function KomixAPI:search_series(query, page, size, sort)
    local params = {}
    if query and query ~= "" then table.insert(params, "search=" .. escape_uri(query)) end
    if sort then table.insert(params, "sort=" .. escape_uri(sort)) end
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    return self:request("/api/v1/series" .. build_query(params))
end

function KomixAPI:get_books_for_series(series_id, filters, page, size)
    local encoded_id = escape_uri(series_id)
    local params = {}
    if filters then
        if filters.read_status then
            if type(filters.read_status) == "table" then
                for _, status in ipairs(filters.read_status) do
                    table.insert(params, "read_status=" .. escape_uri(status))
                end
            else
                table.insert(params, "read_status=" .. escape_uri(filters.read_status))
            end
        end
        if filters.sort then table.insert(params, "sort=" .. escape_uri(filters.sort)) end
    end
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    return self:request("/api/v1/series/" .. encoded_id .. "/books" .. build_query(params))
end

function KomixAPI:get_books(filters, page, size)
    local params = {}
    if filters then
        if filters.read_status then
            if type(filters.read_status) == "table" then
                for _, status in ipairs(filters.read_status) do
                    table.insert(params, "read_status=" .. escape_uri(status))
                end
            else
                table.insert(params, "read_status=" .. escape_uri(filters.read_status))
            end
        end
        if filters.sort then table.insert(params, "sort=" .. escape_uri(filters.sort)) end
    end
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    return self:request("/api/v1/books" .. build_query(params))
end

function KomixAPI:get_books_ondeck(page, size)
    local params = {}
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    return self:request("/api/v1/books/ondeck" .. build_query(params))
end

function KomixAPI:get_new_series(page, size)
    local params = {}
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    return self:request("/api/v1/series/new" .. build_query(params))
end

-- One-shot series (series made of a single book). The modern endpoint is the
-- POST /api/v1/series/list search; older servers still accept the GET filter.
function KomixAPI:get_oneshot_series(page, size)
    local params = {}
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    local q = build_query(params)

    local result = self:request("/api/v1/series/list" .. q, "POST", { oneshot = true })
    if result then return result end

    local fallback_params = {}
    table.insert(fallback_params, "oneshot=true")
    if page then table.insert(fallback_params, "page=" .. tostring(page)) end
    if size then table.insert(fallback_params, "size=" .. tostring(size)) end
    return self:request("/api/v1/series" .. build_query(fallback_params))
end

-- Collections
function KomixAPI:get_collections(page, size)
    local params = {}
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    return self:request("/api/v1/collections" .. build_query(params))
end

function KomixAPI:get_collection_series(collection_id, page, size)
    local params = {}
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    return self:request("/api/v1/collections/" .. escape_uri(collection_id) .. "/series" .. build_query(params))
end

-- Read lists
function KomixAPI:get_readlists(page, size)
    local params = {}
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    return self:request("/api/v1/readlists" .. build_query(params))
end

function KomixAPI:get_readlist_books(readlist_id, page, size)
    local params = {}
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    return self:request("/api/v1/readlists/" .. escape_uri(readlist_id) .. "/books" .. build_query(params))
end

-- Get the next book in the series after book_id (404 = no next book → returns nil)
function KomixAPI:get_next_book(book_id)
    return self:request("/api/v1/books/" .. escape_uri(book_id) .. "/next")
end

-- Best-effort size in bytes of a book file via a HEAD request; nil if unknown.
function KomixAPI:get_file_size(book_id)
    local url = self.base_url .. "/api/v1/books/" .. escape_uri(book_id) .. "/file"
    local headers = self:get_headers()
    headers["Accept"] = nil
    local res = perform_request({
        url = url,
        method = "HEAD",
        headers = headers,
        timeout = self.timeouts.block or 10,
    })
    if res and res.headers then
        local len = res.headers["content-length"] or res.headers["Content-Length"]
        local n = tonumber(len)
        if n and n > 0 then return n end
    end
    return nil
end

-- Download a book file. Retries transient failures (reopening the sink each
-- attempt). on_progress(downloaded_bytes) is called as data arrives.
function KomixAPI:download_book(book_id, dest_filepath, on_progress)
    local url = self.base_url .. "/api/v1/books/" .. book_id .. "/file"
    local headers = self:get_headers()
    headers["Accept"] = nil

    local to_file = dest_filepath ~= nil
    local start_time = os.time()

    local function attempt()
        local file, sink
        if to_file then
            local ferr
            file, ferr = io.open(dest_filepath, "wb")
            if not file then
                return nil, "Failed to open file for writing: " .. tostring(ferr)
            end
            sink = ltn12.sink.file(file)
            if on_progress then
                -- Byte counter chained onto the file sink (best-effort: older
                -- builds may lack it, the download still works without it).
                local ok, socketutil = pcall(require, "socketutil")
                if ok and socketutil and socketutil.chainSinkWithProgressCallback then
                    sink = socketutil.chainSinkWithProgressCallback(sink, on_progress)
                end
            end
        end
        local res, req_err = perform_request({
            url = url,
            method = "GET",
            headers = headers,
            sink = sink,
            timeout = self.timeouts.block or 120,
        })
        if file then pcall(file.close, file) end
        return res, req_err
    end

    local res, req_err = Retry.run(attempt, {
        attempts = self.retry_attempts,
        should_retry = should_retry,
        sleep = self.sleep,
        on_retry = function(next_attempt, attempts)
            if self.on_retry and self.on_retry(next_attempt, attempts) == false then
                return false
            end
            -- Best-effort total timeout: stop retrying past the deadline.
            local total = self.timeouts.total
            if total and total > 0 and (os.time() - start_time) >= total then
                return false
            end
            return true
        end,
    })

    if not res then
        logger.err("KomixAPI:download_book request failed", tostring(req_err), "URL:", url)
        if dest_filepath then os.remove(dest_filepath) end
        return nil, req_err
    end
    if res.code < 200 or res.code >= 300 then
        logger.err("KomixAPI:download_book bad status", tostring(res.code), "URL:", url)
        if dest_filepath then os.remove(dest_filepath) end
        return nil, "Server error " .. res.code
    end
    return to_file and true or res.body
end

-- Helper for downloading images without JSON Accept headers
function KomixAPI:download_image(path)
    local url = self.base_url .. path
    local headers = self:get_headers()
    headers["Accept"] = "image/jpeg, image/png, image/*"
    headers["Content-Type"] = nil

    local res, err = perform_request({
        url = url,
        method = "GET",
        headers = headers,
        timeout = self.timeouts.block or 10,
    })

    if not res or res.code < 200 or res.code >= 300 then
        return nil, "Failed to download image"
    end

    return res.body
end

-- Download raw series thumbnail/poster
function KomixAPI:download_series_thumbnail(series_id)
    return self:download_image("/api/v1/series/" .. escape_uri(series_id) .. "/thumbnail")
end

-- Download raw book thumbnail
function KomixAPI:download_book_thumbnail(book_id)
    return self:download_image("/api/v1/books/" .. escape_uri(book_id) .. "/thumbnail")
end

-- Download raw read list thumbnail/poster
function KomixAPI:download_readlist_thumbnail(readlist_id)
    return self:download_image("/api/v1/readlists/" .. escape_uri(readlist_id) .. "/thumbnail")
end

function KomixAPI:set_basic_auth(username, password)
    if username and password then
        local creds = username .. ":" .. password
        self.auth_header = "Basic " .. encode_base64(creds)
    else
        self.auth_header = nil
    end
end

function KomixAPI:generate_api_key(comment)
    local payload = {
        comment = comment or "KOReader Client"
    }
    return self:request("/api/v2/users/me/api-keys", "POST", payload)
end

return KomixAPI
