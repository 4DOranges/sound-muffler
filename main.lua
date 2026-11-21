local constants = require("constants")
local SOUNDS = constants.sounds
local GROUPS = constants.groups

local blacklistGroups = PersistentDB:GetStructuredData("blacklistGroups") or {}
local individualMutes = PersistentDB:GetStructuredData("individualMutes") or {}
local individualUnmutes = PersistentDB:GetStructuredData("individualUnmutes") or {}
local blacklist = {}
local soundsByGroup = {}

local audioIcon = id.Sprites.RS3_AUDIO_OPTION_ICONS_1
local audioIconSelected = id.Sprites.RS3_AUDIO_OPTION_ICONS_9

-- Initialise the list of sounds belonging to each group
--    We don't keep track of individual sounds muted for each group since otherwise
--    the table is too big for PersistentDB to handle
for soundID, sound in pairs(SOUNDS) do
	if sound.group then
		local group = sound.group
		soundsByGroup[group] = soundsByGroup[group] or {}
		table.insert(soundsByGroup[group], soundID)
	end
end

local function rebuildBlacklist()
	blacklist = {}

	-- Mute sounds belonging to enabled groups
	for groupName in pairs(blacklistGroups) do
		for _, soundID in ipairs(soundsByGroup[groupName] or {}) do
			blacklist[soundID] = true
		end
	end

	-- Mute individual sounds
	for soundID in pairs(individualMutes) do
		blacklist[soundID] = true
	end

	-- Unmute exceptions belonging to groups
	for soundID in pairs(individualUnmutes) do
		blacklist[soundID] = nil
	end
end

rebuildBlacklist()

-- (Un)mute groups
function groupMuteToggle(groupName)
	local muted = not blacklistGroups[groupName]
	blacklistGroups[groupName] = muted or nil

	rebuildBlacklist()
end

-- (Un)mute individual sounds
function soundMuteToggle(soundID)
	local muted = not blacklist[soundID]
	local sound = SOUNDS[soundID]
	local groupMuted = sound and sound.group and blacklistGroups[sound.group]

	if groupMuted then
		-- The group is muted: track exceptions
		individualUnmutes[soundID] = not muted or nil
		individualMutes[soundID] = nil
	else
		-- The group isn't muted: track individual mutes
		individualMutes[soundID] = muted or nil
		individualUnmutes[soundID] = nil
	end

	blacklist[soundID] = muted or nil
end

-- This one actually mutes any playing audio
function muteSounds()
	for soundID,_ in pairs(blacklist) do
		audio.StopSoundsUsingResource(soundID)
	end
end

-- Reusable function for the Mute icon
local function addMuteSprite(tab, tooltip, columnGap)
	local sprite = tab:AddSprite(audioIcon, {
		size = 24,
		tooltip = tooltip,
		columnGap = columnGap
	})
	sprite.root:Subscribe(ui.Hook.ONMOUSEOVER, function(button)
		button.sprite = audioIconSelected
	end)
	sprite.root:Subscribe(ui.Hook.ONMOUSELEAVE, function(button)
		button.sprite = audioIcon
	end)
	return sprite
end

-- GROUPS TAB
local function buildGroupsTab(tab, onMuteChanged)
	for _, groupName in ipairs(GROUPS) do
		local sprite = addMuteSprite(tab, "Toggle " .. groupName)

		local function updateColour()
			sprite.root.rgba = blacklistGroups[groupName] and 0xff0000ff or 0xffffffff
		end

		sprite.root:Subscribe(ui.Hook.ONCLICK, function()
			groupMuteToggle(groupName)
			updateColour()
			onMuteChanged()
		end)
		updateColour()

		tab:AddText({text = groupName, inline = true})
	end
end

-- Display each entry in the tab
local function renderSoundRow(row, soundID)
	row.soundID = soundID

	local hidden = soundID == nil
	row.sprite.root.hidden = hidden
	row.label.hidden = hidden
	row.play.root.hidden = hidden

	if hidden then return end

	row.label.content = string.format("%d. %s", soundID, SOUNDS[soundID].name)
	row.sprite.root.rgba = blacklist[soundID] and 0xff0000ff or 0xffffffff
end

-- Prep function to add each mutable/previewable entry
local function addSoundRow(tab, tooltip, onToggle)
	local row = {sprite = addMuteSprite(tab, tooltip, 1)}

	row.sprite.root:Subscribe(ui.Hook.ONCLICK, function()
		if row.soundID then onToggle(row.soundID, row) end
	end)

	row.play = tab:AddSpriteButton("PLAY", function()
		if row.soundID then audio.Play(row.soundID) end
	end, {inline = true, tooltip = "Preview", columnGap = 1})

	row.label = tab:AddText({text = "", inline = true, font = 26})
	return row
end

