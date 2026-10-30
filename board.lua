-- ---------------------------------------------------------------------------
-- TsumegoBoard -- one life-and-death problem in play.
--
-- A problem (see problems.lua) is a small frame cut from the top-left corner
-- of a 19×19 board, plus its solution tree, both proven offline by
-- solver.lua. Here the frame is placed on a full board -- in one of the eight
-- orientations, picked from the problem id so the corners vary -- and played
-- with ordinary Go rules (captures, no suicide, simple ko; vendored from
-- go.koplugin).
--
-- Black always plays. Each Black move is looked up in the current tree node:
--   w[move] = 1               correct, and the problem is solved;
--   w[move] = { r = reply, n = next node }   correct, White answers `reply`;
--   l[move] = reply           wrong: White answers with the refutation.
-- Every legal Black move of a node is in w or l (the generator proves it and
-- the tests check it), so White's answers never need a search on device.
-- ---------------------------------------------------------------------------

local N = 19
local EMPTY, BLACK, WHITE = 0, 1, 2

local DIRS4 = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
local LETTERS = "abcdefghijklmnopqrstuvwxyz"

local function inBounds(r, c)
    return r >= 1 and r <= N and c >= 1 and c <= N
end

local function copyGrid(grid)
    local g = {}
    for r = 1, N do
        g[r] = {}
        for c = 1, N do g[r][c] = grid[r][c] end
    end
    return g
end

local function hashGrid(grid)
    local parts = {}
    for r = 1, N do parts[r] = table.concat(grid[r]) end
    return table.concat(parts, "|")
end

