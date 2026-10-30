-- ---------------------------------------------------------------------------
-- gen/gen_bank.lua -- offline generator for problems.lua.
--
-- Not part of the plugin at run time. Run it with LuaJIT from anywhere:
--     luajit gen/gen_bank.lua <first_seed> <count> <out.lua> [budget] [min_level] [big]
-- then merge the outputs with gen/merge_bank.lua. Every problem it writes has
-- been proven by solver.lua:
--   * exactly ONE first move succeeds, however ko, seki and repetition are
--     resolved; every other first move -- and passing -- fails however they
--     are resolved (see solver.lua for the two policies);
--   * every node of the stored solution tree is proven the same way: each
--     winning move the player may choose is stored with the opponent's most
--     stubborn answer, each losing move with an answer that refutes it;
--   * a line ends once the result is SETTLED: the player would still win
--     even if the opponent were allowed two moves in a row;
--   * the player never has a ko capture available anywhere in the tree, so
--     the device's simple-ko rule never meets a move the tree did not judge.
-- Anything the solver cannot prove within its budget is thrown away.
-- ---------------------------------------------------------------------------

local here = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = here .. "../?.lua;" .. package.path
local Solver = require("solver")

local EMPTY = Solver.EMPTY

-- Deterministic RNG (LCG), so a seed always rebuilds the same candidate.
local function newRng(seed)
    local state = (seed * 7919 + 104729) % 2147483647
    if state == 0 then state = 1 end
    return function(n)
        state = (state * 48271) % 2147483647
        if n then return state % n + 1 end
        return state / 2147483647
    end
end

-- ---------------------------------------------------------------------------
-- Candidate shapes
--
-- Corner problems, canonical frame in the top-left corner (board edges along
-- the top and the left). Built from roles, 'A' attacker / 'D' defender:
--   * an eye space E: a staircase of column heights in the corner;
--   * the defender's shell: every region point next to E;
--   * the rest (a thin gap up to the wall): attacker stones or liberties;
-- then a few random changes (holes and cutting stones in the shell, stones
-- inside the eye space). Most candidates are rejected by the solver; the few
-- that are proven become problems.
-- ---------------------------------------------------------------------------

-- Size limits; "big" mode (gen_bank.lua ... big) raises them a little to
-- find longer problems.
local MAX_EYE, MAX_EMPTY = 7, 12

local function candidate(rng)
    local k = rng(4) + 1                      -- eye-space width, 2..5
    local heights, prev = {}, (rng() < 0.75) and rng(2) or 3
    local esize = 0
    for c = 1, k do
        local hgt = math.min(prev, rng(3))
        if rng() < 0.6 then hgt = prev end
        heights[c] = hgt
        prev = hgt
        esize = esize + hgt
    end
    -- Big eye spaces are alive whatever happens, and expensive to prove so.
    if esize > MAX_EYE then return nil end
    local h = heights[1] + ((rng() < 0.7) and 1 or 2)
    local w = k + ((rng() < 0.7) and 1 or 2)
    -- A one-column-wide frame is not a corner problem.
    if h < 2 or w < 3 then return nil end

    local role = {}
    for r = 1, h do
        role[r] = {}
        for c = 1, w do
            local inE = c <= k and r <= heights[c]
            role[r][c] = inE and "E" or "?"
        end
    end
    -- Shell: region points next to E.
    for r = 1, h do
        for c = 1, w do
            if role[r][c] == "?" then
                local adj = false
                for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
                    local rr, cc = r + d[1], c + d[2]
                    if rr >= 1 and rr <= h and cc >= 1 and cc <= w and role[rr][cc] == "E" then
                        adj = true
                    end
                end
                if adj then role[r][c] = "S" end
            end
        end
    end

    local p_gap_lib = 0.2 + rng() * 0.3
    local p_hole    = rng() * 0.15
    local p_cut     = rng() * 0.08
    local p_inA     = rng() * 0.12
    local p_inD     = rng() * 0.1
    local grid = {}
    for r = 1, h + 1 do
        grid[r] = {}
        for c = 1, w + 1 do
            if r == h + 1 or c == w + 1 then
                grid[r][c] = "#"
            else
                local ro, x = role[r][c], rng()
                if ro == "E" then
                    grid[r][c] = (x < p_inA) and "A" or (x < p_inA + p_inD) and "D" or "."
                elseif ro == "S" then
                    grid[r][c] = (x < p_hole) and "." or (x < p_hole + p_cut) and "A" or "D"
                else
                    grid[r][c] = (x < p_gap_lib) and "." or "A"
                end
            end
        end
    end
    return grid, h, w
