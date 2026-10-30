-- Board tests: placement and orientation, Go rules on the device engine,
-- the tree-driven play (right / wrong / solved), undo, hint, solution
-- display and the serialize/load round trip.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

local Board = require("board")

-- Straight three in the corner, Black to kill: the centre (ba) is the only
-- move; White's best try after it (aa or ca) is irrelevant -- it is settled.
-- The tree is hand-written here only to drive the board; the real bank's
-- trees are proven in test_bank_spec.lua.
local function straightThree(id)
    return {
        id = id or 8, kind = "kill", level = 1,
        rows = { "...O#", "OOOO#", "#####" },
        tree = { m = "ba", d = 1, w = { ba = 1 }, l = { aa = "ba", ca = "ba" } },
    }
end

-- A two-move line, to exercise White's answers and undo.
local function twoStep(id)
    return {
        id = id or 16, kind = "kill", level = 2,
        rows = { "....O#", "OOOOO#", "######" },
        tree = {
            m = "ba", d = 2,
            w = { ba = { r = "da", n = { m = "ca", d = 1, w = { ca = 1 }, l = { aa = "ca" } } } },
            l = { aa = "ba", ca = "ba", da = "ba" },
        },
    }
end

local function stoneAt(b, name)
    local r, c = b:pointOf(name)
    return b.grid[r][c]
end

