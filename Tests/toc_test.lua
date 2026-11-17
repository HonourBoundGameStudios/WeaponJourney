-- The .toc and the files it loads: every listed file exists and compiles, and every module at the
-- project root is listed (an unlisted module silently never loads).
-- Usage: lua Tests/toc_test.lua   (from the project root)
local H = dofile("Tools/HonourBound/harness.lua")
local Toc = dofile("Tools/HonourBound/toc.lua")

H.start("WeaponJourney.toc")
local f = assert(io.open("WeaponJourney.toc", "rb"))
local parsed = Toc.parse(f:read("*a"))
f:close()
Toc.check(H, parsed, "WeaponJourney.toc")
H.done()
