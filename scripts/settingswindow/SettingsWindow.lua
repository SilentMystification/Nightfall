local ControlLabel = require("common/ControlLabel")
local Easing = require("common/Easing")
local Fonts = require("common/constants/Fonts")
local removeParentheses = require("common/helpers/removeParentheses")
local formatBool = require("settingswindow/helpers/formatBool")
local formatFloat = require("settingswindow/helpers/formatFloat")
local formatInt = require("settingswindow/helpers/formatInt")
local getSettingsProps = require("settingswindow/helpers/getSettingsProps")

---@class SettingsWindow: SettingsWindowBase
local SettingsWindow = {}
SettingsWindow.__index = SettingsWindow

-- Free-running clock for the invalid-cell flash in drawDrillCell, ticked once
-- per frame in drawDrillsGrid - a module-level accumulator rather than
-- something reset per-cell, so every invalid cell on screen flashes in
-- lockstep instead of drifting relative to each other.
local invalidFlashTime = 0

---@param ctx SettingsWindowContext
---@param window Window
---@param isSongSelect? boolean
---@return SettingsWindow
function SettingsWindow.new(ctx, window, isSongSelect)
	---@class SettingsWindowBase
	---@field description Label[]|nil
	local self = {
		currentSetting = 0,
		ctx = ctx,
		description = {},
		descriptionAlpha = 0,
		modifyValueControl = ControlLabel.new("KNOB-R / BT-A  -  BT-D", "MODIFY VALUE"),
		selectOptionControl = ControlLabel.new("KNOB-R / BT-A  -  BT-D", "SELECT OPTION"),
		selectSettingControl = ControlLabel.new("KNOB-L", "SELECT SETTING"),
		selectTabControl = ControlLabel.new("FX-L / FX-R", "SELECT TAB"),
		shift = 0,
		triggerControl = ControlLabel.new("START", "TRIGGER"),
		whichControl = "value",
		window = window,
		windowResized = nil,
		x = 0,
		y = 0,
		w = 808,
		h = 664,
		-- Drills-grid green-flash-then-fade state (see getFlashEasing below),
		-- keyed by each row/cell's stable trackingId rather than position -
		-- drills resort by start point, so position alone can't tell "the same
		-- drill, moved" from "a different drill, now here."
		rowMoveFlashes = {}, -- trackingId -> Easing, for the Name column
		cellValidFlashes = {}, -- trackingId.."_"..field -> Easing
		lastRowPosition = {}, -- trackingId -> row, to detect a move
		lastCellValue = {}, -- trackingId.."_"..field -> value, to detect a change
	}

	self.highlights, self.settings, self.tabs = getSettingsProps(isSongSelect)

	---@diagnostic disable-next-line
	return setmetatable(self, SettingsWindow)
end

-- self.highlights is sized once (getSettingsProps, at construction) to however
-- many rows existed across all tabs at that moment. This window object lives
-- for the whole practice-mode session and is never rebuilt, but the Drills tab's
-- row count changes at runtime as drills are added - so a row index beyond the
-- original size has no Easing here. Create (and cache) one on first use instead
-- of indexing the table directly, so newly-added rows still animate/highlight.
---@param idx integer
---@return Easing
function SettingsWindow:getHighlight(idx)
	local h = self.highlights[idx]

	if not h then
		h = Easing.new()
		self.highlights[idx] = h
	end

	return h
end

-- Green-to-white fade used for "this just changed to something good" cues -
-- a drill's row moved after a resort, or a cell's value just changed while
-- staying valid. Created at rest (value 0, i.e. invisible) on first use; the
-- caller is responsible for :reset(1)-ing it once, at the moment the change
-- is actually detected, then :stop()-ing it every frame after to decay back
-- toward 0 (see tickHighlight above for the same start/stop idiom).
---@param store table<string|integer, Easing>
---@param key string|integer
---@return Easing
function SettingsWindow:getFlashEasing(store, key)
	local e = store[key]

	if not e then
		e = Easing.new()
		store[key] = e
	end

	return e
end

---@param value number 0 (white) .. 1 (green)
local function flashFadeColor(value)
	local c = 255 - math.floor(value * 255 + 0.5)
	return { c, 255, c }
end

