# Changelog

All notable changes to this project will be documented in this file.

## [1.0.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-10-30

### Added
- Go life-and-death problems in the corner of a 19×19 board: "Black to kill"
  and "Black to live", Black always to play, White answering from a stored
  solution tree.
- A bank of problems generated and proven offline by an exhaustive
  life-and-death solver (`solver.lua`): exactly one correct first move, every
  stored answer and refutation proven, ko and seki handled conservatively.
  The tests re-prove every problem.
- Three levels by the length of the main line (Easy, Medium, Hard) and
  progress per level.
- Two-tap hint, numbered solution diagram, undo, retry, next/previous
  problem, timer, auto-save.
