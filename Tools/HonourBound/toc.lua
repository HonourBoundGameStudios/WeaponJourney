-- HonourBound.Toc -- what a .toc promises, and whether the files behind it keep the promise.
-- A module missing from the .toc silently never loads; a typo in a file the client alone loads
-- reaches the game. Both are cheap to catch under plain `lua`.

local Toc = {}

-- Parse .toc text. Strips a UTF-8 BOM and the CR of CRLF (invisible, and either would turn a real
-- filename into one that does not exist). Directives (## ...) and comments are not files.
function Toc.parse(text)
    local files, order, interface = {}, {}, nil
    text = text:gsub("^\239\187\191", "")
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("\r$", ""):match("^%s*(.-)%s*$")
        if line:sub(1, 2) == "##" then
            interface = interface or tonumber(line:match("^##%s*Interface%s*:%s*(%d+)"))
        elseif line ~= "" and line:sub(1, 1) ~= "#" then
            files[line] = true
            order[#order + 1] = line
        end
    end
    return { files = files, order = order, interface = interface }
end

-- major.minor.patch packs as major*10000 + minor*100 + patch. Stated as an encoding so a version and
-- its number cannot disagree silently: a transposed digit in a five-digit constant is invisible.
function Toc.encodeInterface(major, minor, patch)
    return major * 10000 + minor * 100 + patch
end

local WINDOWS = package.config:sub(1, 1) == "\\"

local function listRootLua()
    -- Some Lua builds raise (rather than return nil) when io.popen is unavailable.
    local opened, p = pcall(io.popen, WINDOWS and "dir /b *.lua 2>nul" or "ls *.lua 2>/dev/null")
    if not opened or not p then return nil end
    local found = {}
    for name in p:lines() do
        name = name:gsub("\r$", ""):match("^%s*(.-)%s*$")
        -- `dir /b *.lua` also matches 8.3 short-name ghosts such as x.lua_bak.
        if name:match("%.lua$") then found[#found + 1] = name end
    end
    p:close()
    return found
end

-- The real filesystem, swappable for tests.
Toc.fs = {
    compiles = function(name)
        local chunk, err = loadfile(name)
        return chunk ~= nil, err
    end,
    exists = function(name)
        local f = io.open(name, "rb")
        if f then f:close() end
        return f ~= nil
    end,
    rootLua = listRootLua,
}

-- Assert on harness `h`: every listed file exists (a .lua must also compile -- other kinds, such as
-- .xml, are only checked for existence); every module at the project root is listed. WoW writes
-- paths with backslashes; they are folded to / for the filesystem. `fs` defaults to the real one.
function Toc.check(h, parsed, label, fs)
    fs = fs or Toc.fs
    for _, name in ipairs(parsed.order) do
        local path = name:gsub("\\", "/")
        if path:match("%.[Ll][Uu][Aa]$") then
            local good, err = fs.compiles(path)
            h.ok(good, name .. " exists and compiles" .. (good and "" or ": " .. tostring(err)))
        else
            h.ok(fs.exists(path), name .. " exists")
        end
    end
    local root = fs.rootLua()
    if not root then
        h.note("skipped: no io.popen, cannot list the project root")
        return
    end
    for _, name in ipairs(root) do
        h.ok(parsed.files[name] == true, name .. " is listed in " .. label)
    end
end

return Toc
