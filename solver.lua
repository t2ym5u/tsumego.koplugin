-- ---------------------------------------------------------------------------
-- solver.lua -- exhaustive life-and-death solver for small enclosed regions.
--
-- This is what makes the problem bank trustworthy. It is run OFFLINE by
-- gen/gen_bank.lua to build problems.lua, and again by the tests to
-- re-verify every problem shipped in it. The device never runs it: the
-- opponent's answers on device come from the solution tree stored in
-- problems.lua (see board.lua).
--
-- A problem is a "frame": a small rectangle cut from a board corner or side,
-- given as rows of characters:
--     '.'  empty point inside the region   (playable)
--     'X'  Black stone inside the region
--     'O'  White stone inside the region
--     '#'  wall: a stone of the ATTACKER's colour bounding the region
-- The real board edge lies along the frame sides that have no wall. Points
-- beyond the frame do not exist as far as the solver is concerned: the wall
-- separates the region from them.
--
-- The model (the classic "enclosed problem" premise)
--   * Wall stones, and every attacker stone connected to them, are alive and
--     can never be captured. The defender cannot escape: it may only play
--     inside the region. Either side may pass (a pass stands for tenuki).
--   * Ordinary Go rules otherwise: captures before the suicide test, suicide
--     is illegal.
--   * The DEFENDER WINS as soon as it owns a block that is unconditionally
--     alive by Benson's algorithm (pass-alive: it survives even if the
--     defender never moves again). That is the strict, provable meaning of
--     "alive with two eyes".
--   * The ATTACKER WINS as soon as the position is statically dead, by one
--     of two rules proven next to their code (deadForever, staticDead): in
--     short, too few points are left where an eye could ever form. Anything
--     short of that is searched further.
--   * Two passes in a row end the game. What a defender who is still on the
--     board but not Benson-alive is worth then is the SEKI POLICY (below).
--
-- Ko and seki are handled conservatively, by solving under the two extreme
-- policies and only trusting results on which they agree:
--   * P_A favours the attacker: only the attacker may make a ko capture, and
--     at the end of the game a seki counts as dead.
--   * P_D favours the defender: only the defender may make a ko capture, and
--     a seki (defender still on the board at the end) counts as alive.
--   A "ko capture" is any capture of exactly one stone by a single stone left
--   with exactly one liberty (the shape that could be retaken at once). The
--   side that may not take kos may never make one; the side that may is
--   never stopped by the ko rule, since nobody can retake. That is at least as
--   good for each side as winning every ko fight with unlimited ko threats,
--   and the minimax value is monotone in each side's set of moves, so:
--     attacker wins under P_D  =>  attacker wins however ko and seki go;
--     defender wins under P_A  =>  defender wins however ko and seki go.
--   A move that is a win under one policy and a loss under the other is
--   "unclear", and a problem containing one is thrown away by the generator.
--
-- Repetition: under these policies cycles need superko shapes (triple ko,
-- sending-two-returning-one, ...). They do occur, deep in side lines after a
-- big capture. A move that returns to a position already on the current line
-- is scored as a win for the side the policy favours -- exactly like ko and
-- seki. Conclusions are only ever drawn from the policy that is UNFAVOURABLE
-- to them (an attacker win is read from P_D, a defender win from P_A), so a
-- repetition can only make a claim harder to prove, never wrong; and every
-- win that is proven rests on a finite strategy tree. (Under a superko rule a
-- move inside such a tree could in principle be barred by a position from a
-- different branch of the search -- the usual graph-history caveat of
-- transposition tables; under Japanese-style rules, which have no superko,
-- the strategy is valid as it stands.)
-- Searches carry a node budget and a depth limit and raise an error when
-- they are exceeded -- never a guessed answer.
-- ---------------------------------------------------------------------------

local Solver = {}

local EMPTY, BLACK, WHITE, OFF = 0, 1, 2, -1
Solver.EMPTY, Solver.BLACK, Solver.WHITE = EMPTY, BLACK, WHITE

-- Error values raised by a search that refuses to answer.
Solver.DEEP   = "tsumego: depth limit"
Solver.BUDGET = "tsumego: node budget"

local MAX_DEPTH = 80

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

