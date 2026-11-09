-- Difficulty guarantees of the problem bank: a problem's level is the
-- number of Black moves its main line needs (1 Easy, 2 Medium, 3+ Hard),
-- every level is populated, and the solution trees grow with the level.
-- (Uniqueness of the first move and the soundness of every line are
-- re-proved in test_bank_spec.lua.)
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

local Bank = require("bank")

local problems = assert(loadfile(DIR .. "problems.lua"))()

-- Black moves along the main (hint) line of a tree.
local function mainLine(t)
    local w = t.w[t.m]
    assert.is_truthy(w, "main move is not a right move")
    if w == 1 then return 1 end
    return 1 + mainLine(w.n)
end

-- Black-to-play nodes in a tree (the branching the player has to read).
local function nodes(t)
    local n = 1
    for _, w in pairs(t.w) do
        if w ~= 1 then n = n + nodes(w.n) end
    end
    return n
end

describe("Tsumego difficulty", function()
    it("has problems at every level", function()
        local per = { 0, 0, 0 }
        for _, p in ipairs(problems) do
            local l = math.min(3, p.level)
            per[l] = per[l] + 1
        end
        assert.are.same({ 113, 94, 91 }, per)
    end)

    it("a problem's level is the length of its main line", function()
        for _, p in ipairs(problems) do
            assert.are.equal(p.level, p.tree.d, p.id)
            assert.are.equal(p.level, mainLine(p.tree), p.id)
        end
    end)

    it("splits the bank into three levels covering every problem", function()
        local n = 0
        for lvl = 1, 3 do n = n + Bank.count(lvl) end
        assert.are.equal(#Bank.all(), n)
        assert.are.equal(1, Bank.clampLevel(0))
        assert.are.equal(3, Bank.clampLevel(9))
    end)

    it("each level holds only its band: 1 move, 2 moves, 3 or more", function()
        local band = { { 1, 1 }, { 2, 2 }, { 3, math.huge } }
        for lvl = 1, 3 do
            for _, p in ipairs(Bank.list(lvl)) do
                local m = mainLine(p.tree)
                assert.is_true(m >= band[lvl][1] and m <= band[lvl][2], p.id)
            end
        end
    end)

    it("the levels grow on average (main line and reading nodes)", function()
        local prev_line, prev_nodes = 0, 0
        for lvl = 1, 3 do
            local list = Bank.list(lvl)
            local line, nd = 0, 0
            for _, p in ipairs(list) do
                line = line + mainLine(p.tree)
                nd = nd + nodes(p.tree)
            end
            line, nd = line / #list, nd / #list
            assert.is_true(line > prev_line, "level " .. lvl)
            assert.is_true(nd > prev_nodes, "level " .. lvl)
            prev_line, prev_nodes = line, nd
        end
    end)
end)
