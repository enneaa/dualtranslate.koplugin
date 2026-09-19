-- Cross-platform helpers for DualTranslate.
--
-- This module removes the plugin's dependency on external shell tools
-- (unzip, find, mkdir, rm, curl, ...) wherever KOReader provides a native
-- equivalent, so the plugin also works on Kobo, PocketBook, Android, Linux
-- and macOS, not only on Kindle:
--   * zip read/extract       -> KOReader ffi/archiver (libarchive)
--   * recursive mkdir/rmtree -> lfs (pure Lua, no shell)
--
-- All functions are side-effect-safe: every path argument is treated as a
-- plain string and never interpolated into a shell command.

local lfs = require("libs/libkoreader-lfs")
local Archiver = require("ffi/archiver")
local util = require("util")
local logger = require("logger")

local Tools = {}

-- Stable, path-safe hash used to name per-book cache directories.  The same
-- book path (and language suffix) always maps to the same directory, and the
-- digest cannot collide with user file names.
function Tools.stable_path_hash(value)
    local hash = 7
    for index = 1, #value do
        hash = (hash * 131 + value:byte(index)) % 2147483647
    end
    return string.format("%08x", hash)
end

-- Recursive mkdir.  KOReader's own util.makePath already creates missing
-- parent components; keep this thin wrapper so call sites stay unchanged.
function Tools.mkdir_p(path)
    if not path or path == "" then return false end
    return util.makePath(path) == true
end

-- Recursive delete, pure Lua. Returns true when the path no longer exists.
function Tools.rmtree(path)
    if not path or path == "" then return true end
    local mode = lfs.attributes(path, "mode")
    if not mode then return true end
    if mode == "directory" then
        local ok, iterator, state = pcall(lfs.dir, path)
        if ok and iterator then
            for name in iterator, state do
                if name ~= "." and name ~= ".." then
                    Tools.rmtree(path .. "/" .. name)
                end
            end
        end
        pcall(lfs.rmdir, path)
    else
        pcall(lfs.remove, path)
    end
    return lfs.attributes(path, "mode") == nil
end

-- Normalize a zip member name and reject absolute paths and ".." escapes.
local function safe_member(entry_path)
    local normalized = tostring(entry_path or ""):gsub("\\", "/")
    if normalized:sub(1, 1) == "/" then return nil end
    local parts = {}
    for part in normalized:gmatch("[^/]+") do
        if part == ".." then return nil end
        if part ~= "." and part ~= "" then table.insert(parts, part) end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "/")
end

-- Extract a whole zip archive into dest_dir.
-- Path-traversal safe (rejects absolute members and ".." components).
function Tools.unzip_to(archive_path, dest_dir)
    if not Tools.mkdir_p(dest_dir) then return false end
    local arc = Archiver.Reader:new()
    if not arc:open(archive_path) then
        logger.warn("dualtranslate: cannot open archive:", archive_path, tostring(arc.err))
        return false
    end
    local ok, err = pcall(function()
        for entry in arc:iterate() do
            local safe = safe_member(entry.path)
            if safe then
                local dest_path = dest_dir .. "/" .. safe
                if entry.path:sub(-1) == "/" then
                    Tools.mkdir_p(dest_path)
                else
                    local parent = dest_path:match("^(.*)/[^/]+$")
                    if parent then Tools.mkdir_p(parent) end
                    if not arc:extractToPath(entry.path, dest_path) then
                        error("extract failed: " .. tostring(entry.path)
                            .. ": " .. tostring(arc.err))
                    end
                end
            end
        end
    end)
    arc:close()
    if not ok then
        logger.warn("dualtranslate: archive extract failed:", tostring(err))
        Tools.rmtree(dest_dir)
        return false
    end
    return true
end

return Tools

