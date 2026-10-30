local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. _dir .. "common/?.lua;" .. package.path

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local PluginBase = require("plugin_base")
local _          = require("i18n")

require("i18n").extend(lrequire("i18n_fr"))
local TsumegoScreen = lrequire("screen")

-- ---------------------------------------------------------------------------
-- TsumegoPlugin
-- ---------------------------------------------------------------------------

local TsumegoPlugin = PluginBase:extend{
    name      = "tsumego",
    menu_text = _("Tsumego"),
    menu_hint = "tools",
}

function TsumegoPlugin:createScreen()
    return TsumegoScreen:new{ plugin = self }
end

return TsumegoPlugin