end

-- Roles to solver rows. kill: Black attacks; live: Black defends.
local function toRows(grid, kind)
    local A = (kind == "kill") and "X" or "O"
    local D = (kind == "kill") and "O" or "X"
    local rows = {}
    for r = 1, #grid do
        local t = {}
        for c = 1, #grid[r] do
            local ch = grid[r][c]
            t[c] = (ch == "A") and A or (ch == "D") and D or ch
        end
        rows[r] = table.concat(t)
    end
    return rows
end

-- Rejects positions that are illegal (a block with no liberty), trivial (a
-- defender block already in atari) or out of the size range.
local function sane(g, cells)
    local empties, defenders = 0, 0
    local tmp = {}
    for _, i in ipairs(g.region) do
        local v = cells[i]
        if v == EMPTY then
            empties = empties + 1
        else
            local _, libs, invul = Solver.scanGroup(g, cells, i, tmp)
            if libs == 0 and not invul then return false end
            if v == g.defender then
                defenders = defenders + 1
                if libs < 2 then return false end
            end
        end
    end
    return empties >= 5 and empties <= MAX_EMPTY and defenders >= 3
end

-- ---------------------------------------------------------------------------
-- Proof of a problem and its solution tree
-- ---------------------------------------------------------------------------

local MAX_PLAYER_NODES = 40
local MAX_DEPTH = 5

local function reject(why) error({ reject = why }, 0) end

