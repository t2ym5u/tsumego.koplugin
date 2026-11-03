-- ---------------------------------------------------------------------------
-- gen/append_bank.lua -- appends newly generated problems to problems.lua.
--     luajit gen/append_bank.lua problems.lua <part1.lua> [part2.lua ...]
-- Unlike merge_bank.lua, which rebuilds the whole file, this keeps every
-- existing entry and its place: only new positions are appended (same
-- duplicate rule: the same frame or its mirror across the corner's diagonal,
-- with the same task; an id already in use is skipped too), each level's
-- newcomers ordered by how much search their proof took. Re-prove the result
-- with test_verify.lua.
-- ---------------------------------------------------------------------------
local args = {...}
local out = args[1]
local function tkey(p)
  local rows = p.rows
  local t = {}
  for c = 1, #rows[1] do local col = {} for r = 1, #rows do col[r] = rows[r]:sub(c,c) end t[c] = table.concat(col) end
  local a, b = table.concat(rows, "/"), table.concat(t, "/")
  return p.kind .. ":" .. ((a < b) and a or b)
end
local old = assert(loadfile(out))()
local seen, ids = {}, {}
for _, p in ipairs(old) do seen[tkey(p)] = true; ids[p.id] = true end
local new, dups = {}, 0
for i = 2, #args do
  for _, p in ipairs(assert(loadfile(args[i]))()) do
    local k = tkey(p)
    if seen[k] or ids[p.seed] then dups = dups + 1 else seen[k] = true; ids[p.seed] = true; new[#new+1] = p end
  end
end
table.sort(new, function(a, b)
  local la, lb = math.min(3, a.level), math.min(3, b.level)
  if la ~= lb then return la < lb end
  if a.search ~= b.search then return a.search < b.search end
  return a.seed < b.seed
end)
local function ser(node, o)
  o[#o+1] = "{m=" .. string.format("%q", node.m) .. ",d=" .. node.d .. ",w={"
  local keys = {} for k in pairs(node.w) do keys[#keys+1] = k end table.sort(keys)
  for _, k in ipairs(keys) do local v = node.w[k]
    if v == 1 then o[#o+1] = k .. "=1," else o[#o+1] = k .. "={r=" .. string.format("%q", v.r) .. ",n="; ser(v.n, o); o[#o+1] = "}," end end
  o[#o+1] = "},l={"
  keys = {} for k in pairs(node.l) do keys[#keys+1] = k end table.sort(keys)
  for _, k in ipairs(keys) do o[#o+1] = k .. "=" .. string.format("%q", node.l[k]) .. "," end
  o[#o+1] = "}}"
end
local f = assert(io.open(out)); local text = f:read("*a"); f:close()
local head = text:gsub("}\n$", "")
assert(head ~= text, "unexpected tail")
local buf = { head }
local per = {0,0,0}
for _, p in ipairs(new) do
  per[math.min(3,p.level)] = per[math.min(3,p.level)] + 1
  local q = {} for i, r in ipairs(p.rows) do q[i] = string.format("%q", r) end
  local t = {} ser(p.tree, t)
  buf[#buf+1] = string.format("{id=%d,kind=%q,level=%d,rows={%s},\ntree=%s},\n", p.seed, p.kind, p.level, table.concat(q, ","), table.concat(t))
end
buf[#buf+1] = "}\n"
f = assert(io.open(out, "w")); f:write(table.concat(buf)); f:close()
print(string.format("appended %d (easy %d, medium %d, hard %d), %d dups dropped", #new, per[1], per[2], per[3], dups))