-- start()/stop() only ever nudge timer toward 1 or 0 by dt/duration each frame -
-- they never snap it. If a highlight is re-selected before its previous stop()
-- fully decayed back to 0 (easy with the Drills grid's Up/Down navigation, which
-- can move faster than the 0.2s animation), the next start() resumes from
-- wherever timer was left instead of 0, so the box jumps most of the way to full
-- width/alpha in one frame and only the tail of the animation is visible. Force
-- a reset to exactly 0 on the not-current -> current edge so every activation is
-- a full, clean sweep.
---@param h Easing
---@param isCurrent boolean
---@param dt deltaTime
---@param duration? number seconds for a full sweep - wider boxes need longer so the sweep speed (px/s) doesn't look rushed next to narrower ones
---@param easeType? easingType 3 (default, ease-in-out) has a near-zero rate of change at the very start, which is imperceptible over a cell's small travel distance but eats a visibly large chunk of a wide box's sweep - use 2 (ease-out, moves immediately) for anything that travels far, like a full-row bar
function SettingsWindow:tickHighlight(h, isCurrent, dt, duration, easeType)
	duration = duration or 0.2
	easeType = easeType or 3

	if isCurrent then
		if not h.active then
			h:reset(0)
			h.active = true
		end
		h:start(dt, easeType, duration)
	else
		h.active = false
		h:stop(dt, easeType, duration)
	end
end

---@param dt deltaTime
function SettingsWindow:draw(dt)
	self:setProps()

	if self.ctx.isSongSelect then
		self:drawDim()
	end

	gfx.Translate(self.x + (self.shift * self.ctx.shift.value), self.y)
	self:drawWindow(dt)
end

function SettingsWindow:setProps()
	if self.windowResized ~= self.window.resized then
		self.x = -self.w - self.window.shiftX
		self.y = (self.window.h / 2) - (self.h / 2)

		if self.ctx.isSongSelect then
			self.shift = self.w + self.window.shiftX + (self.window.w / 2) - (self.w / 2)
		else
			self.shift = self.w + self.window.shiftX
		end

		self.windowResized = self.window.resized
	end
end

function SettingsWindow:drawDim()
	local window = self.window
	local scale = window.scaleFactor

	drawRect({
		x = -window.shiftX / scale,
		y = -window.shiftY / scale,
		w = window.resX / scale,
		h = window.resY / scale,
		alpha = self.ctx.shift.value * 0.4,
		color = "Black",
	})
end

---@param dt deltaTime
function SettingsWindow:drawWindow(dt)
	local tabIndex = self.ctx.tabIndex
	local x = 31
	local y = -6

	drawRect({
		w = self.w,
		h = self.h,
		alpha = 0.95,
		color = "Black",
		stroke = { color = "Medium", size = 2 },
	})

	self:drawHeader(x, y, tabIndex)

	y = y + 63

	self:drawSettings(dt, x, y, tabIndex)

	if self.description then
		self:drawDescription(x, y)
	end

	self:drawControls(x, y)
end

---@param x number
---@param y number
---@param tabIndex integer
function SettingsWindow:drawHeader(x, y, tabIndex)
	y = y + 31

	for i, tab in ipairs(self.tabs) do
		tab:draw({
			x = x,
			y = y,
			alpha = ((i == tabIndex) and 1) or 0.4,
			color = "White",
		})

		x = x + tab.w + 30
	end
end

---@param dt deltaTime
---@param x number
---@param y number
---@param tabIndex integer
function SettingsWindow:drawSettings(dt, x, y, tabIndex)
	if self.ctx.tabName == "Drills" then
		self:drawDrillsGrid(dt, x, y, tabIndex)
		return
	end

	local settingIndex = self.ctx.settingIndex
	local settings = self.settings[tabIndex]
	local w = self.w - 64

	x = x + 6
	y = y + 16

	for i, setting in ipairs(self.ctx.settings) do
		local isCurrent = i == settingIndex
		local h = self:getHighlight(i)
		self:tickHighlight(h, isCurrent, dt)

		self:drawSetting(
			x,
			y,
			w,
			setting,
			settings[removeParentheses(setting.name)],
			h.value,
			isCurrent
		)

		y = y + 44
	end
end

