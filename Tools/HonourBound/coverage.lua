-- HonourBound.Coverage -- offline line + function coverage for pure-Lua modules.
-- Runs every Tests/*_test.lua in-process under a line hook, then reports per target file.
--
--   lua Tools/HonourBound/coverage.lua [--tests DIR] Target1.lua Target2.lua ...   (from project root)
--
-- WoW-only files (frames, events) are not targets; they are verified in the client. An option it does
-- not know is refused, never ignored: silently dropping one hands back a plausible wrong number.

local Coverage = {}

local LONE = {
    ["end"] = true, ["else"] = true, ["do"] = true, ["then"] = true,
    ["end,"] = true, ["end)"] = true, ["end);"] = true, ["})"] = true,
    ["}"] = true, ["},"] = true, ["{"] = true, ["),"] = true, [")"] = true,
}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- A physical line is executable unless blank, a comment, a lone structural token the VM never
-- attributes a line event to, or a function header (counted by function coverage instead).
-- Conservative: ambiguous lines stay in the denominator.
function Coverage.isExecutable(t)
    t = trim(t)
    if t == "" or t:sub(1, 2) == "--" or LONE[t] then return false end
    if t:match("^function%s") or t:match("^local%s+function%s") then return false end
    return true
end

-- One spelling per file, so a target and a chunk name compare equal: forward slashes, no @, no ./
function Coverage.normPath(p)
    p = p:gsub("^@", ""):gsub("\\", "/")
    while p:sub(1, 2) == "./" do p = p:sub(3) end
    return p
end

-- {1,2,3,7} -> "1-3, 7"
function Coverage.ranges(missed)
    local parts, i = {}, 1
    while i <= #missed do
        local a, b = missed[i], missed[i]
        while missed[i + 1] == b + 1 do
            i = i + 1
            b = missed[i]
        end
        parts[#parts + 1] = (a == b) and tostring(a) or (a .. "-" .. b)
        i = i + 1
    end
    return table.concat(parts, ", ")
end

-- lines: array of source lines; fileHits: set of executed line numbers.
function Coverage.analyse(lines, fileHits)
    local r = { exec = 0, hit = 0, fns = 0, fnsHit = 0, missed = {} }
    for n, raw in ipairs(lines) do
        local t = trim(raw)
        local header = t:match("^function%s+[%w_%.:]+") or t:match("^local%s+function%s+[%w_]+")
        if header and not t:match("%send[%s,;%)]*$") then -- a one-liner has no body line to judge by
            r.fns = r.fns + 1
            -- Only the first executable body line says the function RAN: in Lua 5.1 the header line
            -- fires when the module loads (the closure is built there), call or no call.
            local covered = false
            for m = n + 1, math.min(n + 12, #lines) do
                if Coverage.isExecutable(lines[m]) then
                    covered = fileHits[m] and true or false
                    break
                end
            end
            if covered then r.fnsHit = r.fnsHit + 1 end
        end
        if Coverage.isExecutable(t) then
            r.exec = r.exec + 1
            if fileHits[n] then r.hit = r.hit + 1 else r.missed[#r.missed + 1] = n end
        end
    end
    return r
end

function Coverage.parseArgs(argv)
    local args, i, sawTests = { targets = {}, testsDir = "Tests" }, 1, false
    while i <= #argv do
        local a = argv[i]
        if a == "--tests" then
            local dir = argv[i + 1]
            if not dir or dir:sub(1, 2) == "--" then
                args.error = "--tests needs a directory"
                return args
            end
            if sawTests then
                args.error = "--tests given twice"
                return args
            end
            sawTests, args.testsDir = true, dir
            i = i + 1
        elseif a:sub(1, 2) == "--" then
            args.error = "unknown option " .. a
            return args
        else
            args.targets[#args.targets + 1] = a
        end
        i = i + 1
    end
    if #args.targets == 0 then args.error = "no target files given" end
    return args
end

local WINDOWS = package.config:sub(1, 1) == "\\"

local function listTests(dir)
    local out = {}
    local function collect(cmd, prefix)
        local opened, p = pcall(io.popen, cmd) -- some builds raise when popen is unavailable
        if not opened or not p then return end
        for line in p:lines() do
            line = line:gsub("%s+$", "")
            if line:match("_test%.lua$") then out[#out + 1] = prefix .. line end
        end
        p:close()
    end
    -- On Windows io.popen goes through cmd.exe, which has no `ls`: a bare `ls` yields zero files and
    -- the report would read "0% coverage" instead of failing. Try `dir /b`, fall back to `ls`.
    if WINDOWS then
        collect('dir /b "' .. dir .. '\\*_test.lua" 2>nul', dir .. "/")
    end
    if #out == 0 then collect('ls "' .. dir .. '"/*_test.lua 2>/dev/null', "") end
    table.sort(out)
    return out
end

-- Run the suites under a line hook and print the report; returns the process exit code.
function Coverage.run(argv)
    local args = Coverage.parseArgs(argv)
    if args.error then
        print("!! coverage: " .. args.error)
        print("   usage: lua Tools/HonourBound/coverage.lua [--tests DIR] Target.lua ...")
        return 2
    end
    if rawget(_G, "HB_COVERAGE_ACTIVE") then
        print("!! coverage: cannot run inside a coverage run (the line hook is single-slot)")
        return 2
    end
    local targetSet = {}
    for _, t in ipairs(args.targets) do targetSet[Coverage.normPath(t)] = true end
    local hits = {}
    local function hook(_, line)
        local info = debug.getinfo(2, "S")
        local src = info and info.source
        if not src then return end
        src = Coverage.normPath(src)
        if targetSet[src] then
            hits[src] = hits[src] or {}
            hits[src][line] = true
        end
    end

    local tests = listTests(args.testsDir)
    if #tests == 0 then
        print("!! coverage: no " .. args.testsDir .. "/*_test.lua found -- 0% here would be a discovery")
        print("   failure, not a measurement. Run from the project root.")
        return 1
    end
    print(string.format("# coverage: running %d test files under line hook\n", #tests))

    -- A suite's H.done() must not end the run, but its failure must not be lost either: record any
    -- non-zero exit and fail the run with it.
    local realExit, suiteFailed = os.exit, false
    os.exit = function(c)
        if c ~= nil and c ~= 0 and c ~= true then suiteFailed = true end
    end
    _G.HB_COVERAGE_ACTIVE = true
    debug.sethook(hook, "l")
    local errored = {}
    for _, file in ipairs(tests) do
        local ok, err = pcall(dofile, file)
        if not ok then errored[#errored + 1] = file .. ": " .. tostring(err) end
    end
    debug.sethook()
    _G.HB_COVERAGE_ACTIVE = nil
    os.exit = realExit

    local tHit, tExec, tFns, tFnsHit, code = 0, 0, 0, 0, 0
    if suiteFailed then
        print("!! coverage: at least one suite reported failures (see NOT OK above)")
        code = 1
    end
    for _, file in ipairs(args.targets) do
        local fh = io.open(file, "r")
        if not fh then
            print("!! cannot open " .. file)
            code = 1
        else
            local lines = {}
            for l in fh:lines() do lines[#lines + 1] = l end
            fh:close()
            local r = Coverage.analyse(lines, hits[Coverage.normPath(file)] or {})
            print(string.format("== %-22s  lines %3d/%-3d (%5.1f%%)   functions %2d/%-2d", file, r.hit, r.exec,
                r.exec > 0 and 100 * r.hit / r.exec or 100, r.fnsHit, r.fns))
            if #r.missed > 0 then print("   missed lines: " .. Coverage.ranges(r.missed)) end
            tHit, tExec, tFns, tFnsHit = tHit + r.hit, tExec + r.exec, tFns + r.fns, tFnsHit + r.fnsHit
        end
    end
    print(string.format("\n# TOTAL  lines %d/%d (%.1f%%)   functions %d/%d (%.1f%%)", tHit, tExec,
        tExec > 0 and 100 * tHit / tExec or 100, tFnsHit, tFns, tFns > 0 and 100 * tFnsHit / tFns or 100))
    if #errored > 0 then
        print("\n!! test files that errored under the hook:")
        for _, e in ipairs(errored) do print("   " .. e) end
        code = 1
    end
    return code
end

-- Run as a script (`lua coverage.lua ...`), not when dofile'd by a test.
-- (Not while a run is active: a suite that dofiles this module must not start a nested run.)
if arg and arg[0] and arg[0]:match("coverage%.lua$") and not rawget(_G, "HB_COVERAGE_ACTIVE") then
    os.exit(Coverage.run(arg))
end

return Coverage
