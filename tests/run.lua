-- Run from the repository root: lua tests/run.lua [suite [case]]
local H = dofile("tests/helpers.lua")
for _, suite in ipairs({ "history", "detector", "goals", "integrations" }) do
    if not arg[1] or arg[1] == suite then
        assert(loadfile("tests/" .. suite .. ".lua"))(H)
    end
end
assert(H.passed > 0, "no matching tests")
print(string.format("%d regression cases passed", H.passed))