-- A committed value can be invalid without looking wrong at a glance (e.g. an
-- out-of-range measure silently clamped to the chart's last measure at commit -
-- the displayed number is unremarkable on its own, only wrong relative to the
-- drill's other point). Flashing calls attention to it without needing to
-- explain why in the limited space of a grid cell: first the value itself
-- flashes red 4 times a second, then it switches to the word "Invalid", then
-- alternates between the two once a second - not just steady red text.
---@param value integer
---@param x number
---@param cx number
---@param cellW number
---@param rowMidY number
function SettingsWindow:drawInvalidCell(value, x, cx, cellW, rowMidY)
	local cyclePhase = invalidFlashTime % 1
	if cyclePhase >= 0.5 then
		setColor("Negative", 1)
		gfx.Text("Invalid", x + cx + (cellW / 2), rowMidY)
		return
	end

	local flashPhase = invalidFlashTime % 0.25
	if flashPhase < 0.125 then
		setColor("Negative", 1)
	else
		setColor("White", 0.85)
	end
	gfx.Text(tostring(value), x + cx + (cellW / 2), rowMidY)
end

-- Draws one numeric cell (In-Measure/In-Beat/Out-Measure/Out-Beat) of a drill
-- row. A method taking plain arguments - not a per-row table of per-cell
-- tables - so the grid's hot per-frame render path (every visible row, every
-- frame) allocates nothing per cell.
---@param dt deltaTime
---@param x number
---@param idx integer
---@param cx number
---@param cellW number
---@param cellHighlightH number
---@param rowMidY number
---@param fieldKey string
function SettingsWindow:drawDrillCell(dt, x, idx, cx, cellW, cellHighlightH, rowMidY, fieldKey)
	local cell = self.ctx.settings[idx]
	local isCurrent = idx == self.ctx.settingIndex
	local h = self:getHighlight(idx)
	self:tickHighlight(h, isCurrent, dt)

	if h.value > 0 then
		drawRect({
			x = x + cx,
			y = rowMidY - (cellHighlightH / 2),
			w = cellW * h.value,
			h = cellHighlightH,
			alpha = 0.5 * h.value,
			color = "Standard",
		})
	end

	if cell.isEditing then
		-- No flash here (see drawInvalidCell below) - the value's what you're
		-- actively typing, so it should hold still.
		setColor(cell.invalid and "Negative" or "Positive", 1)
		gfx.Text(tostring(cell.value) .. "_", x + cx + (cellW / 2), rowMidY)
	elseif cell.invalid then
		-- In >= out (measure or beat, whichever pair is the culprit) - still
		-- freely editable/navigable, but flashes until the drill's points are
		-- fixed (see drawInvalidCell below).
		self:drawInvalidCell(cell.value, x, cx, cellW, rowMidY)
	else
		-- Same green-flash-then-fade as a moved row, any time this cell's
		-- committed value changes while it stays valid - covers both "you just
		-- fixed an invalid value" and "you changed an already-valid one."
		local key = cell.trackingId .. fieldKey
		local lastVal = self.lastCellValue[key]
		if lastVal ~= nil and lastVal ~= cell.value then
			self:getFlashEasing(self.cellValidFlashes, key):reset(1)
		end
		self.lastCellValue[key] = cell.value

		local flash = self.cellValidFlashes[key]
		if flash and flash.value > 0 then
			flash:stop(dt, 2, 0.6)
			setColor(flashFadeColor(flash.value), 1)
		elseif isCurrent then
			-- Hint that Enter opens this field for typing, even before you do
			setColor("Positive", 0.8)
		else
			setColor("White", 0.85)
		end
		-- 0 is a blank start/end measure on a freshly created drill (see
		-- PracticeModeSettingsDialog::IsDrillEmpty) - not a real measure number
		-- (measures are 1-indexed), so show nothing rather than "0".
		gfx.Text(cell.value == 0 and "" or tostring(cell.value), x + cx + (cellW / 2), rowMidY)
	end
end