-- Flood fill of the block at (r,c): stones and liberty count.
local function getGroup(grid, r, c)
    local color = grid[r][c]
    local seen, stones, libs, nlibs = {}, {}, {}, 0
    local stack = { { r, c } }
    seen[r * 100 + c] = true
    while #stack > 0 do
        local cell = table.remove(stack)
        stones[#stones + 1] = cell
        for _, d in ipairs(DIRS4) do
            local nr, nc = cell[1] + d[1], cell[2] + d[2]
            if inBounds(nr, nc) then
                local v, key = grid[nr][nc], nr * 100 + nc
                if v == EMPTY then
                    if not libs[key] then libs[key] = true; nlibs = nlibs + 1 end
                elseif v == color and not seen[key] then
                    seen[key] = true
                    stack[#stack + 1] = { nr, nc }
                end
            end
        end
    end
    return stones, nlibs
end

-- ---------------------------------------------------------------------------
-- TsumegoBoard
-- ---------------------------------------------------------------------------

local TsumegoBoard = {}
TsumegoBoard.__index = TsumegoBoard

TsumegoBoard.N = N
TsumegoBoard.EMPTY, TsumegoBoard.BLACK, TsumegoBoard.WHITE = EMPTY, BLACK, WHITE

-- problem: a record from problems.lua.
function TsumegoBoard:new(problem)
    local obj = setmetatable({}, self)
    obj:setProblem(problem)
    return obj
end

function TsumegoBoard:setProblem(problem)
    self.problem = problem
    self.kind = problem.kind
    self.level = problem.level
    self.rows = problem.rows
    self.FR, self.FC = #problem.rows, #problem.rows[1]
    -- Orientation 0..7: bit 1 transposes, bit 2 flips rows, bit 4 flips
    -- columns. Taken from the id so a problem always looks the same.
    self.orient = problem.id % 8
    self:reset()
end

-- Frame (row, col) -> board (row, col), and back.
function TsumegoBoard:toBoard(fr, fc)
    local r, c = fr, fc
    if self.orient % 2 == 1 then r, c = c, r end
    if math.floor(self.orient / 2) % 2 == 1 then r = N + 1 - r end
    if math.floor(self.orient / 4) % 2 == 1 then c = N + 1 - c end
    return r, c
end

function TsumegoBoard:toFrame(r, c)
    if math.floor(self.orient / 4) % 2 == 1 then c = N + 1 - c end
    if math.floor(self.orient / 2) % 2 == 1 then r = N + 1 - r end
    if self.orient % 2 == 1 then r, c = c, r end
    return r, c
end

-- Move names are frame coordinates, SGF style: column letter, row letter.
function TsumegoBoard:nameAt(r, c)
    local fr, fc = self:toFrame(r, c)
    if fr < 1 or fr > self.FR or fc < 1 or fc > self.FC then return nil end
    return LETTERS:sub(fc, fc) .. LETTERS:sub(fr, fr)
end

function TsumegoBoard:pointOf(name)
    local fc = LETTERS:find(name:sub(1, 1), 1, true)
    local fr = LETTERS:find(name:sub(2, 2), 1, true)
    return self:toBoard(fr, fc)
end

-- True for the points Black may play: inside the frame and not a wall.
function TsumegoBoard:isInRegion(r, c)
    if not inBounds(r, c) then return false end
    local fr, fc = self:toFrame(r, c)
    if fr < 1 or fr > self.FR or fc < 1 or fc > self.FC then return false end
    return self.rows[fr]:sub(fc, fc) ~= "#"
end

function TsumegoBoard:reset()
    local attacker = (self.kind == "kill") and BLACK or WHITE
    self.grid = {}
    for r = 1, N do
        self.grid[r] = {}
        for c = 1, N do self.grid[r][c] = EMPTY end
    end
    for fr = 1, self.FR do
        for fc = 1, self.FC do
            local ch = self.rows[fr]:sub(fc, fc)
            local v = (ch == "#") and attacker or (ch == "X") and BLACK
                      or (ch == "O") and WHITE or EMPTY
            local r, c = self:toBoard(fr, fc)
            self.grid[r][c] = v
        end
    end
    self.node = self.problem.tree
    self.status = "playing"          -- "playing" | "solved" | "failed"
    self.history = {}                -- Black's moves, by name
    self.last_move = nil             -- {r,c} of the latest stone (either colour)
    self.white_passed = false
    self.ko_forbidden_hash = nil
    self.solution_labels = nil       -- {[r*100+c] = n} while the solution is shown
    self.hint_mark = nil             -- {r,c} marked by the first Hint tap
end

-- Places a stone with Go rules. Returns true, or false if illegal.
function TsumegoBoard:_place(r, c, color)
    if not inBounds(r, c) or self.grid[r][c] ~= EMPTY then return false end
    local opp = (color == BLACK) and WHITE or BLACK
    local scratch = copyGrid(self.grid)
    scratch[r][c] = color
    local captured = 0
    for _, d in ipairs(DIRS4) do
        local nr, nc = r + d[1], c + d[2]
        if inBounds(nr, nc) and scratch[nr][nc] == opp then
            local stones, libs = getGroup(scratch, nr, nc)
            if libs == 0 then
                for _, s in ipairs(stones) do scratch[s[1]][s[2]] = EMPTY end
                captured = captured + #stones
            end
        end
    end
    local own, own_libs = getGroup(scratch, r, c)
    if own_libs == 0 then return false end
    local new_hash = hashGrid(scratch)
    if self.ko_forbidden_hash and new_hash == self.ko_forbidden_hash then return false end
    local prev_hash = hashGrid(self.grid)
    self.grid = scratch
    if captured == 1 and #own == 1 then
        self.ko_forbidden_hash = prev_hash
    else
        self.ko_forbidden_hash = nil
    end
    self.last_move = { r = r, c = c }
    return true
end

function TsumegoBoard:isLegal(r, c)
    if self.status ~= "playing" or not self:isInRegion(r, c) then return false end
    if self.grid[r][c] ~= EMPTY then return false end
    local saved_grid, saved_ko, saved_last = self.grid, self.ko_forbidden_hash, self.last_move
    local ok = self:_place(r, c, BLACK)
    self.grid, self.ko_forbidden_hash, self.last_move = saved_grid, saved_ko, saved_last
    return ok
end

local function playReply(self, reply)
    self.white_passed = false
    if reply == "" then
        self.white_passed = true
        self.ko_forbidden_hash = nil
        return true
    end
    local rr, rc = self:pointOf(reply)
    return self:_place(rr, rc, WHITE)
end

-- Black plays (r,c); White answers from the tree at once. Returns:
--   "outside" | "occupied" | "illegal" | "ended"   -- nothing changed
--   "correct"   -- right move, White answered, keep going
--   "solved"    -- right move, the problem is solved
--   "wrong"     -- White answered with the refutation; the attempt failed
function TsumegoBoard:play(r, c)
    if self.status ~= "playing" then return "ended" end
    if not self:isInRegion(r, c) then return "outside" end
    if self.grid[r][c] ~= EMPTY then return "occupied" end
    local name = self:nameAt(r, c)
    local win, loss = self.node.w[name], self.node.l[name]
    if not win and not loss then return "illegal" end
    if not self:_place(r, c, BLACK) then return "illegal" end
    self.hint_mark = nil
    self.history[#self.history + 1] = name
    if win == 1 then
        self.status = "solved"
        return "solved"
    elseif win then
        playReply(self, win.r)
        self.node = win.n
        return "correct"
    end
    playReply(self, loss)
    self.status = "failed"
    return "wrong"
end

-- Replays a list of Black moves from the start. False if one is refused
-- (a saved game from another problem bank).
function TsumegoBoard:replay(history)
    self:reset()
    for _, name in ipairs(history) do
        local r, c = self:pointOf(name)
        local res = self:play(r, c)
        if res ~= "correct" and res ~= "solved" and res ~= "wrong" then
            self:reset()
            return false
        end
    end
    return true
end

-- Takes back Black's last move and White's answer.
function TsumegoBoard:undo()
    if #self.history == 0 then return false end
    local h = {}
    for i = 1, #self.history - 1 do h[i] = self.history[i] end
    self:replay(h)
    return true
end

function TsumegoBoard:canUndo()
    return #self.history > 0 and not self.solution_labels
end

-- The main line from the start, as a list of names, Black and White
-- alternating (a pass is "").
function TsumegoBoard:mainLine()
    local line, node = {}, self.problem.tree
    while node do
        local m = node.m
        line[#line + 1] = m
        local w = node.w[m]
        if w == 1 then break end
        line[#line + 1] = w.r
        node = w.n
    end
    return line
end

-- Shows the whole main line at once, numbered like a book diagram: one
-- refresh instead of an animation. As in a book, every numbered stone stays
-- on the diagram even if it is captured later in the line; a point played a
-- second time keeps its first number.
function TsumegoBoard:showSolution()
    self:reset()
    local labels = {}
    for i, name in ipairs(self:mainLine()) do
        if name ~= "" then
            local r, c = self:pointOf(name)
            if self.grid[r][c] == EMPTY then
                self.grid[r][c] = (i % 2 == 1) and BLACK or WHITE
                labels[r * 100 + c] = i
            end
        end
    end
    self.solution_labels = labels
    self.last_move = nil
    self.status = "shown"
end

function TsumegoBoard:isShowingSolution()
    return self.solution_labels ~= nil
end

-- ---------------------------------------------------------------------------
-- Hint: the main move of the current node, i.e. a move proven correct.
-- ScreenBase:onHint() drives the two taps (first marks it, second plays it).
-- ---------------------------------------------------------------------------

function TsumegoBoard:findHint()
    if self.status ~= "playing" then return nil, "complete" end
    local r, c = self:pointOf(self.node.m)
    return { kind = "move", r = r, c = c, name = self.node.m }
end

-- Called by ScreenBase:onHint() with the hinted point: the widget rings it.
function TsumegoBoard:setSelection(r, c)
    self.hint_mark = { r = r, c = c }
end

function TsumegoBoard:applyHint(step)
    if not step then return false end
    local res = self:play(step.r, step.c)
    return res == "correct" or res == "solved"
end

function TsumegoBoard:getHintsUsed()
    return self.hints_used or 0
end

function TsumegoBoard:noteHintUsed()
    self.hints_used = (self.hints_used or 0) + 1
end

-- ---------------------------------------------------------------------------
-- Display window: the frame plus one line of open board beyond the wall,
-- and never fewer than five lines either way.
-- ---------------------------------------------------------------------------

function TsumegoBoard:getCrop()
    local r1, c1 = self:toBoard(1, 1)
    local r2, c2 = self:toBoard(self.FR, self.FC)
    local top, bottom = math.max(1, math.min(r1, r2) - 1), math.min(N, math.max(r1, r2) + 1)
    local left, right = math.max(1, math.min(c1, c2) - 1), math.min(N, math.max(c1, c2) + 1)
    while bottom - top < 4 do
        if top > 1 and bottom == N then top = top - 1 else bottom = bottom + 1 end
    end
    while right - left < 4 do
        if left > 1 and right == N then left = left - 1 else right = right + 1 end
    end
    return { top = top, bottom = bottom, left = left, right = right }
end

-- True for points inside the frame (region or wall).
function TsumegoBoard:isInFrame(r, c)
    local fr, fc = self:toFrame(r, c)
    return fr >= 1 and fr <= self.FR and fc >= 1 and fc <= self.FC
end

-- ---------------------------------------------------------------------------
-- Persistence: the problem id and Black's moves; the position is replayed.
-- ---------------------------------------------------------------------------

function TsumegoBoard:serialize()
    local h = {}
    for i, name in ipairs(self.history) do h[i] = name end
    return {
        id         = self.problem.id,
        history    = h,
        hints_used = self.hints_used or 0,
        shown      = self.solution_labels ~= nil,
    }
end

-- data must be for this board's problem.
function TsumegoBoard:load(data)
    if type(data) ~= "table" or data.id ~= self.problem.id then return false end
    if type(data.history) ~= "table" then return false end
    if not self:replay(data.history) then return false end
    self.hints_used = tonumber(data.hints_used) or 0
    if data.shown then self:showSolution() end
    return true
end

return TsumegoBoard