describe("TsumegoBoard", function()
    describe("placement", function()
        it("maps frame points to the board and back in all eight orientations", function()
            for orient = 0, 7 do
                local b = Board:new(straightThree(orient))
                assert.are.equal(orient, b.orient)
                for fr = 1, b.FR do
                    for fc = 1, b.FC do
                        local r, c = b:toBoard(fr, fc)
                        assert.is_true(r >= 1 and r <= 19 and c >= 1 and c <= 19)
                        local fr2, fc2 = b:toFrame(r, c)
                        assert.are.equal(fr, fr2)
                        assert.are.equal(fc, fc2)
                    end
                end
            end
        end)

        it("always puts the frame's corner on a board corner", function()
            for orient = 0, 7 do
                local b = Board:new(straightThree(orient))
                local r, c = b:toBoard(1, 1)
                assert.is_true((r == 1 or r == 19) and (c == 1 or c == 19))
            end
        end)

        it("sets up walls in the attacker's colour and the region inside them", function()
            local b = Board:new(straightThree(0))
            assert.are.equal(Board.BLACK, b.grid[1][5])        -- wall
            assert.are.equal(Board.WHITE, b.grid[1][4])
            assert.is_true(b:isInRegion(1, 1))
            assert.is_false(b:isInRegion(1, 5))                -- wall
            assert.is_false(b:isInRegion(5, 5))                -- outside
            local live = straightThree(0)
            live.kind = "live"
            assert.are.equal(Board.WHITE, Board:new(live).grid[1][5])
        end)

        it("crops a window inside the board that holds the frame", function()
            for orient = 0, 7 do
                local b = Board:new(straightThree(orient))
                local crop = b:getCrop()
                assert.is_true(crop.top >= 1 and crop.bottom <= 19 and crop.left >= 1 and crop.right <= 19)
                for fr = 1, b.FR do
                    for fc = 1, b.FC do
                        local r, c = b:toBoard(fr, fc)
                        assert.is_true(r >= crop.top and r <= crop.bottom and c >= crop.left and c <= crop.right)
                    end
                end
            end
        end)
    end)

    describe("play", function()
        it("solves on the correct move", function()
            local b = Board:new(straightThree(0))
            local r, c = b:pointOf("ba")
            assert.are.equal("solved", b:play(r, c))
            assert.are.equal("solved", b.status)
            assert.are.same({ "ba" }, b.history)
        end)

        it("answers a wrong move with the refutation and fails", function()
            local b = Board:new(straightThree(0))
            local r, c = b:pointOf("aa")
            assert.are.equal("wrong", b:play(r, c))
            assert.are.equal("failed", b.status)
            assert.are.equal(Board.WHITE, stoneAt(b, "ba"))
            -- White's ba captured the lone Black stone at aa.
            assert.are.equal(Board.EMPTY, stoneAt(b, "aa"))
            assert.are.equal("ended", b:play(b:pointOf("ca")))
        end)

        it("refuses points outside the region and occupied points", function()
            local b = Board:new(straightThree(0))
            assert.are.equal("outside", b:play(10, 10))
            assert.are.equal("outside", b:play(b:pointOf("ea")))   -- wall
            assert.are.equal("occupied", b:play(b:pointOf("da")))
            assert.are.equal("playing", b.status)
        end)

        it("plays White's answer and moves to the next node", function()
            local b = Board:new(twoStep(0))
            assert.are.equal("correct", b:play(b:pointOf("ba")))
            assert.are.equal(Board.WHITE, stoneAt(b, "da"))
            assert.are.equal("ca", b.node.m)
            local lr, lc = b:pointOf("da")
            assert.are.same({ r = lr, c = lc }, b.last_move)
            assert.are.equal("solved", b:play(b:pointOf("ca")))
        end)
    end)

    describe("Go rules on the board", function()
        it("captures and forbids suicide", function()
            local b = Board:new(straightThree(0))
            -- A Black stone surrounded on the edge is captured.
            b.grid[10][1] = Board.BLACK
            b.grid[9][1], b.grid[10][2] = Board.WHITE, Board.WHITE
            assert.is_true(b:_place(11, 1, Board.WHITE))
            assert.are.equal(Board.EMPTY, b.grid[10][1])
            -- Black may not fill the point it just lost: no liberty.
            assert.is_false(b:_place(10, 1, Board.BLACK))
        end)

        it("forbids retaking a ko at once", function()
            local b = Board:new(straightThree(0))
            local g = b.grid
            -- Classic ko on the left edge around (11,1)/(11,2).
            g[10][1], g[12][1], g[11][2] = Board.BLACK, Board.BLACK, Board.BLACK
            g[10][2], g[12][2], g[11][3] = Board.WHITE, Board.WHITE, Board.WHITE
            assert.is_true(b:_place(11, 1, Board.WHITE))       -- takes (11,2)
            assert.are.equal(Board.EMPTY, b.grid[11][2])
            assert.is_false(b:_place(11, 2, Board.BLACK))      -- immediate retake
        end)
    end)

    describe("undo and retry", function()
        it("takes back Black's move with White's answer", function()
            local b = Board:new(twoStep(0))
            b:play(b:pointOf("ba"))
            assert.is_true(b:undo())
            assert.are.equal(Board.EMPTY, stoneAt(b, "ba"))
            assert.are.equal(Board.EMPTY, stoneAt(b, "da"))
            assert.are.equal(b.problem.tree, b.node)
            assert.is_false(b:undo())
        end)

        it("undoes a failed attempt back to playing", function()
            local b = Board:new(straightThree(0))
            b:play(b:pointOf("aa"))
            assert.is_true(b:undo())
            assert.are.equal("playing", b.status)
            assert.are.equal("solved", b:play(b:pointOf("ba")))
        end)
    end)

    describe("hint", function()
        it("offers the node's main move, which is correct", function()
            local b = Board:new(twoStep(0))
            local step = b:findHint()
            assert.are.equal("ba", step.name)
            b:setSelection(step.r, step.c)
            assert.are.same({ r = step.r, c = step.c }, b.hint_mark)
            assert.is_true(b:applyHint(step))
            assert.is_nil(b.hint_mark)
            assert.are.equal("ca", b:findHint().name)
        end)

        it("has nothing to offer once the problem is over", function()
            local b = Board:new(straightThree(0))
            b:play(b:pointOf("ba"))
            local step, reason = b:findHint()
            assert.is_nil(step)
            assert.are.equal("complete", reason)
        end)

        it("counts hints", function()
            local b = Board:new(straightThree(0))
            assert.are.equal(0, b:getHintsUsed())
            b:noteHintUsed()
            assert.are.equal(1, b:getHintsUsed())
        end)
    end)

    describe("solution", function()
        it("lists the main line and numbers it on the board", function()
            local b = Board:new(twoStep(0))
            assert.are.same({ "ba", "da", "ca" }, b:mainLine())
            b:showSolution()
            assert.is_true(b:isShowingSolution())
            assert.are.equal("shown", b.status)
            local r, c = b:pointOf("da")
            assert.are.equal(2, b.solution_labels[r * 100 + c])
            assert.are.equal(Board.WHITE, b.grid[r][c])
            b:reset()
            assert.is_false(b:isShowingSolution())
        end)
    end)

    describe("persistence", function()
        it("round-trips a game in progress", function()
            local p = twoStep(5)
            local b = Board:new(p)
            b:play(b:pointOf("ba"))
            b:noteHintUsed()
            local data = b:serialize()
            local b2 = Board:new(p)
            assert.is_true(b2:load(data))
            assert.are.same(b.grid, b2.grid)
            assert.are.same(b.history, b2.history)
            assert.are.equal(b.node, b2.node)
            assert.are.equal(1, b2:getHintsUsed())
        end)

        it("round-trips a failed attempt and a shown solution", function()
            local p = straightThree(3)
            local b = Board:new(p)
            b:play(b:pointOf("ca"))
            local b2 = Board:new(p)
            assert.is_true(b2:load(b:serialize()))
            assert.are.equal("failed", b2.status)
            b:showSolution()
            local b3 = Board:new(p)
            assert.is_true(b3:load(b:serialize()))
            assert.is_true(b3:isShowingSolution())
        end)

        it("rejects a save from another problem or with bad moves", function()
            local b = Board:new(straightThree(3))
            assert.is_false(b:load({ id = 99, history = {} }))
            assert.is_false(b:load({ id = 3, history = { "ea" } }))
            assert.is_false(b:load(nil))
            assert.are.equal("playing", b.status)
        end)
    end)
end)