-- The Drills tab lays its rows out as a compact grid (one line per drill,
-- header once at the top) instead of the generic one-row-per-line list.
--
-- This deliberately bypasses SettingsWindow.settings[tabIndex] (the label
-- cache built once in getSettingsProps, keyed by setting name): drill rows
-- are dynamic (added/removed, and the C++ side rebuilds their names/values
-- live), so a name-keyed cache built once at dialog-open would silently miss
-- new/changed rows until the whole dialog were torn down and recreated. This
-- reads straight from the live self.ctx.settings (refreshed every frame by
-- SettingsWindowContext:update) and draws with plain gfx.Text calls, so it
-- always reflects the current C++ state with no caching to go stale.
--
-- Row layout produced by PracticeModeSettingsDialog::m_CreateDrillsTab is a
-- fixed, deterministic pattern: 7 settings per drill (Select, Rename,
-- In-Measure, In-Beat, Out-Measure, Out-Beat, Delete), followed by exactly two
-- trailing buttons (Create New Drill, then Set current in/out as a new drill)
-- - so drills can be grouped by position rather than by name. Drills stay
-- sorted by start point ascending (see
-- PracticeModeSettingsDialog::m_SortDrillsAndFollow) - editing In-Measure/
-- In-Beat can silently move a row to a different position in the list.
---@param dt deltaTime
---@param x number
---@param y number
---@param tabIndex integer
function SettingsWindow:drawDrillsGrid(dt, x, y, tabIndex)
	invalidFlashTime = invalidFlashTime + dt

	local settingIndex = self.ctx.settingIndex
	local rawSettings = self.ctx.settings
	local total = #rawSettings
	local groupSize = 7 -- Select, Rename, In-Measure, In-Beat, Out-Measure, Out-Beat, Delete
	-- Two trailing rows follow the drills themselves: Create New Drill, then
	-- Set current in/out as a new drill.
	local numDrills = math.floor((total - 2) / groupSize)
	local w = self.w - 64

	x = x + 6
	y = y + 16

	local nameX = 0
	local nameW = 210
	local inMX = 220
	local inBX = 320
	local arrowX = 430
	local outMX = 450
	local outBX = 550
	local cellW = 90
	local deleteW = 100
	local deleteX = w - deleteW -- left edge of the Delete/Invalid cell
	local rowH = 34
	-- Highlight boxes are inset symmetrically from the full content width so
	-- the row highlight fully covers the DELETE text (centered within its own
	-- deleteX..deleteX+deleteW cell) and reads as centered rather than left-biased.
	local rowHighlightPad = 10
	local rowHighlightH = 28
	-- Individual cells (Rename, the 4 numeric fields) highlight a bit shorter
	-- than the full-row Select/Add-drill highlight, so it's visually obvious
	-- at a glance whether the whole row or just one cell is selected.
	local cellHighlightH = 20

	Fonts:load("SemiBold")
	gfx.FontSize(16)
	setColor("White", 0.5)
	gfx.TextAlign(gfx.TEXT_ALIGN_LEFT + gfx.TEXT_ALIGN_MIDDLE)
	gfx.Text("DRILL NAME", x + nameX, y)
	gfx.TextAlign(gfx.TEXT_ALIGN_CENTER + gfx.TEXT_ALIGN_MIDDLE)
	gfx.FontSize(13) -- "START/END MEASURE" are longer than the old "IN/OUT MEASURE"
	gfx.Text("START MEASURE", x + inMX + (cellW / 2), y)
	gfx.Text("START BEAT", x + inBX + (cellW / 2), y)
	gfx.Text("END MEASURE", x + outMX + (cellW / 2), y)
	gfx.Text("END BEAT", x + outBX + (cellW / 2), y)
	gfx.FontSize(16)
	y = y + 16

	-- Vertical space actually available for drill rows before running into
	-- the controls area near the bottom of this window's fixed height (self.h
	-- = 664) - without this, every drill (there's no upper bound on how many a
	-- chart can have) got a full set of highlight ticks, a table allocation,
	-- several font switches and draw calls, every single frame, regardless of
	-- whether it was anywhere near the visible area. Scroll to keep the
	-- current selection (roughly centered) in view instead, the same way the
	-- Default skin's equivalent list/grid do.
	--
	-- Drills never show a description (every branch below sets
	-- self.description = nil), so the only thing this actually has to clear is
	-- drawControls, anchored at a fixed y + 553 relative to the y this
	-- function was originally called with (57, before the +16 header offsets
	-- above) - i.e. absolute 610, vs. this body starting at y=89. 480 leaves a
	-- clean ~40px gap for the "more below" indicator instead of the old,
	-- overly conservative 420 (which fit 3 fewer rows than actually available
	-- and started scrolling correspondingly earlier than it needed to).
	local bodyHeight = 480
	local maxVisibleRows = math.max(1, math.floor(bodyHeight / rowH))
	local totalVisualRows = numDrills + 2 -- + Create New Drill + Set current in/out rows
	local maxScrollRow = math.max(0, totalVisualRows - maxVisibleRows)

	local createRowIdx = numDrills * groupSize + 1
	local addRowIdx = createRowIdx + 1

	local currentVisualRow
	if settingIndex == createRowIdx then
		currentVisualRow = numDrills -- 0-indexed: lands on the Create New Drill row
	elseif settingIndex == addRowIdx then
		currentVisualRow = numDrills + 1 -- 0-indexed: lands on the Set current in/out row
	else
		currentVisualRow = math.floor((settingIndex - 1) / groupSize)
	end
	local scrollRow = math.max(0, math.min(maxScrollRow, currentVisualRow - math.floor(maxVisibleRows / 2)))

	-- Drawn outside the scissor (above/below it) rather than clipped inside,
	-- so they're never mistaken for a partially-cut-off row.
	if scrollRow > 0 then
		Fonts:load("SemiBold")
		gfx.FontSize(11)
		gfx.TextAlign(gfx.TEXT_ALIGN_CENTER + gfx.TEXT_ALIGN_MIDDLE)
		setColor("White", 0.5)
		gfx.Text("^ MORE ABOVE ^", x + (w / 2), y - 6)
	end

	gfx.Scissor(x - rowHighlightPad, y, w + (rowHighlightPad * 2), bodyHeight)

	for row = 1, numDrills do
		local rowIndex0 = row - 1
		if rowIndex0 < scrollRow or rowIndex0 >= scrollRow + maxVisibleRows then
			goto continueDrillRow
		end

		local base = (row - 1) * groupSize
		local selectIdx = base + 1
		local renameIdx = base + 2
		local inMIdx = base + 3
		local inBIdx = base + 4
		local outMIdx = base + 5
		local outBIdx = base + 6
		local deleteIdx = base + 7

		local isSelectCurrent = selectIdx == settingIndex
		local isRenameCurrent = renameIdx == settingIndex
		local isDeleteCurrent = deleteIdx == settingIndex
		local rowMidY = y + ((rowIndex0 - scrollRow) * rowH) + (rowH / 2)

		-- Did this drill just move to a different row (a resort, triggered by
		-- editing its own or another drill's In-Measure/In-Beat)? Tracked by
		-- trackingId (stable identity), not row position (which is exactly
		-- what just changed) - see rowMoveFlashes above.
		local trackingId = rawSettings[selectIdx].trackingId
		local prevRow = self.lastRowPosition[trackingId]
		if prevRow ~= nil and prevRow ~= row then
			self:getFlashEasing(self.rowMoveFlashes, trackingId):reset(1)
		end
		self.lastRowPosition[trackingId] = row

		local selectHighlight = self:getHighlight(selectIdx)
		if selectHighlight then
			self:tickHighlight(selectHighlight, isSelectCurrent, dt, 0.35, 2)

			if selectHighlight.value > 0 then
				drawRect({
					x = x - rowHighlightPad,
					y = rowMidY - (rowHighlightH / 2),
					w = (w + (rowHighlightPad * 2)) * selectHighlight.value,
					h = rowHighlightH,
					alpha = 0.4 * selectHighlight.value,
					color = "Standard",
				})
			end
		end

		local renameSetting = rawSettings[renameIdx]
		local renameHighlight = self:getHighlight(renameIdx)
		if renameHighlight then
			self:tickHighlight(renameHighlight, isRenameCurrent, dt)

			if renameHighlight.value > 0 then
				drawRect({
					x = x + nameX - 4,
					y = rowMidY - (cellHighlightH / 2),
					w = nameW * renameHighlight.value,
					h = cellHighlightH,
					alpha = 0.5 * renameHighlight.value,
					color = "Standard",
				})
			end
		end

		-- While actively editing, show the real (possibly empty) buffer as-is -
		-- the C++ side already fills in the "Drill N" placeholder as real,
		-- backspace-able text whenever there's no custom name (see
		-- PracticeModeSettingsDialog::m_CreateDrillsTab), so this fallback only
		-- matters as a defensive default and must never override what's
		-- actually being typed (that made an emptied buffer visually "snap
		-- back" to the placeholder mid-edit).
		local drillLabel = renameSetting.isEditing and renameSetting.value
			or ((renameSetting.value ~= "" and renameSetting.value) or ("DRILL %d"):format(row))

		Fonts:load("SemiBold")
		gfx.FontSize(20)
		gfx.TextAlign(gfx.TEXT_ALIGN_LEFT + gfx.TEXT_ALIGN_MIDDLE)

		if renameSetting.isEditing then
			setColor("Positive", 1)
			gfx.Text(drillLabel:upper() .. "_", x + nameX, rowMidY)
		elseif isRenameCurrent then
			setColor("Positive", 0.8)
			gfx.Text(drillLabel:upper(), x + nameX, rowMidY)
		else
			local rowFlash = self.rowMoveFlashes[trackingId]
			if rowFlash and rowFlash.value > 0 then
				rowFlash:stop(dt, 2, 0.6)
				setColor(flashFadeColor(rowFlash.value), 1)
			else
				setColor("White", 0.4 + (0.6 * ((selectHighlight and selectHighlight.value) or 0)))
			end
			gfx.Text(drillLabel:upper(), x + nameX, rowMidY)
		end

		Fonts:load("Number")
		gfx.FontSize(22)
		gfx.TextAlign(gfx.TEXT_ALIGN_CENTER + gfx.TEXT_ALIGN_MIDDLE)

		self:drawDrillCell(dt, x, inMIdx, inMX, cellW, cellHighlightH, rowMidY, "_inM")
		self:drawDrillCell(dt, x, inBIdx, inBX, cellW, cellHighlightH, rowMidY, "_inB")
		self:drawDrillCell(dt, x, outMIdx, outMX, cellW, cellHighlightH, rowMidY, "_outM")
		self:drawDrillCell(dt, x, outBIdx, outBX, cellW, cellHighlightH, rowMidY, "_outB")

		Fonts:load("SemiBold")
		gfx.FontSize(18)
		gfx.TextAlign(gfx.TEXT_ALIGN_CENTER + gfx.TEXT_ALIGN_MIDDLE)
		setColor("White", 0.4)
		gfx.Text("->", x + arrowX, rowMidY)

		local deleteHighlight = self:getHighlight(deleteIdx)
		if deleteHighlight then
			self:tickHighlight(deleteHighlight, isDeleteCurrent, dt)
		end

		-- Row invalid (in >= out) - swap DELETE for an INVALID indicator, except
		-- while hovering the delete option itself, so it's still possible to
		-- delete an invalid drill rather than getting stuck with it. A first
		-- request (button or the Del key) on Delete arms a confirm (armed)
		-- rather than deleting outright - see m_RequestDeleteDrill.
		local rowInvalid = rawSettings[selectIdx].invalid
		local rowArmed = rawSettings[deleteIdx].armed
		local deleteLabel = "DELETE"
		local deleteColor = isDeleteCurrent and "Negative" or "White"
		local deleteAlpha = isDeleteCurrent and 1 or 0.4

		if rowArmed then
			deleteLabel = "REALLY?"
			deleteColor = { 255, 160, 0 } -- amber, distinct from the destructive-red hover/invalid states
			deleteAlpha = 1
		elseif rowInvalid and not isDeleteCurrent then
			deleteLabel = "INVALID"
			deleteColor = "Negative"
			deleteAlpha = 0.7
		end

		gfx.TextAlign(gfx.TEXT_ALIGN_CENTER + gfx.TEXT_ALIGN_MIDDLE)
		setColor(deleteColor, deleteAlpha)
		gfx.Text(deleteLabel, x + deleteX + (deleteW / 2), rowMidY)
		gfx.TextAlign(gfx.TEXT_ALIGN_LEFT + gfx.TEXT_ALIGN_TOP)

		if isSelectCurrent or isDeleteCurrent then
			self.whichControl = "button"
			self.description = nil
		elseif isRenameCurrent or inMIdx == settingIndex or inBIdx == settingIndex or outMIdx == settingIndex or outBIdx == settingIndex then
			-- Rename was previously missing from this check, so landing on it
			-- left self.description/whichControl showing stale state from
			-- whatever was current on a different tab before switching here.
			self.whichControl = "value"
			self.description = nil
		end

		::continueDrillRow::
	end

	-- Trailing "Create New Drill" row - a plain always-enabled button, drawn
	-- the same way as the Add row below it (can't go through the name-keyed
	-- cache - see that row's comment).
	local createSetting = rawSettings[createRowIdx]
	local isCreateCurrent = createRowIdx == settingIndex
	local createHighlight = self:getHighlight(createRowIdx)

	if createHighlight then
		self:tickHighlight(createHighlight, isCreateCurrent, dt, 0.35, 2)
	end

	local createRowIndex0 = numDrills
	if createRowIndex0 >= scrollRow and createRowIndex0 < scrollRow + maxVisibleRows then
		local createRowMidY = y + ((createRowIndex0 - scrollRow) * rowH) + (rowH / 2)

		if createHighlight and createHighlight.value > 0 then
			drawRect({
				x = x - rowHighlightPad,
				y = createRowMidY - (rowHighlightH / 2),
				w = (w + (rowHighlightPad * 2)) * createHighlight.value,
				h = rowHighlightH,
				alpha = 0.4 * createHighlight.value,
				color = "Standard",
			})
		end

		Fonts:load("SemiBold")
		gfx.FontSize(20)
		gfx.TextAlign(gfx.TEXT_ALIGN_LEFT + gfx.TEXT_ALIGN_MIDDLE)
		setColor("White", 0.4 + (0.6 * ((createHighlight and createHighlight.value) or 0)))
		gfx.Text(createSetting.name:upper(), x, createRowMidY)
	end

	-- Trailing "Set current in/out as a new drill" row - the last "visual row"
	-- (index numDrills + 1), subject to the same scroll window as the drills
	-- above it. Its label toggles between an enabled and a disabled/explanatory
	-- string depending on whether an in/out range is set (see
	-- PracticeModeSettingsDialog::m_CreateDrillsTab), so - like the grid rows
	-- above - it can't go through the name-keyed cache: the cache would only
	-- ever hold whichever of the two strings existed when the dialog first
	-- opened, and silently stop rendering on the other one.
	local addSetting = rawSettings[addRowIdx]
	local isAddCurrent = addRowIdx == settingIndex
	local addHighlight = self:getHighlight(addRowIdx)
	local isAddEnabled = addSetting.name ~= "Set an In and Out position to save as a drill"

	if addHighlight then
		self:tickHighlight(addHighlight, isAddCurrent, dt, 0.35, 2)
	end

	local addRowIndex0 = numDrills + 1
	if addRowIndex0 >= scrollRow and addRowIndex0 < scrollRow + maxVisibleRows then
		local addRowMidY = y + ((addRowIndex0 - scrollRow) * rowH) + (rowH / 2)

		if isAddEnabled and addHighlight and addHighlight.value > 0 then
			drawRect({
				x = x - rowHighlightPad,
				y = addRowMidY - (rowHighlightH / 2),
				w = (w + (rowHighlightPad * 2)) * addHighlight.value,
				h = rowHighlightH,
				alpha = 0.4 * addHighlight.value,
				color = "Standard",
			})
		end

		Fonts:load("SemiBold")
		gfx.FontSize(20)
		gfx.TextAlign(gfx.TEXT_ALIGN_LEFT + gfx.TEXT_ALIGN_MIDDLE)

		if isAddEnabled then
			setColor("White", 0.4 + (0.6 * ((addHighlight and addHighlight.value) or 0)))
		else
			setColor("White", 0.25)
		end

		gfx.Text(addSetting.name:upper(), x, addRowMidY)
	end

	gfx.ResetScissor()

	if scrollRow + maxVisibleRows < totalVisualRows then
		Fonts:load("SemiBold")
		gfx.FontSize(11)
		gfx.TextAlign(gfx.TEXT_ALIGN_CENTER + gfx.TEXT_ALIGN_MIDDLE)
		setColor("White", 0.5)
		gfx.Text("v MORE BELOW v", x + (w / 2), y + bodyHeight + 10)
	end

	if isCreateCurrent or isAddCurrent then
		self.whichControl = "button"
		self.description = nil
	end
end

---@param x number
---@param y number
---@param w number
---@param baseSetting SettingsDiagSetting
---@param setting FormattedSetting
---@param highlight number
---@param isCurrent boolean
function SettingsWindow:drawSetting(x, y, w, baseSetting, setting, highlight, isCurrent)
	if setting then
		local alpha = 0.4 + (0.6 * highlight)

		if isCurrent then
			self.description = setting.description
			self.descriptionAlpha = highlight
		end

		drawRect({
			x = x - 5,
			y = y + 4,
			w = w * highlight,
			h = 36,
			alpha = 0.5,
			color = "Standard",
		})
		---@diagnostic disable-next-line
		setting.name:draw({
			x = x,
			y = y,
			color = "White",
			alpha = alpha,
		})

		self:drawSettingValue(x, y, w, alpha, baseSetting, setting, isCurrent)
	end
end

---@param x number
---@param y number
---@param w number
---@param alpha number
---@param baseSetting SettingsDiagSetting
---@param setting FormattedSetting
---@param isCurrent boolean
function SettingsWindow:drawSettingValue(x, y, w, alpha, baseSetting, setting, isCurrent)
	local offsetY = 0
	local params = {
		x = x + w - 12,
		align = "RightTop",
		alpha = alpha,
		color = "White",
		update = true,
	}
	local type = baseSetting.type

	if type == "int" then
		if isCurrent then
			self.whichControl = "value"
		end

		params.color, params.text = formatInt(setting.category, baseSetting)
		offsetY = 3

		if baseSetting.isEditing then
			params.color = "Positive"
			params.text = params.text .. "_"
		elseif isCurrent then
			-- Hint that Enter opens this field for typing, even before you do
			params.color = "Positive"
		end

		if baseSetting.invalid then
			params.color = "Negative"
		end
	elseif type == "string" then
		if isCurrent then
			self.whichControl = "value"
		end

		params.text = baseSetting.value

		if baseSetting.isEditing then
			params.color = "Positive"
			params.text = params.text .. "_"
		elseif isCurrent then
			params.color = "Positive"
		end
	elseif type == "float" then
		if isCurrent then
			self.whichControl = "value"
		end

		params.text = formatFloat(setting.category, baseSetting)
		offsetY = 3
	elseif type == "enum" then
		if isCurrent then
			self.whichControl = "option"
		end

		params.text = setting.options[baseSetting.value]
	elseif type == "toggle" then
		if isCurrent then
			self.whichControl = "option"
		end

		params.color, params.text = formatBool(setting.isInverted, baseSetting)
	elseif type == "button" then
		if isCurrent then
			self.whichControl = "button"
		end
	end

	if setting.value then
		params.y = y + offsetY
		setting.value:draw(params)
	end
end

---@param category string
---@param setting SettingsDiagSetting
---@param isCurrent boolean
---@return string, string
function SettingsWindow:handleFloat(category, setting, isCurrent)
	local color = "White"
	local text = ""

	if isCurrent then
		self.whichControl = "value"
	end

	if category == "hitWindow" then
		text = ("±%d ms"):format(setting.value)

		if setting.value < setting.max then
			color = "Negative"
		end
	elseif (category == "time") or setting.name:lower():find("offset") then
		text = ("%d ms"):format(setting.value)
	else
		text = tostring(setting.value)
	end

	return color, text
end

---@param x number
---@param y number
function SettingsWindow:drawDescription(x, y)
	local alpha = self.descriptionAlpha
	local numLines = #self.description

	y = y + 525

	for _, line in ipairs(self.description) do
		---@diagnostic disable-next-line
		line:draw({
			x = x,
			y = y - (numLines * 25),
			alpha = alpha,
			color = "White",
		})

		numLines = numLines - 1
	end
end

---@param x number
---@param y number
function SettingsWindow:drawControls(x, y)
	local whichControl = self.whichControl

	x = x + 2
	y = y + 553

	self.selectTabControl:draw(x, y)

	x = x + 208

	self.selectSettingControl:draw(x, y)

	x = x + 226

	if whichControl == "button" then
		self.triggerControl:draw(x, y)
	elseif whichControl == "option" then
		self.selectOptionControl:draw(x, y)
	elseif whichControl == "value" then
		self.modifyValueControl:draw(x, y)
	end
end

return SettingsWindow