-- rows: list of strings (see header). attacker: BLACK or WHITE.
-- Returns geom, cells. cells is a flat array indexed (r-1)*C + c.
function Solver.parse(rows, attacker)
    local R, C = #rows, #rows[1]
    local g = {
        R = R, C = C, N = R * C,
        attacker = attacker, defender = 3 - attacker,
        nb = {}, wall = {}, region = {},
        mark = {}, lmark = {}, stamp = 0, tmp = {},
    }
    local cells = {}
    for r = 1, R do
        assert(#rows[r] == C, "ragged frame")
        for c = 1, C do
            local i = (r - 1) * C + c
            local ch = rows[r]:sub(c, c)
            g.mark[i], g.lmark[i] = 0, 0
            if ch == "#" then
                cells[i] = attacker
                g.wall[i] = true
            elseif ch == "X" then cells[i] = BLACK
            elseif ch == "O" then cells[i] = WHITE
            elseif ch == "." then cells[i] = EMPTY
            else cells[i] = OFF end
            if cells[i] ~= OFF and not g.wall[i] then
                g.region[#g.region + 1] = i
            end
        end
    end
    for r = 1, R do
        for c = 1, C do
            local i = (r - 1) * C + c
            local nb = {}
            if cells[i] ~= OFF then
                local function add(rr, cc)
                    if rr >= 1 and rr <= R and cc >= 1 and cc <= C then
                        local j = (rr - 1) * C + cc
                        if cells[j] ~= OFF then nb[#nb + 1] = j end
                    end
                end
                add(r - 1, c); add(r + 1, c); add(r, c - 1); add(r, c + 1)
            end
            g.nb[i] = nb
        end
    end
    return g, cells
end

-- Back to rows (walls written as '#').
function Solver.format(g, cells)
    local out = {}
    for r = 1, g.R do
        local t = {}
        for c = 1, g.C do
            local i = (r - 1) * g.C + c
            local v = cells[i]
            if g.wall[i] then t[c] = "#"
            elseif v == BLACK then t[c] = "X"
            elseif v == WHITE then t[c] = "O"
            elseif v == EMPTY then t[c] = "."
            else t[c] = " " end
        end
        out[r] = table.concat(t)
    end
    return out
end

function Solver.copy(cells)
    local t = {}
    for i = 1, #cells do t[i] = cells[i] end
    return t
end

-- Move names: SGF-style letters, column then row, in frame coordinates
-- ("ab" = column 1, row 2). "" is a pass.
local LETTERS = "abcdefghijklmnopqrstuvwxyz"
function Solver.name(g, i)
    if not i then return "" end
    local r = math.floor((i - 1) / g.C) + 1
    local c = i - (r - 1) * g.C
    return LETTERS:sub(c, c) .. LETTERS:sub(r, r)
end

function Solver.index(g, name)
    if name == "" then return nil end
    local c = LETTERS:find(name:sub(1, 1), 1, true)
    local r = LETTERS:find(name:sub(2, 2), 1, true)
    return (r - 1) * g.C + c
end

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

-- Flood-fills the block at `start` into `stones`. Returns its size, its
-- liberty count, and whether it is invulnerable (touches the wall).
local function scanGroup(g, cells, start, stones)
    local color = cells[start]
    g.stamp = g.stamp + 1
    local st, mark, lmark, nbs, wall = g.stamp, g.mark, g.lmark, g.nb, g.wall
    local n, libs, invul = 1, 0, wall[start] or false
    stones[1] = start
    mark[start] = st
    local k = 1
    while k <= n do
        local nb = nbs[stones[k]]
        k = k + 1
        for j = 1, #nb do
            local q = nb[j]
            local v = cells[q]
            if v == EMPTY then
                if lmark[q] ~= st then lmark[q] = st; libs = libs + 1 end
            elseif v == color and mark[q] ~= st then
                mark[q] = st
                n = n + 1
                stones[n] = q
                if wall[q] then invul = true end
            end
        end
    end
    return n, libs, invul
end
Solver.scanGroup = scanGroup

local NO_CAPTURE = {}

-- Plays `color` at point p. ko_taker is the colour allowed to make ko
-- captures (see header). Returns the list of captured points (possibly
-- empty) and whether the move was a ko capture, or nil if illegal. The move
-- is left on the board: undo it with Solver.undo.
function Solver.play(g, cells, p, color, ko_taker)
    if cells[p] ~= EMPTY then return nil end
    cells[p] = color
    local opp = 3 - color
    local captured, ncap = NO_CAPTURE, 0
    local nb = g.nb[p]
    for j = 1, #nb do
        local q = nb[j]
        if cells[q] == opp then
            local stones = {}
            local n, libs, invul = scanGroup(g, cells, q, stones)
            if libs == 0 and not invul then
                if ncap == 0 then captured = {} end
                for k = 1, n do
                    cells[stones[k]] = EMPTY
                    ncap = ncap + 1
                    captured[ncap] = stones[k]
                end
            end
        end
    end
    local n, libs, invul = scanGroup(g, cells, p, g.tmp)
    local illegal = (libs == 0 and not invul)
    local ko = (ncap == 1 and n == 1 and libs == 1 and not invul)
    if illegal or (ko and ko_taker ~= color) then
        cells[p] = EMPTY
        for k = 1, ncap do cells[captured[k]] = opp end
        return nil
    end
    return captured, ko
end

function Solver.undo(cells, p, color, captured)
    cells[p] = EMPTY
    local opp = 3 - color
    for k = 1, #captured do cells[captured[k]] = opp end
end

-- ---------------------------------------------------------------------------
-- Terminal tests
-- ---------------------------------------------------------------------------

-- Benson's algorithm for the defender. Regions are maximal connected sets of
-- non-defender points; one that contains a wall stone is connected to the
-- open board beyond the wall and can never be an eye. A region is healthy
-- for a block when every empty point in it is a liberty of that block.
-- Blocks with fewer than two healthy regions (among regions enclosed only by
-- surviving blocks) are discarded until nothing changes; whatever survives is
-- unconditionally alive.
function Solver.bensonAlive(g, cells)
    local D = g.defender
    local nbs, N = g.nb, g.N
    -- Quick exit: a block needs two enclosed regions, so at least two
    -- non-defender points that cannot reach the wall without crossing a
    -- defender stone.
    g.stamp = g.stamp + 1
    local st, mark = g.stamp, g.mark
    local stack = {}
    for i = 1, N do
        if g.wall[i] then mark[i] = st; stack[#stack + 1] = i end
    end
    while #stack > 0 do
        local p = stack[#stack]
        stack[#stack] = nil
        local nb = nbs[p]
        for j = 1, #nb do
            local q = nb[j]
            if mark[q] ~= st and cells[q] ~= D then
                mark[q] = st
                stack[#stack + 1] = q
            end
        end
    end
    local enclosed = 0
    for _, i in ipairs(g.region) do
        if cells[i] ~= D and mark[i] ~= st then enclosed = enclosed + 1 end
    end
    if enclosed < 2 then return false end
    local blockOf, nblocks = {}, 0
    for i = 1, N do
        if cells[i] == D and not blockOf[i] then
            nblocks = nblocks + 1
            local stack = { i }
            blockOf[i] = nblocks
            while #stack > 0 do
                local p = table.remove(stack)
                local nb = nbs[p]
                for j = 1, #nb do
                    local q = nb[j]
                    if cells[q] == D and not blockOf[q] then
                        blockOf[q] = nblocks
                        stack[#stack + 1] = q
                    end
                end
            end
        end
    end
    if nblocks == 0 then return false end

    -- regions[k] = { adj = {block=true}, healthy = {block=true} }
    local regionOf, regions = {}, {}
    for i = 1, N do
        local v = cells[i]
        if v ~= OFF and v ~= D and not regionOf[i] then
            local k = #regions + 1
            local reg = { adj = {}, open = false, empties = {} }
            regions[k] = reg
            local stack = { i }
            regionOf[i] = k
            while #stack > 0 do
                local p = table.remove(stack)
                if g.wall[p] then reg.open = true end
                if cells[p] == EMPTY then reg.empties[#reg.empties + 1] = p end
                local nb = nbs[p]
                for j = 1, #nb do
                    local q = nb[j]
                    local w = cells[q]
                    if w == D then
                        reg.adj[blockOf[q]] = true
                    elseif not regionOf[q] then
                        regionOf[q] = k
                        stack[#stack + 1] = q
                    end
                end
            end
            reg.healthy = {}
            if not reg.open then
                for b in pairs(reg.adj) do
                    local ok = true
                    for _, e in ipairs(reg.empties) do
                        local lib = false
                        for _, q in ipairs(nbs[e]) do
                            if blockOf[q] == b then lib = true; break end
                        end
                        if not lib then ok = false; break end
                    end
                    if ok then reg.healthy[b] = true end
                end
            end
        end
    end

    local alive, enclosed = {}, {}
    for b = 1, nblocks do alive[b] = true end
    for k, reg in ipairs(regions) do enclosed[k] = not reg.open end
    local changed = true
    while changed do
        changed = false
        for k, reg in ipairs(regions) do
            if enclosed[k] then
                for b in pairs(reg.adj) do
                    if not alive[b] then enclosed[k] = false; break end
                end
            end
        end
        for b = 1, nblocks do
            if alive[b] then
                local vital = 0
                for k, reg in ipairs(regions) do
                    if enclosed[k] and reg.healthy[b] then vital = vital + 1 end
                end
                if vital < 2 then alive[b] = false; changed = true end
            end
        end
    end
    for b = 1, nblocks do
        if alive[b] then return true end
    end
    return false
end

-- Attacker stones joined to the wall (through attacker stones): these can
-- never be captured. Returns a set.
local function safeAttackers(g, cells)
    local A, nbs = g.attacker, g.nb
    local reached, stack = {}, {}
    for i = 1, g.N do
        if g.wall[i] then reached[i] = true; stack[#stack + 1] = i end
    end
    while #stack > 0 do
        local p = stack[#stack]
        stack[#stack] = nil
        local nb = nbs[p]
        for j = 1, #nb do
            local q = nb[j]
            if cells[q] == A and not reached[q] then
                reached[q] = true
                stack[#stack + 1] = q
            end
        end
    end
    return reached
end

-- True if the points in `list` contain no two non-adjacent points. (Any three
-- grid points contain such a pair, so only lists of at most two can pass.)
local function noTwoApart(g, list)
    if #list <= 1 then return true end
    if #list > 2 then return false end
    for _, q in ipairs(g.nb[list[1]]) do
        if q == list[2] then return true end
    end
    return false
end

-- The attacker's static wins. Both rest on one fact: a Benson eye (an
-- enclosed region) can only contain points that neither hold nor touch a
-- safe attacker stone -- a region holding or touching one is joined to the
-- wall. Safe stones never disappear, so that set of candidate points only
-- shrinks, and two separate eyes need two non-adjacent points of it.
--
-- deadForever (used under P_A): fewer than two non-adjacent candidate points
-- means the defender can NEVER become Benson-alive. Under P_A a seki counts
-- as dead, so the attacker simply passes from here on: the defender's own
-- moves only add stones (nobody captures them), the game ends with the
-- defender not alive, and no ko is ever involved.
--
-- staticDead (used under P_D, where the defender wins kos and a seki counts
-- as alive, so the attacker must really capture): every attacker stone in the
-- region is safe, and at most one point of the region is a candidate. The
-- attacker fills every other empty point (each touches a safe stone: never
-- suicide, never a ko); the defender's blocks are left with that one point as
-- their last liberty, and taking it captures at least two stones -- the
-- point has only defender neighbours, at least two of them -- so no ko
-- arises. If the capturing stone is then attacked, the attacker links it to a
-- safe stone before the defender can fill its two or more liberties.
function Solver.deadForever(g, cells)
    local safe = safeAttackers(g, cells)
    local cand = {}
    for _, i in ipairs(g.region) do
        if not safe[i] then
            local touches = false
            for _, q in ipairs(g.nb[i]) do
                if safe[q] then touches = true; break end
            end
            if not touches then
                cand[#cand + 1] = i
                if #cand > 2 then return false end
            end
        end
    end
    return noTwoApart(g, cand)
end

function Solver.staticDead(g, cells)
    local A = g.attacker
    local safe = safeAttackers(g, cells)
    local cand = 0
    for _, i in ipairs(g.region) do
        if cells[i] == A then
            if not safe[i] then return false end
        else
            local touches = false
            for _, q in ipairs(g.nb[i]) do
                if cells[q] == A then touches = true; break end
            end
            if not touches then
                cand = cand + 1
                if cand > 1 then return false end
            end
        end
    end
    return true
end

local function hasDefender(g, cells)
    local D = g.defender
    for _, i in ipairs(g.region) do
        if cells[i] == D then return true end
    end
    return false
end
Solver.hasDefender = hasDefender

-- ---------------------------------------------------------------------------
-- Search
--
-- Depth-first AND/OR search with a transposition table, run by iterative
-- deepening with three-valued results: when the depth runs out a node is
-- UNKNOWN, never guessed. Shallow proofs are therefore found first, and a
-- blunder (giving the whole group away, say) is refuted in a few plies
-- instead of being searched to the bottom of what follows it. The answer is
-- exact: a node is only declared lost once every move has been proven to
-- lose, and the root is only answered once it is proven.
-- ---------------------------------------------------------------------------

-- Policy names (see header).
Solver.P_A = "A"
Solver.P_D = "D"

-- A search object keeps its transposition table across queries, so all the
-- questions asked about one problem under one policy share their work.
function Solver.newSearch(g, policy, budget)
    assert(policy == "A" or policy == "D")
    return {
        g          = g,
        policy     = policy,
        ko_taker   = (policy == "A") and g.attacker or g.defender,
        seki_alive = (policy == "D"),
        tt         = {},   -- key -> true/false (proven) or depth searched (unknown)
        path       = {},
        nodes      = 0,
        budget     = budget or 3000000,
    }
end

local function keyOf(g, cells, color, passed)
    local t = {}
    local region = g.region
    for k = 1, #region do t[k] = cells[region[k]] end
    t[#t + 1] = passed and (color + 4) or color
    return table.concat(t)
end

-- Labels every block once: blockOf[i] = block id; size/libs/invul per id.
local function analyze(g, cells)
    local blockOf, size, libs, invul = {}, {}, {}, {}
    local nbs, wall = g.nb, g.wall
    g.stamp = g.stamp + 1
    local nblocks = 0
    for i = 1, g.N do
        local color = cells[i]
        if color > 0 and not blockOf[i] then
            nblocks = nblocks + 1
            local b = nblocks
            g.stamp = g.stamp + 1
            local st, lmark = g.stamp, g.lmark
            local stack, n, l, inv = { i }, 0, 0, false
            blockOf[i] = b
            while #stack > 0 do
                local p = stack[#stack]
                stack[#stack] = nil
                n = n + 1
                if wall[p] then inv = true end
                local nb = nbs[p]
                for j = 1, #nb do
                    local q = nb[j]
                    local v = cells[q]
                    if v == EMPTY then
                        if lmark[q] ~= st then lmark[q] = st; l = l + 1 end
                    elseif v == color and not blockOf[q] then
                        blockOf[q] = b
                        stack[#stack + 1] = q
                    end
                end
            end
            size[b], libs[b], invul[b] = n, l, inv
        end
    end
    return blockOf, size, libs, invul
end

-- Candidate moves, most forcing first: captures, saving one's own block from
-- atari, ataris, contact; filling one's own eye and self-atari last. Ordering
-- only changes speed, never the answer, and it does not check legality:
-- search() plays each move and skips the illegal ones.
local function orderedMoves(S, cells, color)
    local g = S.g
    local blockOf, size, libs, invul = analyze(g, cells)
    local opp = 3 - color
    local list, score = {}, {}
    for _, p in ipairs(g.region) do
        if cells[p] == EMPTY then
            local s, captures, own_eye, empties = 0, 0, true, 0
            local seen1, seen2, seen3, seen4
            local newlibs = 0
            local nb = g.nb[p]
            for j = 1, #nb do
                local q = nb[j]
                local v = cells[q]
                if v == EMPTY then
                    empties = empties + 1
                    own_eye = false
                else
                    local b = blockOf[q]
                    if b ~= seen1 and b ~= seen2 and b ~= seen3 and b ~= seen4 then
                        if not seen1 then seen1 = b elseif not seen2 then seen2 = b
                        elseif not seen3 then seen3 = b else seen4 = b end
                        s = s + 3
                        if v == opp then
                            own_eye = false
                            if not invul[b] then
                                if libs[b] == 1 then captures = captures + size[b]
                                elseif libs[b] == 2 then s = s + 20 end
                            end
                        else
                            if libs[b] == 1 and not invul[b] then s = s + 50 end
                            newlibs = newlibs + libs[b] - 1
                            if invul[b] then newlibs = newlibs + 10 end
                        end
                    end
                end
            end
            s = s + captures * 100
            if captures == 0 then
                if newlibs + empties <= 1 then s = s - 60 end
                if own_eye then s = s - 80 end
            end
            list[#list + 1] = p
            score[p] = s
        end
    end
    table.sort(list, function(a, b)
        if score[a] ~= score[b] then return score[a] > score[b] end
        return a < b
    end)
    return list
end
Solver.orderedMoves = orderedMoves

-- true = attacker wins, false = defender wins, nil = unknown at this depth.
-- `passed`: the previous move was a pass (so a pass now ends the game).
local function search(S, cells, color, passed, depth)
    local g = S.g
    if Solver.bensonAlive(g, cells) then return false end
    if S.policy == "A" then
        if Solver.deadForever(g, cells) then return true end
    elseif Solver.staticDead(g, cells) then
        return true
    end
    local key = keyOf(g, cells, color, passed)
    local v = S.tt[key]
    if v == true or v == false then return v end
    -- A repetition is scored for the side this policy favours (see header).
    if S.path[key] then return S.policy == "A" end
    if depth <= 0 or (v and v >= depth) then return nil end
    S.nodes = S.nodes + 1
    if S.nodes > S.budget then error(Solver.BUDGET, 0) end
    S.path[key] = true

    local want = (color == g.attacker)
    local result, unknown = nil, false
    local moves = orderedMoves(S, cells, color)
    for k = 1, #moves do
        local p = moves[k]
        local captured = Solver.play(g, cells, p, color, S.ko_taker)
        if captured then
            local r = search(S, cells, 3 - color, false, depth - 1)
            Solver.undo(cells, p, color, captured)
            if r == want then result = want; break end
            if r == nil then unknown = true end
        end
    end
    if result == nil then
        local r
        if passed then
            -- Game over. Benson already failed above, so the defender only
            -- survives if a seki counts as alive under this policy.
            r = not (S.seki_alive and hasDefender(g, cells))
        else
            r = search(S, cells, 3 - color, true, depth - 1)
        end
        if r == want then result = want
        elseif r == nil then unknown = true end
    end
    if result == nil and not unknown then result = not want end

    S.path[key] = nil
    if result == nil then
        S.tt[key] = depth
    else
        S.tt[key] = result
    end
    return result
end

-- Public entry: does the attacker win this position, `color` to move?
-- Iterative deepening until the answer is proven; raises Solver.DEEP or
-- Solver.BUDGET rather than answer anything unproven. Works on a copy, so an
-- aborted search never leaves the caller's cells half-played.
function Solver.attackerWins(S, cells, color, passed)
    local work = Solver.copy(cells)
    for depth = 2, MAX_DEPTH, 2 do
        S.path = {}
        local r = search(S, work, color, passed or false, depth)
        if r ~= nil then return r end
    end
    error(Solver.DEEP, 0)
end

-- ---------------------------------------------------------------------------
-- Robust questions (the only ones the generator and the tests ask)
-- ---------------------------------------------------------------------------

-- A pair of searches for one problem: P_A and P_D.
function Solver.newPair(g, budget)
    return { g = g, A = Solver.newSearch(g, "A", budget), D = Solver.newSearch(g, "D", budget) }
end

-- Outcome for `side` (BLACK/WHITE) in this position, `to_move` to play:
-- "win" if side wins however ko, seki and repetition are resolved, "loss" if
-- it loses however they are resolved, "unclear" otherwise.
function Solver.outcome(pair, cells, to_move, passed, side)
    local g = pair.g
    if side == g.attacker then
        if Solver.attackerWins(pair.D, cells, to_move, passed) then return "win" end
        if not Solver.attackerWins(pair.A, cells, to_move, passed) then return "loss" end
    else
        if not Solver.attackerWins(pair.A, cells, to_move, passed) then return "win" end
        if Solver.attackerWins(pair.D, cells, to_move, passed) then return "loss" end
    end
    return "unclear"
end

return Solver
