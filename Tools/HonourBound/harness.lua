-- HonourBound.TestHarness -- minimal TAP-ish test harness for pure-Lua addon code.
-- Runs outside the WoW client under plain `lua` (5.1, the client's own version), so the logic that
-- decides things is observable without the game.
--
--   local H = dofile("Tools/HonourBound/harness.lua")
--   H.start("name"); H.ok(cond, msg); H.eq(got, want, msg); H.near(got, want, msg); H.done()
--
-- H.done() exits 1 if anything failed (CI-friendly) and returns normally otherwise, so the coverage
-- tool can run many suites in one process. H.new{ print=, exit= } builds an isolated instance whose
-- output and exit go to the injected functions -- that is how the harness tests itself.

local function new(opts)
    opts = opts or {}
    local out = opts.print or print
    local quit = opts.exit or os.exit
    local H = { passed = 0, failed = 0, name = "tests" }

    local function record(good, msg)
        msg = tostring(msg)
        if good then H.passed = H.passed + 1 else H.failed = H.failed + 1 end
        out(string.format("  %s %d - %s", good and "ok" or "NOT OK", H.passed + H.failed, msg))
    end

    function H.ok(cond, msg) record(cond and true or false, msg) end

    function H.eq(got, want, msg)
        if got == want then
            record(true, msg)
        else
            record(false, string.format("%s (got %s, want %s)", tostring(msg), tostring(got), tostring(want)))
        end
    end

    -- Equality to a hair's width, for numbers that arrive by two arithmetic routes: H.eq demands the
    -- exact bit pattern, which two algebraically equal float expressions need not share.
    function H.near(got, want, msg, tol)
        tol = tol or 1e-6
        if type(got) == "number" and type(want) == "number" and math.abs(got - want) <= tol then
            record(true, msg)
        else
            record(false, string.format("%s (got %s, want %s +/- %s)", tostring(msg), tostring(got), tostring(want),
                tostring(tol)))
        end
    end

    -- Run fn under pcall; expect it to raise (guard-clause checks).
    function H.errors(fn, msg) H.ok(not pcall(fn), msg) end

    -- A comment line (e.g. "skipped: ..."), through the same sink as everything else.
    function H.note(msg) out("  # " .. tostring(msg)) end

    function H.start(name)
        H.name = name
        out("# " .. name)
    end

    function H.done()
        out(string.format("# %s: %d passed, %d failed", H.name, H.passed, H.failed))
        if H.failed > 0 then quit(1) end
    end

    return H
end

local default = new()
default.new = new
return default