-- Classifies every move of `player` here: lists of winning and losing points.
-- Raises a rejection if any move is unclear, or if the player could make a ko
-- capture (the device would then allow a move the tree never judged).
local function classify(P, cells, player)
    local g = P.g
    local wins, losses = {}, {}
    for _, p in ipairs(g.region) do
        if cells[p] == EMPTY then
            local captured, ko = Solver.play(g, cells, p, player, player)
            if captured then
                Solver.undo(cells, p, player, captured)
                if ko then reject("player ko") end
                local c = Solver.copy(cells)
                Solver.play(g, c, p, player, player)
                local o = Solver.outcome(P, c, 3 - player, false, player)
                if o == "win" then wins[#wins + 1] = p
                elseif o == "loss" then losses[#losses + 1] = p
                else reject("unclear move") end
            end
        end
    end
    return wins, losses
end

-- Settled: after the player's move, the player still wins even if the
-- opponent plays twice in a row.
local function settled(P, cells, player)
    local g, opp = P.g, 3 - player
    -- The opponent's moves as the unfavourable policy allows them (it may
    -- take kos).
    local kt = (player == g.attacker) and g.defender or g.attacker
    for _, p in ipairs(g.region) do
        if cells[p] == EMPTY then
            local c = Solver.copy(cells)
            if Solver.play(g, c, p, opp, kt) then
                if Solver.outcome(P, c, opp, false, player) ~= "win" then return false end
            end
        end
    end
    return true
end

-- The opponent's answer to a losing move: one after which the player is
-- proven lost. Prefers real moves, most forcing first.
local function refutation(P, cells, player)
    local g, opp = P.g, 3 - player
    local S = (player == g.attacker) and P.A or P.D   -- player-favourable policy
    for _, p in ipairs(Solver.orderedMoves(S, cells, opp)) do
        local c = Solver.copy(cells)
        if Solver.play(g, c, p, opp, S.ko_taker) then
            if Solver.outcome(P, c, player, false, player) == "loss" then return p end
        end
    end
    if Solver.outcome(P, cells, player, true, player) == "loss" then return false end
    reject("no refutation")
end

-- ---------------------------------------------------------------------------
-- The opponent's best reply
--
-- In tsumego the best defence is the one that resists LONGEST. So the tree
-- is built on a small minimax over the length of the line: the length of a
-- position (player to move) is the number of player moves still needed to
-- settle it, the player choosing the quickest win and the opponent the
-- longest resistance. Ties go to the reply that leaves the player the fewest
-- correct moves. A position that cannot be judged (an unclear move, a ko the
-- player could take, deeper than MAX_DEPTH) has no length; the opponent is
-- never steered into one -- the device only ever plays stored replies.
-- ---------------------------------------------------------------------------

local function keyOf(cells) return table.concat(cells, ",") end

-- Memoised classify: { wins, losses } or false when it cannot be judged.
local function nodeInfo(T, cells, player)
    local key = keyOf(cells)
    local info = T.info[key]
    if info == nil then
        local ok, wins, losses = pcall(classify, T.P, cells, player)
        if ok then
            info = { wins = wins, losses = losses }
        elseif type(wins) == "table" and wins.reject then
            info = false
        else
            error(wins, 0)
        end
        T.info[key] = info
    end
    return info
end

local function settledCached(T, cells, player)
    local key = keyOf(cells)
    local v = T.settled[key]
    if v == nil then
        v = settled(T.P, cells, player)
        T.settled[key] = v
    end
    return v
end

local lineLength

-- Length through the winning move p, and the opponent's reply on that line
-- (nil when the move settles at once).
local function winLength(T, cells, p, player, depth)
    local g = T.P.g
    local key = keyOf(cells) .. "@" .. p .. "#" .. depth
    local memo = T.wl[key]
    if memo ~= nil then
        if not memo then return nil end
        return memo[1], memo[2]
    end
    local c = Solver.copy(cells)
    Solver.play(g, c, p, player, player)
    local d, reply
    if settledCached(T, c, player) then
        d = 1
    else
        local S = (player == g.attacker) and T.P.D or T.P.A   -- player-unfavourable
        local worst, worst_w
        for _, r in ipairs(Solver.orderedMoves(S, c, 3 - player)) do
            local c2 = Solver.copy(c)
            if Solver.play(g, c2, r, 3 - player, S.ko_taker) then
                local dd = lineLength(T, c2, player, depth + 1)
                if dd then
                    local nw = #T.info[keyOf(c2)].wins
                    if not worst or dd > worst or (dd == worst and nw < worst_w) then
                        worst, worst_w, reply = dd, nw, r
                    end
                end
            end
        end
        if worst then d = 1 + worst end
    end
    T.wl[key] = d and { d, reply } or false
    return d, reply
end

lineLength = function(T, cells, player, depth)
    -- The depth is part of the key: a position cut off deep down may still
    -- have a length when it is met higher up.
    local key = keyOf(cells) .. "#" .. depth
    local memo = T.len[key]
    if memo ~= nil then return memo or nil end
    T.n = T.n + 1
    if T.n > T.limit then reject("tree search too big") end
    local info = (depth <= MAX_DEPTH) and nodeInfo(T, cells, player)
    local best
    if info then
        for _, p in ipairs(info.wins) do
            local d = winLength(T, cells, p, player, depth)
            if d and (not best or d < best) then best = d end
        end
    end
    T.len[key] = best or false
    return best
end

local function newTreeState(P)
    return { P = P, info = {}, settled = {}, wl = {}, len = {}, n = 0, limit = 600 }
end

-- Builds the stored node for a player-to-move position: every winning move
-- with the opponent's best reply, every losing move with a refutation.
local function buildPlayerNode(T, cells, player, depth, count)
    count.n = count.n + 1
    if count.n > MAX_PLAYER_NODES then reject("tree too big") end
    if depth > MAX_DEPTH then reject("too deep") end
    local P, g = T.P, T.P.g
    local info = nodeInfo(T, cells, player)
    if not info then reject("unjudged node") end
    if #info.wins == 0 then reject("only pass wins") end
    local node = { w = {}, l = {} }
    for _, p in ipairs(info.losses) do
        local c = Solver.copy(cells)
        Solver.play(g, c, p, player, player)
        local r = refutation(P, c, player)
        node.l[Solver.name(g, p)] = r and Solver.name(g, r) or ""
    end
    local best_d, best_m
    for _, p in ipairs(info.wins) do
        local d, r = winLength(T, cells, p, player, depth)
        if not d then reject("no reply") end
        if d == 1 then
            node.w[Solver.name(g, p)] = 1
        else
            local S = (player == g.attacker) and P.D or P.A
            local c = Solver.copy(cells)
            Solver.play(g, c, p, player, player)
            Solver.play(g, c, r, 3 - player, S.ko_taker)
            local child = buildPlayerNode(T, c, player, depth + 1, count)
            node.w[Solver.name(g, p)] = { r = Solver.name(g, r), n = child }
            assert(child.d == d - 1)
        end
        if not best_d or d < best_d then best_d, best_m = d, Solver.name(g, p) end
    end
    node.d, node.m = best_d, best_m
    return node
end

-- Full proof of one candidate as a problem. Returns the problem or nil, why.
local function prove(rows, attacker, budget, min_level)
    local g, cells = Solver.parse(rows, attacker)
    if not sane(g, cells) then return nil, "insane" end
    local P = Solver.newPair(g, budget)
    local player = 1   -- Black is always the side to play
    local ok, res = pcall(function()
        -- Cheap filters first: the player must win, and passing must lose.
        if Solver.outcome(P, cells, player, false, player) ~= "win" then reject("no win") end
        if Solver.outcome(P, cells, 3 - player, true, player) ~= "loss" then reject("pass ok") end
        local wins = classify(P, cells, player)
        if #wins ~= 1 then reject("not unique") end
        -- Hunting longer problems: drop one-movers before building a tree.
        if (min_level or 1) > 1 then
            local c = Solver.copy(cells)
            Solver.play(g, c, wins[1], player, player)
            if settled(P, c, player) then reject("too easy") end
        end
        local count = { n = 0 }
        local tree = buildPlayerNode(newTreeState(P), cells, player, 1, count)
        if tree.d < (min_level or 1) then reject("too easy") end
        return { tree = tree, nodes = count.n, search = P.A.nodes + P.D.nodes }
    end)
    if not ok then
        if type(res) == "table" and res.reject then return nil, res.reject end
        if res == Solver.BUDGET or res == Solver.DEEP then return nil, "budget" end
        error(res, 0)
    end
    return res
end

-- ---------------------------------------------------------------------------
-- Steering towards the boundary
--
-- A random shape is nearly always settled already: the group lives whoever
-- moves first, or dies whoever moves first. A problem sits on the boundary,
-- where the first move decides. So a candidate is nudged there: if the
-- player cannot win, the opponent is made a little weaker; if the player
-- would win even by passing, a little stronger -- one stone added or removed
-- at a time. Only the final position matters: it is proven from scratch.
-- ---------------------------------------------------------------------------

local QUICK_BUDGET = 4000

-- "nowin" | "passok" | "ok" | "fail" (unclear or too expensive) for Black
-- to play in this position.
local function quickStatus(rows, attacker)
    local g, cells = Solver.parse(rows, attacker)
    if not sane(g, cells) then return "insane" end
    local P = Solver.newPair(g, QUICK_BUDGET)
    local ok, res = pcall(function()
        local o = Solver.outcome(P, cells, 1, false, 1)
        if o == "loss" then return "nowin" end
        if o ~= "win" then return "fail" end
        local q = Solver.outcome(P, cells, 2, true, 1)
        if q == "win" then return "passok" end
        if q ~= "loss" then return "fail" end
        return "ok"
    end)
    if not ok then
        if res == Solver.BUDGET or res == Solver.DEEP then return "fail" end
        error(res, 0)
    end
    return res
end

local DIRS = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }

-- Makes the defender ('D' in roles) stronger (+1) or weaker (-1) by one
-- stone. Returns a new grid, or nil when nothing applies.
local function mutate(grid, rng, dir)
    local H, W = #grid, #grid[1]
    local function nextToD(r, c)
        for _, d in ipairs(DIRS) do
            local rr, cc = r + d[1], c + d[2]
            if rr >= 1 and rr <= H and cc >= 1 and cc <= W and grid[rr][cc] == "D" then
                return true
            end
        end
        return false
    end
    local options = {}
    for r = 1, H do
        for c = 1, W do
            local v = grid[r][c]
            if dir > 0 then
                if v == "." and nextToD(r, c) then options[#options + 1] = { r, c, "D" } end
                if v == "A" then options[#options + 1] = { r, c, "." } end
            else
                if v == "D" then options[#options + 1] = { r, c, "." } end
                if v == "." and nextToD(r, c) then options[#options + 1] = { r, c, "A" } end
            end
        end
    end
    if #options == 0 then return nil end
    local pick = options[rng(#options)]
    local new = {}
    for r = 1, H do
        new[r] = {}
        for c = 1, W do new[r][c] = grid[r][c] end
    end
    new[pick[1]][pick[2]] = pick[3]
    return new
end

-- Up to `steps` nudges; returns the grid once it is on the boundary.
local function steer(grid, kind, rng, steps)
    local attacker = (kind == "kill") and Solver.BLACK or Solver.WHITE
    for _ = 1, steps do
        local st = quickStatus(toRows(grid, kind), attacker)
        if st == "ok" then return grid end
        if st == "fail" then return nil, st end
        local dir
        if st == "insane" then
            dir = (rng() < 0.5) and 1 or -1
        elseif kind == "kill" then
            dir = (st == "nowin") and -1 or 1
        else
            dir = (st == "nowin") and 1 or -1
        end
        grid = mutate(grid, rng, dir)
        if not grid then return nil, "stuck" end
    end
    return nil, "steps"
end

-- ---------------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------------

local function serializeNode(node, out)
    out[#out + 1] = "{m=" .. string.format("%q", node.m) .. ",d=" .. node.d .. ",w={"
    local keys = {}
    for k in pairs(node.w) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = node.w[k]
        if v == 1 then
            out[#out + 1] = k .. "=1,"
        else
            out[#out + 1] = k .. "={r=" .. string.format("%q", v.r) .. ",n="
            serializeNode(v.n, out)
            out[#out + 1] = "},"
        end
    end
    out[#out + 1] = "},l={"
    keys = {}
    for k in pairs(node.l) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        out[#out + 1] = k .. "=" .. string.format("%q", node.l[k]) .. ","
    end
    out[#out + 1] = "}}"
end

local function canonicalKey(grid)
    local a, b = {}, {}
    for r = 1, #grid do a[r] = table.concat(grid[r]) end
    for c = 1, #grid[1] do
        local t = {}
        for r = 1, #grid do t[r] = grid[r][c] end
        b[c] = table.concat(t)
    end
    local ka, kb = table.concat(a, "/"), table.concat(b, "/")
    return (ka < kb) and ka or kb
end

-- Rebuilds the solution tree of an already proven problem (positions are
-- kept; only the stored replies change). Returns the tree or nil, why.
local function retree(p, budget)
    local attacker = (p.kind == "kill") and Solver.BLACK or Solver.WHITE
    local g, cells = Solver.parse(p.rows, attacker)
    local P = Solver.newPair(g, budget or 200000)
    local ok, res = pcall(function()
        return buildPlayerNode(newTreeState(P), cells, Solver.BLACK, 1, { n = 0 })
    end)
    if ok then return res end
    if type(res) == "table" and res.reject then return nil, res.reject end
    if res == Solver.BUDGET or res == Solver.DEEP then return nil, "budget" end
    error(res, 0)
end

local M = {
    retree = retree,
    candidate = candidate, steer = steer, quickStatus = quickStatus, toRows = toRows, prove = prove, newRng = newRng,
    serializeNode = serializeNode, canonicalKey = canonicalKey,
}

-- Library use (tests, merge script) stops here.
if not arg or not arg[0] or not arg[0]:match("gen_bank%.lua$") then return M end

io.stdout:setvbuf("no")
local first = tonumber(arg[1]) or 1
local count = tonumber(arg[2]) or 1000
local out_path = arg[3] or "bank_part.lua"
local budget = tonumber(arg[4]) or 15000
local min_level = tonumber(arg[5]) or 1
if arg[6] == "big" then MAX_EYE, MAX_EMPTY = 8, 14 end

local out = io.open(out_path, "w")
out:write("return {\n")
local seen = {}
local stats = {}
local t0 = os.clock()
local found = 0
for seed = first, first + count - 1 do
    local rng = newRng(seed)
    local grid0 = candidate(rng)
    if grid0 then
        local kind = (rng() < 0.5) and "kill" or "live"
        local grid, why0 = steer(grid0, kind, rng, 10)
        if not grid then stats[why0] = (stats[why0] or 0) + 1 end
        local key = grid and canonicalKey(grid) .. kind
        if grid and not seen[key] then
            seen[key] = true
            do
                local rows = toRows(grid, kind)
                local attacker = (kind == "kill") and Solver.BLACK or Solver.WHITE
                local t = os.clock()
                local res, why = prove(rows, attacker, budget, min_level)
                stats[why or "ok"] = (stats[why or "ok"] or 0) + 1
                if res then
                    found = found + 1
                    local buf = {}
                    serializeNode(res.tree, buf)
                    local q = {}
                    for i, r in ipairs(rows) do q[i] = string.format("%q", r) end
                    out:write(string.format(
                        "{seed=%d,kind=%q,level=%d,nodes=%d,search=%d,secs=%.2f,rows={%s},\ntree=%s},\n",
                        seed, kind, res.tree.d, res.nodes, res.search, os.clock() - t,
                        table.concat(q, ","), table.concat(buf)))
                    out:flush()
                end
            end
        end
    end
end
out:write("}\n")
out:close()
local parts = {}
for k, v in pairs(stats) do parts[#parts + 1] = k .. "=" .. v end
table.sort(parts)
print(string.format("seeds %d..%d: %d problems in %.1fs; %s", first, first + count - 1,
    found, os.clock() - t0, table.concat(parts, " ")))
