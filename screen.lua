local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local MenuHelper = require("menu_helper")
local ScreenBase = require("screen_base")
local Timer      = require("timer")

local TsumegoBoard       = lrequire("board")
local TsumegoBoardWidget = lrequire("board_widget")
local Bank               = lrequire("bank")

local GAME_RULES_EN = _([[
Tsumego — Life and death

Each problem shows a corner of a 19×19 Go board. Black always plays.

• "Black to kill": the White group must die. Find the move that leaves it unable to make two eyes.
• "Black to live": the Black group must make two eyes, or be safe.

Tap an intersection to play. White answers at once with its most stubborn reply (its latest stone carries a dot). Keep going until the result is settled — White can no longer change it even with two moves in a row.

A wrong move is refuted by White's answer. Tap Undo to take it back, or Retry to start over.

The stones bordering the problem are alive and cannot be captured; play only inside them. There is exactly one correct first move.

Hint marks a correct move with a square; tap Hint again to play it. Show solution numbers the main line on the board.

A problem counts as solved when you solve it without hints or the solution. Problems are grouped by the number of Black moves the main line needs: Easy 1, Medium 2, Hard 3 or more.

Every problem was generated and proven by an exhaustive life-and-death search, whatever the outcome of any ko or seki.
]])

local GAME_RULES_FR = [[
Tsumego — Vie et mort

Chaque problème montre un coin d'un goban 19×19. Noir joue toujours.

• « Noir tue » : le groupe blanc doit mourir. Trouvez le coup qui l'empêche de faire deux yeux.
• « Noir vit » : le groupe noir doit faire deux yeux, ou être hors de danger.

Touchez une intersection pour jouer. Blanc répond aussitôt par sa défense la plus tenace (sa dernière pierre porte un point). Continuez jusqu'à ce que le résultat soit acquis : Blanc ne peut plus le changer, même en jouant deux coups de suite.

Un mauvais coup est réfuté par la réponse de Blanc. Touchez Annuler pour le reprendre, ou Recommencer pour repartir du début.

Les pierres qui entourent le problème sont vivantes et imprenables ; jouez seulement à l'intérieur. Il y a exactement un premier coup correct.

Astuce marque un coup correct d'un carré ; touchez Astuce une seconde fois pour le jouer. Voir la solution numérote la variante principale sur le goban.

Un problème compte comme résolu si vous le résolvez sans astuce ni solution. Les problèmes sont classés par le nombre de coups noirs de la variante principale : Facile 1, Moyen 2, Difficile 3 ou plus.

Chaque problème a été généré et prouvé par une recherche exhaustive de vie et de mort, quelle que soit l'issue d'un ko ou d'un seki.
]]

local LEVEL_LABELS = { _("Easy"), _("Medium"), _("Hard") }

local TsumegoScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function TsumegoScreen:init()
    self.solved = self.plugin:getSetting("solved", {})
    self.level = Bank.clampLevel(self.plugin:getSetting("level", 1))
    local state = self.plugin:loadState()
    local problem = type(state) == "table" and Bank.byId(state.id)
    if problem then self.level = Bank.levelOf(problem) end
    problem = problem or Bank.nextUnsolved(self.level, nil, self.solved)
    self:_setProblem(problem, state)
    ScreenBase.init(self)
end

function TsumegoScreen:_setProblem(problem, state)
    self.board = TsumegoBoard:new(problem)
    self.timer = Timer:new()
    if state and self.board:load(state) then
        self.board.assisted = state.assisted and true or false
        self.timer:load(state.timer)
    else
        self.board.assisted = false
        self.timer:start()
    end
    if self.board.status ~= "playing" then self.timer:stop() end
end

function TsumegoScreen:serializeState()
    local data = self.board:serialize()
    data.assisted = self.board.assisted
    data.timer = self.timer:serialize()
    return data
end

function TsumegoScreen:_save()
    self.plugin:saveState(self:serializeState())
end

function TsumegoScreen:_rebuild()
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function TsumegoScreen:isRoundOver()
    return self.board.status ~= "playing"
end

function TsumegoScreen:getRoundOverButtons()
    return {
        { text = _("Undo"),         callback = function() self:onUndo() end },
        { text = _("Retry"),        callback = function() self:onRetry() end },
        { text = _("Next problem"), callback = function() self:onNext() end },
    }
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function TsumegoScreen:buildLayout()
    local title_bar = self:buildTitleBar(_("Tsumego"), function()
        return {
            { text = T(_("Difficulty: %1"), LEVEL_LABELS[self.level]),
              callback = function() self:openLevelMenu() end },
            { text = self.board:isShowingSolution() and _("Hide solution") or _("Show solution"),
              callback = function() self:onToggleSolution() end },
            { text = _("Previous problem"), callback = function() self:onPrevious() end },
            { text = _("Progress"), callback = function() self:onProgress() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    local controls_w = self:getControlsWidth()
    self.status_text:setMaxWidth(controls_w)
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        self:buildActionBar({
            { text = _("Hint"),  callback = function() self:onHint() end },
            { text = _("Undo"),  callback = function() self:onUndo() end },
            { text = _("Retry"), callback = function() self:onRetry() end },
            { text = _("Next"),  callback = function() self:onNext() end },
        }),
    }

    local frame_pad = Size.padding.default
    local frame_extra = 2 * (frame_pad + Size.border.window)
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = TsumegoBoardWidget:new{
        board        = self.board,
        max_w        = budget_w - frame_extra,
        max_h        = budget_h - frame_extra,
        onCellAction = function(r, c) self:onCellAction(r, c) end,
    }
    local board_frame = FrameContainer:new{
        padding = frame_pad,
        margin  = 0,
        self.board_widget,
    }

    if self:isLandscape() then
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        })
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Play
-- ---------------------------------------------------------------------------

