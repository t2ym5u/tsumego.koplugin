-- ---------------------------------------------------------------------------
-- bank.lua -- the problem bank (problems.lua) grouped by level.
--
-- Level = the number of Black moves the main line needs: 1 Easy, 2 Medium,
-- 3 or more Hard. Within a level, problems keep the bank's order (easiest
-- search first, see gen/merge_bank.lua).
-- ---------------------------------------------------------------------------

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local Bank = {}

local problems, by_id, by_level

local function load()
    if problems then return end
    problems = assert(loadfile(_dir .. "problems.lua"))()
    by_id, by_level = {}, { {}, {}, {} }
    for _, p in ipairs(problems) do
        by_id[p.id] = p
        local list = by_level[Bank.levelOf(p)]
        list[#list + 1] = p
        p._pos = #list
    end
end

function Bank.levelOf(p)
    return math.max(1, math.min(3, p.level))
end

function Bank.clampLevel(lvl)
    lvl = tonumber(lvl) or 1
    return math.max(1, math.min(3, math.floor(lvl)))
end

function Bank.all()
    load()
    return problems
end

function Bank.byId(id)
    load()
    return id and by_id[id]
end

function Bank.list(level)
    load()
    return by_level[Bank.clampLevel(level)]
end

function Bank.count(level)
    return #Bank.list(level)
end

-- Settings key of a problem's "solved" flag (string keys keep the settings
-- table a map).
function Bank.key(p)
    return "p" .. p.id
end

function Bank.position(level, p)
    local list = Bank.list(level)
    return (Bank.levelOf(p) == Bank.clampLevel(level)) and p._pos or 1, #list
end

function Bank.solvedCount(level, solved)
    local n = 0
    for _, p in ipairs(Bank.list(level)) do
        if solved[Bank.key(p)] then n = n + 1 end
    end
    return n
end

-- The first unsolved problem after `current` in this level (wrapping), or
-- simply the next one once the whole level is solved.
function Bank.nextUnsolved(level, current, solved)
    local list = Bank.list(level)
    if #list == 0 then return nil end
    local start = (current and Bank.levelOf(current) == Bank.clampLevel(level)) and current._pos or 0
    for k = 1, #list do
        local p = list[(start + k - 1) % #list + 1]
        if not solved[Bank.key(p)] then return p end
    end
    return list[start % #list + 1]
end

function Bank.previous(level, current)
    local list = Bank.list(level)
    if #list == 0 then return nil end
    local pos = (current and Bank.levelOf(current) == Bank.clampLevel(level)) and current._pos or 1
    return list[(pos - 2) % #list + 1]
end

return Bank
