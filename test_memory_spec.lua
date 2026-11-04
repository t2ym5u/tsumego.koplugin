local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("Problem bank memory", function()
    it("loads problems.lua on first use only, and release() drops it", function()
        local Bank = dofile(DIR .. "bank.lua")
        assert.is_false(Bank.isLoaded())
        local ids = {}
        for _, p in ipairs(Bank.list(2)) do ids[#ids + 1] = p.id end
        assert.is_true(#ids > 0)
        assert.is_true(Bank.isLoaded())
        Bank.release()
        assert.is_false(Bank.isLoaded())
        local again = {}
        for _, p in ipairs(Bank.list(2)) do again[#again + 1] = p.id end
        assert.are.same(ids, again)
        assert.are.equal(ids[1], Bank.byId(ids[1]).id)
    end)
end)
