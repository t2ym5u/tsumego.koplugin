local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText     = require("ui/rendertext")
local UIManager      = require("ui/uimanager")

local Screen = Device.screen

local C_BG    = Blitbuffer.COLOR_WHITE
local C_LINE  = Blitbuffer.COLOR_BLACK
local C_BLACK = Blitbuffer.COLOR_BLACK
local C_WHITE = Blitbuffer.COLOR_WHITE
local C_SHADE = Blitbuffer.COLOR_GRAY_D

-- ---------------------------------------------------------------------------
-- TsumegoBoardWidget -- a window onto a 19×19 board.
--
-- Only the corner the problem lives in is drawn (TsumegoBoard:getCrop()), at
-- a size a finger can hit; the widget takes the window's shape rather than a
-- square, so no space goes to empty board. The real board edges are drawn
-- heavier; on the sides where the board goes on, the lines run out to the
-- widget's edge so the window reads as a cut, not as a small board. The
-- board beyond the wall is shaded: it is not part of the problem. Points are
-- intersections, not cells, as in go.koplugin's widget.
-- ---------------------------------------------------------------------------

local TsumegoBoardWidget = InputContainer:extend{
    board        = nil,
    onCellAction = nil,
    max_w        = 300,
    max_h        = 300,
}

local STAR_POINTS = {
    { 4, 4 }, { 4, 10 }, { 4, 16 }, { 10, 4 }, { 10, 10 }, { 10, 16 }, { 16, 4 }, { 16, 10 }, { 16, 16 },
}

function TsumegoBoardWidget:init()
    self:_layout()
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges   = "tap",
                range = function() return self.paint_rect end,
            },
        },
    }
end

-- Recomputes the window (a new problem has another corner).
function TsumegoBoardWidget:_layout()
    local crop = self.board:getCrop()
    self.crop = crop
    local nr, nc = crop.bottom - crop.top + 1, crop.right - crop.left + 1
    self.cell = math.floor(math.min(self.max_w / nc, self.max_h / nr))
    self.margin = math.floor(self.cell / 2)
    self.w, self.h = nc * self.cell, nr * self.cell
    self.dimen = Geom:new{ w = self.w, h = self.h }
    self.paint_rect = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.stone_r = math.max(3, math.floor(self.cell * 0.46))
    local face_size = math.max(8, math.floor(self.cell * 0.42 / (Screen:scaleBySize(1000) / 1000)))
    self.label_face = Font:getFace("cfont", face_size)
end

function TsumegoBoardWidget:_toXY(r, c)
    return self.margin + (c - self.crop.left) * self.cell,
           self.margin + (r - self.crop.top) * self.cell
end

function TsumegoBoardWidget:onTap(_, ges)
    if not (ges and ges.pos) then return false end
    local rect = self.paint_rect
    local lx, ly = ges.pos.x - rect.x, ges.pos.y - rect.y
    local c = math.floor((lx - self.margin) / self.cell + 0.5) + self.crop.left
    local r = math.floor((ly - self.margin) / self.cell + 0.5) + self.crop.top
    if r < self.crop.top or r > self.crop.bottom or c < self.crop.left or c > self.crop.right then
        return true
    end
    if self.onCellAction then self.onCellAction(r, c) end
    return true
end

function TsumegoBoardWidget:refresh()
    local rect = self.paint_rect
    UIManager:setDirty(self, function()
        return "ui", Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    end)
end

local function centredText(bb, face, text, cx, cy, color)
    local m = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, text, true, false)
    local x = math.floor(cx - m.x / 2)
    local baseline = math.floor(cy + (m.y_top - m.y_bottom) / 2)
    RenderText:renderUtf8Text(bb, x, baseline, face, text, true, false, color)
end