-- SOUNDS TAB
local pageSize = 50
local function buildSoundsTab(soundsTab, soundIDs, searchNames, onMuteChanged)
	local rows = {}
	local matches = nil -- nil means the full list
	local page = 1
	local previousButton, nextButton, counter

	local function showPage(requestedPage)
		local total = matches and #matches or #soundIDs
		local pageCount = math.max(1, math.ceil(total / pageSize))
		page = math.max(1, math.min(requestedPage or page, pageCount))

		previousButton:SetDisabled(page == 1)
		nextButton:SetDisabled(page == pageCount)
		counter.content = total == 0 and "No results"
			or string.format("Page %d of %d (%d sounds)", page, pageCount, total)

		local offset = (page - 1) * pageSize

		for slot, row in ipairs(rows) do
			local resultIndex = offset + slot
			local listIndex

			if resultIndex <= total then
				listIndex = matches and matches[resultIndex] or resultIndex
			end

			renderSoundRow(row, listIndex and soundIDs[listIndex])
		end
	end

	local function search(text)
		local query = text:match("^%s*(.-)%s*$"):lower()
		if query == "" then
			matches = nil
		else
			matches = {}

			if query:match("^%d+$") then -- User searches by ID
				local targetID = tonumber(query)

				for listIndex, soundID in ipairs(soundIDs) do
					if soundID == targetID then
						matches[1] = listIndex
						break
					end
				end
			else -- User searches by name
				for listIndex, soundID in ipairs(soundIDs) do
					if searchNames[soundID]:find(query, 1, true) then
						matches[#matches+1] = listIndex
					end
				end
			end
		end
		showPage(1)
	end

	soundsTab:AddTextField({
		placeholder = "Search by sound name or ID",
		onChange = function(_, _, text)	search(text) end,
	})

	previousButton = soundsTab:AddSimpleButton("Previous", function() showPage(page - 1) end)
	nextButton = soundsTab:AddSimpleButton("Next", function() showPage(page + 1) end, { inline = true })
	counter = soundsTab:AddText({ text = "", inline = true })

	for slot=1, math.min(pageSize, #soundIDs) do
		rows[slot] = addSoundRow(soundsTab, "Toggle sound", function(soundID, row)
			soundMuteToggle(soundID)
			renderSoundRow(row, soundID)
			onMuteChanged()
		end)
	end

	return showPage
end

-- MUTED TAB
local function buildMutedTab(mutedTab, searchNames, refreshSoundsTab)
	local mutedRows = {}
	local mutedMatches = {}
	local mutedPage = 1
	local mutedQuery = ""
	local mutedPrevious, mutedNext, mutedCounter

	local function showMutedPage(requestedPage)
		local total = #mutedMatches
		local pageCount = math.max(1, math.ceil(total / pageSize))
		mutedPage = math.max(1, math.min(requestedPage, pageCount))

		mutedPrevious:SetDisabled(mutedPage == 1)
		mutedNext:SetDisabled(mutedPage == pageCount)

		mutedCounter.content = total == 0 and "No results"
			or string.format("Page %d of %d (%d muted sounds)", mutedPage, pageCount, total)

		local offset = (mutedPage-1) * pageSize

		for slot, row in ipairs(mutedRows) do
			renderSoundRow(row, mutedMatches[offset + slot])
		end
	end

	local function refreshMutedTab(requestedPage)
		mutedMatches = {}

		for soundID in pairs(blacklist) do
			if SOUNDS[soundID] and (
				mutedQuery == ""
				or tostring(soundID):find(mutedQuery, 1, true)
				or searchNames[soundID]:find(mutedQuery, 1, true)
			) then
				mutedMatches[#mutedMatches+1] = soundID
			end
		end

		table.sort(mutedMatches)
		showMutedPage(requestedPage or mutedPage)
	end

	mutedTab:AddTextField({
		placeholder = "Search muted sounds by name or ID",
		onChange = function(_, _, text)
			mutedQuery = text:match("^%s*(.-)%s*$"):lower()
			refreshMutedTab(1)
		end,
	})

	mutedPrevious = mutedTab:AddSimpleButton("Previous", function()
		showMutedPage(mutedPage - 1)
	end)

	mutedNext = mutedTab:AddSimpleButton("Next", function() showMutedPage(mutedPage + 1) end, {inline=true})

	mutedCounter = mutedTab:AddText({text="", inline=true})

		for slot = 1, pageSize do
			mutedRows[slot] = addSoundRow(mutedTab, "Unmute sound", function(soundID)
			soundMuteToggle(soundID)
			refreshSoundsTab()
			refreshMutedTab()
		end)
	end

	return refreshMutedTab
end

-- THE MAIN INTERFACE
local contentView
function mufflerUI(event)
	if contentView then contentView:Destroy() end

	local parent = event.component
	contentView = prettyui.SimpleView.new(parent, {
		width = parent.width,
		height = parent.height,
	})
	contentView:AddTitle("Sound Muffler")

	local tabs = contentView:AddTabs({
		{text = "Groups"},
		{text = "Sounds"},
		{text = "Muted"}
	}, {activeIndex = 1, height = parent.height})

	local refreshSoundsTab, refreshMutedTab
	buildGroupsTab(tabs:GetPage(1), function()
		if refreshSoundsTab then refreshSoundsTab() end
		if refreshMutedTab then refreshMutedTab() end
	end)

	local soundIDs = {}
	local searchNames = {}
	for soundID, sound in pairs(SOUNDS) do
		soundIDs[#soundIDs+1] = soundID
		searchNames[soundID] = sound.name:lower()
	end
	table.sort(soundIDs)

	refreshSoundsTab = buildSoundsTab(tabs:GetPage(2), soundIDs, searchNames, function()
		if refreshMutedTab then refreshMutedTab() end
	end)
	refreshMutedTab = buildMutedTab(tabs:GetPage(3), searchNames, refreshSoundsTab)

	refreshMutedTab(1)
	refreshSoundsTab(1)
end

Event.Logic.Subscribe("muteSounds", muteSounds)
Event.ContentLayerReady.Subscribe("mufflerReady", mufflerUI)

function PluginShutdown()
	Event.Logic.Unsubscribe("muteSounds")
	Event.ContentLayerReady.Unsubscribe("mufflerReady")

	if contentView then
		contentView:Destroy()
		contentView = nil
	end

	PersistentDB:SetStructuredData("blacklistGroups", blacklistGroups)
	PersistentDB:SetStructuredData("individualMutes", individualMutes)
	PersistentDB:SetStructuredData("individualUnmutes", individualUnmutes)
end