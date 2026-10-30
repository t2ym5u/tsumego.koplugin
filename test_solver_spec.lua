-- Solver tests: the rules, the static tests, and the robust outcome of
-- textbook life-and-death shapes whose answers are known from Go theory.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

local Solver = require("solver")
local B, W = Solver.BLACK, Solver.WHITE

-- Every first move of `player` (and its pass) -> "win" | "loss" | "unclear".
local function classify(rows, attacker, player)
    local g, cells = Solver.parse(rows, attacker)
    local P = Solver.newPair(g)
    local res = {}
    for _, p in ipairs(g.region) do
        if cells[p] == Solver.EMPTY then
            local c = Solver.copy(cells)
            if Solver.play(g, c, p, player, player) then
                res[Solver.name(g, p)] = Solver.outcome(P, c, 3 - player, false, player)
            end
        end
    end
    res.pass = Solver.outcome(P, cells, 3 - player, true, player)
    return res
end

local function winners(res)
    local t = {}
    for k, v in pairs(res) do
        if v == "win" then t[#t + 1] = k end
    end
    table.sort(t)
    return t
end

describe("Solver rules", function()
    it("parses walls as the attacker's stones and keeps them out of the region", function()
        local g, cells = Solver.parse({ ".O#", "OO#", "###" }, B)
        assert.are.equal(B, cells[3])
        assert.is_true(g.wall[3])
        assert.are.equal(4, #g.region)
    end)

    it("names points SGF-style and back", function()
        local g = Solver.parse({ "...#", "...#", "####" }, B)
        for _, p in ipairs(g.region) do
            assert.are.equal(p, Solver.index(g, Solver.name(g, p)))
        end
        assert.are.equal("cb", Solver.name(g, Solver.index(g, "cb")))
    end)

    it("captures a block with no liberty and undoes cleanly", function()
        local g, cells = Solver.parse({ "XO.#", ".X.#", "####" }, B)
        local before = table.concat(cells, ",")
        local p = Solver.index(g, "ca")
        local captured = Solver.play(g, cells, p, B, B)
        assert.are.equal(1, #captured)
        assert.are.equal(Solver.EMPTY, cells[Solver.index(g, "ba")])
        Solver.undo(cells, p, B, captured)
        assert.are.equal(before, table.concat(cells, ","))
    end)

    it("refuses suicide but allows a move that captures first", function()
        -- White at aa: no liberty, and both Black stones keep one at bb.
        local g, cells = Solver.parse({ ".X.#", "X..#", "####" }, W)
        assert.is_nil(Solver.play(g, cells, Solver.index(g, "aa"), W, W))
        -- Black at aa: no liberty of its own, but it takes the White stone
        -- at ba first (ab is joined to White's wall and cannot be taken).
        local g2, c2 = Solver.parse({ ".OX#", "OX.#", "####" }, W)
        local captured = Solver.play(g2, c2, Solver.index(g2, "aa"), B, B)
        assert.are.same({ Solver.index(g2, "ba") }, captured)
    end)

    it("never captures a block joined to the wall", function()
        -- The Black stone at ab touches the wall: it cannot be taken.
        local g, cells = Solver.parse({ "O..#", "XO.#", "####" }, B)
        local captured = Solver.play(g, cells, Solver.index(g, "bb"), W, W)
        -- bb is already White; play elsewhere next to ab.
        assert.is_nil(captured)
        local c2 = Solver.play(g, cells, Solver.index(g, "ba"), W, W)
        assert.are.equal(0, #c2)
        assert.are.equal(B, cells[Solver.index(g, "ab")])
    end)

    it("lets only the ko holder take a ko", function()
        -- Black at ca takes the White stone at ba and is left in atari at
        -- ba: a ko capture.
        local rows = { "XO.O#", ".XO.#", "#####" }
        local g, cells = Solver.parse(rows, B)
        local p = Solver.index(g, "ca")
        assert.is_nil(Solver.play(g, Solver.copy(cells), p, B, W))
        local captured, ko = Solver.play(g, Solver.copy(cells), p, B, B)
        assert.are.equal(1, #captured)
        assert.is_true(ko)
    end)
end)

describe("Solver static tests", function()
    it("Benson: two separate eyes are alive, one is not", function()
        local g1, c1 = Solver.parse({ ".O.O#", "OOOO#", "#####" }, B)
        assert.is_true(Solver.bensonAlive(g1, c1))
        local g2, c2 = Solver.parse({ "..OO#", "OOOO#", "#####" }, B)
        assert.is_false(Solver.bensonAlive(g2, c2))
    end)

    it("Benson: an area joined to the wall is never an eye", function()
        local g, cells = Solver.parse({ ".O.#", "OO.#", "####" }, B)
        assert.is_false(Solver.bensonAlive(g, cells))
    end)

    it("staticDead: everything touches a safe attacker stone", function()
        local g, cells = Solver.parse({ ".X#", "XX#", "###" }, B)
        assert.is_true(Solver.staticDead(g, cells))
        local g2, c2 = Solver.parse({ "...O#", "OOOO#", "#####" }, B)
        assert.is_false(Solver.staticDead(g2, c2))
    end)

    it("deadForever: no room left for two eyes", function()
        local g, cells = Solver.parse({ "..O#", "OOO#", "####" }, B)
        assert.is_true(Solver.deadForever(g, cells))     -- two adjacent points
        local g2, c2 = Solver.parse({ ".O.O#", "OOOO#", "#####" }, B)
        assert.is_false(Solver.deadForever(g2, c2))      -- two eyes possible
    end)
end)

describe("Solver on textbook shapes", function()
    it("straight three: the centre kills, and only the centre", function()
        local res = classify({ "...O#", "OOOO#", "#####" }, B, B)
        assert.are.same({ "ba" }, winners(res))
        assert.are.equal("loss", res.pass)
        assert.are.equal("loss", res.aa)
    end)

    it("straight three: the defender lives only at the centre", function()
        local res = classify({ "...X#", "XXXX#", "#####" }, W, B)
        assert.are.same({ "ba" }, winners(res))
        assert.are.equal("loss", res.pass)
    end)

    it("bent three in the corner: the corner point kills", function()
        local res = classify({ "..O#", ".OO#", "OO##", "####" }, B, B)
        assert.are.same({ "aa" }, winners(res))
    end)

    it("straight four is alive: no attacking move works", function()
        local res = classify({ "....O#", "OOOOO#", "######" }, B, B)
        assert.are.same({}, winners(res))
        for k, v in pairs(res) do assert.are.equal("loss", v, k) end
    end)

    it("square four is dead: no defending move helps", function()
        local res = classify({ "..O#", "..O#", "OOO#", "####" }, W, B)
        assert.are.same({}, winners(res))
        for k, v in pairs(res) do assert.are.equal("loss", v, k) end
    end)

    it("bulky five: the vital point kills", function()
        local res = classify({ "...O#", "..OO#", "OOO##", "####" .. "#" }, B, B)
        assert.are.same({ "ba" }, winners(res))
    end)

    it("bent four in the corner is a ko: unclear, never a proven kill", function()
        local g, cells = Solver.parse({ "...O#", ".OOO#", "OO###", "#####" }, B)
        local P = Solver.newPair(g)
        assert.are.equal("unclear", Solver.outcome(P, cells, B, false, B))
        -- White to play simply makes two eyes.
        assert.are.equal("win", Solver.outcome(P, cells, W, false, W))
    end)

    it("a seki is unclear for both sides", function()
        -- Black's four stones and White's group share two liberties; who
        -- fills one first loses everything, so neither can.
        local rows = { "O.XXXX.O#", "OOOOOOOO#", "#########" }
        local g, cells = Solver.parse(rows, B)
        local P = Solver.newPair(g)
        assert.are.equal("unclear", Solver.outcome(P, cells, B, false, B))
        assert.are.equal("unclear", Solver.outcome(P, cells, W, false, W))
    end)

    it("raises rather than guesses when the budget runs out", function()
        local g, cells = Solver.parse({ "...O#", "..OO#", "OOO.#", "....#", "#####" }, B)
        local S = Solver.newSearch(g, "D", 50)
        local ok, err = pcall(Solver.attackerWins, S, cells, B, false)
        assert.is_false(ok)
        assert.are.equal(Solver.BUDGET, err)
    end)
end)
