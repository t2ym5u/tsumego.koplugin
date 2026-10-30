-- The problem bank, checked three ways:
--   1. its structure (ids, kinds, levels, frames);
--   2. the device engine (board.lua) against the solver's engine
--      (solver.lua) along every edge of every solution tree: same legal
--      moves, same captures, same positions -- two independent
--      implementations of the rules have to agree;
--   3. a full re-proof of every claim of every tree (test_verify.lua):
--      unique first move, every stored right move a proven win, every
--      stored wrong move a proven loss with a proven refutation, every line
--      end settled -- however ko and seki are resolved.
-- (3) is slow under plain Lua (a minute or two): it is the point of the
-- bank, so it runs every time.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

local Board  = require("board")
local Bank   = require("bank")
local Solver = require("solver")
local V      = dofile(DIR .. "test_verify.lua")

local problems = assert(loadfile(DIR .. "problems.lua"))()

-- The device position, read back in frame coordinates as solver cells.
local function deviceCells(b, g)
    local cells = {}
    for fr = 1, b.FR do
        for fc = 1, b.FC do
            local r, c = b:toBoard(fr, fc)
            cells[(fr - 1) * g.C + fc] = b.grid[r][c]
        end
    end
    return cells
end

local function sameCells(a, b, g)
    for i = 1, g.N do
        if a[i] ~= b[i] then return false end
    end
    return true
end

describe("Problem bank", function()
    it("has problems at every level", function()
        local per = { 0, 0, 0 }
        for _, p in ipairs(problems) do
            local l = math.min(3, p.level)
            per[l] = per[l] + 1
        end
        assert.is_true(per[1] >= 50, "easy: " .. per[1])
        assert.is_true(per[2] >= 30, "medium: " .. per[2])
        assert.is_true(per[3] >= 10, "hard: " .. per[3])
    end)

    it("has unique ids, valid kinds and corner frames", function()
        local seen = {}
        for _, p in ipairs(problems) do
            assert.is_nil(seen[p.id], "duplicate id " .. tostring(p.id))
            seen[p.id] = true
            assert.is_true(p.kind == "kill" or p.kind == "live")
            assert.are.equal(p.level, p.tree.d)
            local R, C = #p.rows, #p.rows[1]
            for r = 1, R do
                assert.are.equal(C, #p.rows[r])
                for c = 1, C do
                    local ch = p.rows[r]:sub(c, c)
                    assert.are.equal(r == R or c == C, ch == "#", "frame of " .. p.id)
                    assert.is_truthy(("#.XO"):find(ch, 1, true))
                end
            end
        end
    end)

    it("has no duplicate positions (mirror images included)", function()
        local seen = {}
        for _, p in ipairs(problems) do
            local t = {}
            for c = 1, #p.rows[1] do
                local col = {}
                for r = 1, #p.rows do col[r] = p.rows[r]:sub(c, c) end
                t[c] = table.concat(col)
            end
            local a, b = table.concat(p.rows, "/"), table.concat(t, "/")
            local key = p.kind .. ((a < b) and a or b)
            assert.is_nil(seen[key], "duplicate of " .. tostring(seen[key]))
            seen[key] = p.id
        end
    end)

    it("plays on the device exactly as the solver proved it", function()
        local edges = 0
        for _, p in ipairs(problems) do
            local attacker = (p.kind == "kill") and Solver.BLACK or Solver.WHITE
            local g, start = Solver.parse(p.rows, attacker)
            local b = Board:new(p)

            -- history: Black's moves so far; cells: the solver's position.
            local function walk(node, history, cells)
                b:replay(history)
                assert.is_true(sameCells(deviceCells(b, g), cells, g), "position differs in " .. p.id)
                -- Same legal moves: every legal device move is judged by the
                -- tree, and nothing else is.
                for _, q in ipairs(g.region) do
                    local name = Solver.name(g, q)
                    local r, c = b:pointOf(name)
                    local judged = node.w[name] ~= nil or node.l[name] ~= nil
                    assert.are.equal(judged, b:isLegal(r, c), p.id .. " " .. name)
                end
                for name, w in pairs(node.w) do
                    edges = edges + 1
                    b:replay(history)
                    local res = b:play(b:pointOf(name))
                    local c = Solver.copy(cells)
                    assert.is_truthy(Solver.play(g, c, Solver.index(g, name), Solver.BLACK, Solver.BLACK))
                    if w == 1 then
                        assert.are.equal("solved", res, p.id .. " " .. name)
                        assert.is_true(sameCells(deviceCells(b, g), c, g))
                    else
                        assert.are.equal("correct", res, p.id .. " " .. name)
                        assert.is_truthy(Solver.play(g, c, Solver.index(g, w.r), Solver.WHITE, Solver.WHITE))
                        local h = {}
                        for i, m in ipairs(history) do h[i] = m end
                        h[#h + 1] = name
                        walk(w.n, h, c)
                    end
                end
                for name, reply in pairs(node.l) do
                    edges = edges + 1
                    b:replay(history)
                    assert.are.equal("wrong", b:play(b:pointOf(name)), p.id .. " " .. name)
                    local c = Solver.copy(cells)
                    Solver.play(g, c, Solver.index(g, name), Solver.BLACK, Solver.BLACK)
                    if reply ~= "" then
                        assert.is_truthy(Solver.play(g, c, Solver.index(g, reply), Solver.WHITE, Solver.BLACK))
                    end
                    assert.is_true(sameCells(deviceCells(b, g), c, g), "refutation differs in " .. p.id)
                end
            end
            walk(p.tree, {}, start)
        end
        assert.is_true(edges > #problems)
    end)

    it("re-proves every problem with the solver", function()
        for _, p in ipairs(problems) do
            local ok, err = pcall(V.verify, p)
            assert.is_true(ok, tostring(err))
        end
    end)

    describe("navigation", function()
        it("splits the bank into three levels covering every problem", function()
            local n = 0
            for lvl = 1, 3 do n = n + Bank.count(lvl) end
            assert.are.equal(#Bank.all(), n)
            assert.are.equal(1, Bank.clampLevel(0))
            assert.are.equal(3, Bank.clampLevel(9))
        end)

        it("walks a level in order, wrapping, and skips solved problems", function()
            local list = Bank.list(1)
            local first = Bank.nextUnsolved(1, nil, {})
            assert.are.equal(list[1], first)
            assert.are.equal(list[2], Bank.nextUnsolved(1, first, {}))
            assert.are.equal(list[1], Bank.nextUnsolved(1, list[#list], {}))
            local solved = { [Bank.key(list[2])] = true }
            assert.are.equal(list[3], Bank.nextUnsolved(1, first, solved))
            assert.are.equal(list[#list], Bank.previous(1, first))
            assert.are.equal(1, Bank.solvedCount(1, solved))
            local pos, total = Bank.position(1, list[3])
            assert.are.equal(3, pos)
            assert.are.equal(#list, total)
        end)

        it("still moves on once a whole level is solved", function()
            local list = Bank.list(3)
            local solved = {}
            for _, p in ipairs(list) do solved[Bank.key(p)] = true end
            assert.are.equal(list[2], Bank.nextUnsolved(3, list[1], solved))
            assert.are.equal(#list, Bank.solvedCount(3, solved))
        end)
    end)
end)

