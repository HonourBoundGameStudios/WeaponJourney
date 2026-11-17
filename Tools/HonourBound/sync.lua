-- HonourBound.Sync -- is a vendored copy of this kit still the kit?
-- The kit is delivered as a folder copied into each addon (WoW has no package feed). A copy drifts
-- the moment anyone edits it or the kit moves on, and a version label cannot say so. So the folder
-- carries a MANIFEST of every file's Adler-32 and size, and the check reads CONTENT, never a label.
-- Adler-32 is drift detection, not tamper-proofing.

local Sync = {}

local MOD = 65521

-- A CRLF checkout (git autocrlf) must hash like the LF original, or every Windows clone reads as
-- drifted. Only CRLF pairs fold; a lone CR is content.
function Sync.normalise(s)
    return (s:gsub("\r\n", "\n"))
end

function Sync.adler32(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % MOD
        b = (b + a) % MOD
    end
    return b * 65536 + a
end

function Sync.formatManifest(entries)
    local lines = {}
    for _, e in ipairs(entries) do
        -- Two 16-bit halves: %x on a double goes through a C long, which is 32-bit signed on some builds.
        lines[#lines + 1] = string.format("%s %04x%04x %d", e.name, math.floor(e.sum / 65536), e.sum % 65536,
            e.size)
    end
    return table.concat(lines, "\n") .. "\n"
end

function Sync.parseManifest(text)
    local entries = {}
    for name, sum, size in text:gmatch("([^%s]+) (%x+) (%d+)") do
        entries[#entries + 1] = { name = name, sum = tonumber(sum, 16), size = tonumber(size) }
    end
    return entries
end

-- Drift between `want` and `got`: stale (content differs), missing (want only), extra (got only).
function Sync.diff(want, got)
    local gotBy, wantBy, out = {}, {}, {}
    for _, e in ipairs(got) do gotBy[e.name] = e end
    for _, e in ipairs(want) do
        wantBy[e.name] = e
        local g = gotBy[e.name]
        if not g then
            out[#out + 1] = { name = e.name, kind = "missing" }
        elseif g.sum ~= e.sum or g.size ~= e.size then
            out[#out + 1] = { name = e.name, kind = "stale" }
        end
    end
    for _, e in ipairs(got) do
        if not wantBy[e.name] then out[#out + 1] = { name = e.name, kind = "extra" } end
    end
    return out
end

local WINDOWS = package.config:sub(1, 1) == "\\"

local function listDir(dir)
    local cmd = WINDOWS and ('dir /b "' .. dir:gsub("/", "\\") .. '" 2>nul') or ('ls "' .. dir .. '" 2>/dev/null')
    local opened, p = pcall(io.popen, cmd)
    local names = {}
    if opened and p then
        for name in p:lines() do
            name = name:gsub("\r$", "")
            if name ~= "" then names[#names + 1] = name end
        end
        p:close()
    end
    table.sort(names)
    return names
end

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- Entries for every file in `dir` except those named in `skip`, sorted by name.
function Sync.scan(dir, skip)
    local skipSet = {}
    for _, n in ipairs(skip or {}) do skipSet[n] = true end
    local entries = {}
    for _, name in ipairs(listDir(dir)) do
        local content = not skipSet[name] and readAll(dir .. "/" .. name)
        if content then
            local text = Sync.normalise(content)
            entries[#entries + 1] = { name = name, sum = Sync.adler32(text), size = #text }
        end
    end
    return entries
end

-- Drift of the folder `dir` against its own MANIFEST (nil + reason if there is none).
function Sync.verify(dir)
    local text = readAll(dir .. "/MANIFEST")
    if not text then return nil, "no MANIFEST in " .. dir end
    return Sync.diff(Sync.parseManifest(text), Sync.scan(dir, { "MANIFEST" }))
end

return Sync