local MOVE_MESSAGES = {
    outside  = _("Play inside the problem area."),
    occupied = _("Invalid move."),
    illegal  = _("Invalid move."),
}

function TsumegoScreen:onCellAction(r, c)
    local board = self.board
    if board:isShowingSolution() then
        self:updateStatus(_("Hide the solution to keep playing."))
        return
    end
    if board.status ~= "playing" then return end

    local res = board:play(r, c)
    if MOVE_MESSAGES[res] then
        self:updateStatus(MOVE_MESSAGES[res])
        return
    end
    self.hint_cell = nil
    if res == "solved" then self:_noteSolved() end
    self.board_widget:refresh()
    self:_save()
    self:updateStatus(self:_moveMessage(res))
end

-- What a move did, for the status line.
function TsumegoScreen:_moveMessage(res)
    if res == "correct" then
        return self.board.white_passed
            and _("Correct. White passes. Your move.")
            or  _("Correct. White answered (dot). Your move.")
    end
    return nil   -- the default status says the rest
end

function TsumegoScreen:_noteSolved()
    self.timer:stop()
    if not self.board.assisted and self.board:getHintsUsed() == 0 then
        self.solved[Bank.key(self.board.problem)] = true
        self.plugin:saveSetting("solved", self.solved)
    end
end

function TsumegoScreen:onUndo()
    local board = self.board
    if board:isShowingSolution() then
        self:updateStatus(_("Hide the solution to keep playing."))
        return
    end
    if not board:undo() then return end
    self.hint_cell = nil
    if board.status == "playing" then self.timer:start() end
    self.board_widget:refresh()
    self:_save()
    self:updateStatus()
end

function TsumegoScreen:onRetry()
    self.board:reset()
    self.hint_cell = nil
    self.timer:start()
    self.board_widget:refresh()
    self:_save()
    self:updateStatus()
end

function TsumegoScreen:_goTo(problem)
    if not problem then return end
    self.hint_cell = nil
    self:_setProblem(problem)
    self:_save()
    self:_rebuild()
end

function TsumegoScreen:onNext()
    self:_goTo(Bank.nextUnsolved(self.level, self.board.problem, self.solved))
end

function TsumegoScreen:onPrevious()
    self:_goTo(Bank.previous(self.level, self.board.problem))
end

-- Same name as the fleet's "New game" entry point, for ScreenBase defaults.
function TsumegoScreen:onNewGame()
    self:onNext()
end

function TsumegoScreen:onToggleSolution()
    local board = self.board
    if board:isShowingSolution() then
        board:reset()
        self.timer:start()
    else
        board:showSolution()
        board.assisted = true
        self.timer:stop()
    end
    self.hint_cell = nil
    self.board_widget:refresh()
    self:_save()
    self:updateStatus()
end

function TsumegoScreen:onHint()
    local board = self.board
    if board.status == "solved" or board.status == "failed" then
        self:updateStatus(board.status == "solved"
            and _("Already solved. Tap Next problem.")
            or  _("Undo the wrong move or retry first."))
        return
    end
    ScreenBase.onHint(self)
    if board.status == "solved" then self.timer:stop() end
end

function TsumegoScreen:describeHintStep(step, level)
    if level == 1 then
        return _("A correct move is marked. Tap Hint to play it.")
    end
    return _("Played the hinted move.")
end

-- ---------------------------------------------------------------------------
-- Level and progress
-- ---------------------------------------------------------------------------

function TsumegoScreen:openLevelMenu()
    local items = {}
    for lvl = 1, 3 do
        items[#items + 1] = {
            id   = lvl,
            text = T("%1 (%2/%3)", LEVEL_LABELS[lvl], Bank.solvedCount(lvl, self.solved), Bank.count(lvl)),
        }
    end
    MenuHelper.openPickerMenu{
        title      = _("Difficulty"),
        items      = items,
        current_id = self.level,
        parent     = self,
        on_select  = function(lvl)
            self.level = lvl
            self.plugin:saveSetting("level", lvl)
            self:_goTo(Bank.nextUnsolved(lvl, nil, self.solved))
        end,
    }
end

function TsumegoScreen:onProgress()
    local lines = {}
    for lvl = 1, 3 do
        lines[#lines + 1] = T(_("%1: %2/%3 solved"), LEVEL_LABELS[lvl],
            Bank.solvedCount(lvl, self.solved), Bank.count(lvl))
    end
    self:showMessage(table.concat(lines, "\n"), 6)
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

function TsumegoScreen:updateStatus(msg)
    local board = self.board
    local status = msg
    if not status then
        local kill = board.kind == "kill"
        if board.status == "solved" then
            status = self:joinStatus(
                kill and _("Solved! White is dead.") or _("Solved! Black lives."),
                (board.assisted or board:getHintsUsed() > 0) and _("With help: not counted.")
                    or T(_("Time: %1"), self.timer:format()))
        elseif board.status == "failed" then
            status = kill and _("Wrong: White's answer (dot) saves the group.")
                          or  _("Wrong: White's answer (dot) kills the group.")
        elseif board.status == "shown" then
            status = _("Solution: Black plays the odd numbers.")
        else
            local pos, total = Bank.position(self.level, board.problem)
            status = self:joinStatus(
                LEVEL_LABELS[self.level],
                T("%1/%2", pos, total),
                kill and _("Black to kill") or _("Black to live"),
                self.solved[Bank.key(board.problem)] and _("Solved before") or nil)
        end
    end
    ScreenBase.updateStatus(self, status)
    self:refreshActionBar()
end

return TsumegoScreen