function TsumegoBoardWidget:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    bb:paintRect(x, y, self.w, self.h, C_BG)

    local board, crop, N = self.board, self.crop, self.board.N
    local edge_w = math.max(2, math.floor(self.cell / 16))

    -- Shade the board outside the problem's frame, one cell per point.
    for r = crop.top, crop.bottom do
        for c = crop.left, crop.right do
            if not board:isInFrame(r, c) then
                local px, py = self:_toXY(r, c)
                -- Nothing lies beyond a real board edge: stop at its line.
                local x0 = (c == 1) and px or math.max(0, px - self.margin)
                local y0 = (r == 1) and py or math.max(0, py - self.margin)
                local x1 = (c == N) and (px + 1) or math.min(self.w, px - self.margin + self.cell)
                local y1 = (r == N) and (py + 1) or math.min(self.h, py - self.margin + self.cell)
                bb:paintRect(x + x0, y + y0, x1 - x0, y1 - y0, C_SHADE)
            end
        end
    end

    -- Grid lines. A line ends at a real board edge; elsewhere it runs on to
    -- the edge of the widget.
    for r = crop.top, crop.bottom do
        local _, py = self:_toXY(r, crop.left)
        local x0 = (crop.left == 1) and self.margin or 0
        local x1 = (crop.right == N) and select(1, self:_toXY(r, crop.right)) or (self.w - 1)
        local th = (r == 1 or r == N) and edge_w or 1
        bb:paintRect(x + x0, y + py - math.floor(th / 2), x1 - x0 + 1, th, C_LINE)
    end
    for c = crop.left, crop.right do
        local px = self:_toXY(crop.top, c)
        local y0 = (crop.top == 1) and self.margin or 0
        local _, by = self:_toXY(crop.bottom, c)
        local y1 = (crop.bottom == N) and by or (self.h - 1)
        local th = (c == 1 or c == N) and edge_w or 1
        bb:paintRect(x + px - math.floor(th / 2), y + y0, th, y1 - y0 + 1, C_LINE)
    end

    for _, p in ipairs(STAR_POINTS) do
        if p[1] >= crop.top and p[1] <= crop.bottom and p[2] >= crop.left and p[2] <= crop.right then
            local sx, sy = self:_toXY(p[1], p[2])
            bb:paintCircle(x + sx, y + sy, math.max(2, math.floor(self.cell * 0.08)), C_LINE)
        end
    end

    local ring = math.max(2, math.floor(self.stone_r / 8))
    local labels = board.solution_labels
    for r = crop.top, crop.bottom do
        for c = crop.left, crop.right do
            local v = board.grid[r][c]
            if v ~= board.EMPTY then
                local px, py = self:_toXY(r, c)
                if v == board.BLACK then
                    bb:paintCircle(x + px, y + py, self.stone_r, C_BLACK)
                else
                    bb:paintCircle(x + px, y + py, self.stone_r, C_WHITE)
                    bb:paintCircle(x + px, y + py, self.stone_r, C_BLACK, ring)
                end
                local label = labels and labels[r * 100 + c]
                if label then
                    centredText(bb, self.label_face, tostring(label), x + px, y + py,
                        (v == board.BLACK) and C_WHITE or C_BLACK)
                end
            end
        end
    end

    -- Latest stone: a dot of the opposite colour.
    local lm = board.last_move
    if lm and board.grid[lm.r][lm.c] ~= board.EMPTY then
        local px, py = self:_toXY(lm.r, lm.c)
        local col = (board.grid[lm.r][lm.c] == board.BLACK) and C_WHITE or C_BLACK
        bb:paintCircle(x + px, y + py, math.max(3, math.floor(self.stone_r * 0.3)), col)
    end

    -- Hint: a thick square on the point to play -- a square, so it cannot
    -- be mistaken for a white stone.
    local hm = board.hint_mark
    if hm and board.grid[hm.r][hm.c] == board.EMPTY then
        local px, py = self:_toXY(hm.r, hm.c)
        local half = math.floor(self.stone_r * 0.75)
        bb:paintBorder(x + px - half, y + py - half, 2 * half, 2 * half,
            math.max(3, math.floor(self.stone_r / 5)), C_BLACK)
    end
end

return TsumegoBoardWidget
