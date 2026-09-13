-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Ported from the komga KOReader plugin, Copyright (C) 2026 Jonathan Willian.
--[[
    Retry helper (ported from the komga plugin).
    Retries flaky network operations with exponential backoff.
--]]

local Retry = {}

Retry.DEFAULT_ATTEMPTS = 4

-- luasocket returns short string codes like "timeout"/"closed" on transport
-- failures; anything below 500 is a definitive server answer and not retried.
function Retry.transient(code)
    if type(code) ~= "number" then return true end
    return code >= 500
end

local function default_sleep(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.sleep then
        socket.sleep(seconds)
    end
end

-- run(fn, opts):
--   fn()                -> a, b            (attempt)
--   opts.should_retry(a, b) -> bool        (required)
--   opts.on_retry(next_attempt, attempts)  -> false to abort (optional)
--   opts.attempts       -> number          (default DEFAULT_ATTEMPTS)
--   opts.sleep          -> function(sec)   (default socket.sleep)
function Retry.run(fn, opts)
    opts = opts or {}
    local attempts = opts.attempts or Retry.DEFAULT_ATTEMPTS
    local sleep = opts.sleep or default_sleep
    local on_retry = opts.on_retry
    local should_retry = opts.should_retry

    local delay = 1
    local a, b
    for attempt = 1, attempts do
        a, b = fn()
        if attempt == attempts or not should_retry(a, b) then return a, b end
        if on_retry and on_retry(attempt + 1, attempts) == false then return a, b end
        sleep(delay)
        delay = delay * 2
    end
    return a, b
end

return Retry
