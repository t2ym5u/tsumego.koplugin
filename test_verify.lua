-- ---------------------------------------------------------------------------
-- test_verify.lua -- re-proves a problems.lua entry from scratch with
-- solver.lua. Used by test_bank_spec.lua; also runnable on its own (faster
-- under LuaJIT):
--     luajit test_verify.lua            -- every problem, prints a summary
-- Written independently of gen/gen_bank.lua: it re-derives every claim the
-- tree makes instead of reusing the generator's code paths.
-- ---------------------------------------------------------------------------

local here = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = here .. "?.lua;" .. package.path
local Solver = require("solver")

local BLACK, WHITE, EMPTY = Solver.BLACK, Solver.WHITE, Solver.EMPTY

local V = {}

local function fail(p, fmt, ...)
    error(string.format("problem %s: " .. fmt, tostring(p.id), ...), 0)
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Black wins after White moved twice in a row, whatever White's first move.
local function settled(P, g, cells)
    for _, q in ipairs(g.region) do
        if cells[q] == EMPTY then
            local c = Solver.copy(cells)
            -- White as the policy least favourable to Black lets it move:
            -- ko captures allowed.
            if Solver.play(g, c, q, WHITE, WHITE) then
                if Solver.outcome(P, c, WHITE, false, BLACK) ~= "win" then return false end
            end
        end
    end
    return true
end

-- Checks one Black-to-play node; returns the number of nodes checked.
local function checkNode(p, P, g, cells, node, is_root)
    local nodes = 1
    local legal = 0
    for _, q in ipairs(g.region) do
        if cells[q] == EMPTY then
            local name = Solver.name(g, q)
            local c = Solver.copy(cells)
            local captured, ko = Solver.play(g, c, q, BLACK, BLACK)
            if captured then
                legal = legal + 1
                if ko then fail(p, "Black could take a ko at %s", name) end
                local w, l = node.w[name], node.l[name]
                if w ~= nil and l ~= nil then fail(p, "%s both right and wrong", name) end
                if w ~= nil then
                    if Solver.outcome(P, c, WHITE, false, BLACK) ~= "win" then
                        fail(p, "%s is stored as correct but is not a proven win", name)
                    end
                    if w == 1 then
                        if not settled(P, g, c) then fail(p, "%s ends the line but is not settled", name) end
                    else
                        local r = Solver.index(g, w.r)
                        if not r or not Solver.play(g, c, r, WHITE, WHITE) then
                            fail(p, "White's answer %s to %s is illegal", w.r, name)
                        end
                        nodes = nodes + checkNode(p, P, g, c, w.n, false)
                    end
                elseif l ~= nil then
                    if Solver.outcome(P, c, WHITE, false, BLACK) ~= "loss" then
                        fail(p, "%s is stored as wrong but is not a proven loss", name)
                    end
                    if l == "" then
                        if Solver.outcome(P, c, BLACK, true, BLACK) ~= "loss" then
                            fail(p, "passing does not refute %s", name)
                        end
                    else
                        local r = Solver.index(g, l)
                        -- A refutation must hold even if Black wins every
                        -- ko: so White may not take one to refute.
                        if not r or not Solver.play(g, c, r, WHITE, BLACK) then
                            fail(p, "refutation %s of %s is illegal or a ko capture", l, name)
                        end
                        if Solver.outcome(P, c, BLACK, false, BLACK) ~= "loss" then
                            fail(p, "%s does not refute %s", l, name)
                        end
                    end
                else
                    fail(p, "legal move %s is not in the tree", name)
                end
            elseif node.w[name] ~= nil or node.l[name] ~= nil then
                fail(p, "illegal move %s is in the tree", name)
            end
        end
    end
    if count(node.w) + count(node.l) ~= legal then fail(p, "tree lists moves that are not on the board") end
    if count(node.w) == 0 then fail(p, "no correct move") end
    if node.w[node.m] == nil then fail(p, "main move %s is not a correct move", tostring(node.m)) end
    -- d = moves to the end of the main line, through the main move.
    local mw = node.w[node.m]
    local d = (mw == 1) and 1 or (1 + mw.n.d)
    if d ~= node.d then fail(p, "depth %d stored as %d", d, node.d) end
    if is_root then
        if count(node.w) ~= 1 then fail(p, "%d correct first moves", count(node.w)) end
        if Solver.outcome(P, cells, WHITE, true, BLACK) ~= "loss" then
            fail(p, "Black could pass and still succeed")
        end
    end
    return nodes
end

-- Re-proves one problem. Raises a descriptive error on any failed claim;
-- returns the number of tree nodes and of search nodes.
function V.verify(p, budget)
    if p.kind ~= "kill" and p.kind ~= "live" then fail(p, "bad kind") end
    local R, C = #p.rows, #p.rows[1]
    for r = 1, R do
        if #p.rows[r] ~= C then fail(p, "ragged rows") end
        for c = 1, C do
            local wall = (r == R or c == C)
            local is_wall = p.rows[r]:sub(c, c) == "#"
            if wall ~= is_wall then fail(p, "the wall must be exactly the last row and column") end
        end
    end
    if p.level ~= p.tree.d then fail(p, "level %d but main line %d", p.level, p.tree.d) end
    local attacker = (p.kind == "kill") and BLACK or WHITE
    local g, cells = Solver.parse(p.rows, attacker)
    local P = Solver.newPair(g, budget or 3000000)
    local nodes = checkNode(p, P, g, cells, p.tree, true)
    return nodes, P.A.nodes + P.D.nodes
end

if arg and arg[0] and arg[0]:match("test_verify%.lua$") then
    io.stdout:setvbuf("no")
    local problems = assert(loadfile(here .. "problems.lua"))()
    local t0, total, worst, worst_id = os.clock(), 0, 0, nil
    for i, p in ipairs(problems) do
        local t = os.clock()
        local nodes, search = V.verify(p)
        local dt = os.clock() - t
        total = total + nodes
        if dt > worst then worst, worst_id = dt, p.id end
        if (os.getenv("VERBOSE")) then
            print(string.format("%3d id=%d %s L%d tree=%d search=%d %.2fs", i, p.id, p.kind, p.level, nodes, search, dt))
        end
    end
    print(string.format("%d problems re-proven (%d tree nodes) in %.1fs; slowest %.2fs (id %s)",
        #problems, total, os.clock() - t0, worst, tostring(worst_id)))
end

return V
