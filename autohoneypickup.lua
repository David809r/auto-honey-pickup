-- AutoHoneyPickup
-- Run as a client/LocalScript. Live Bee-event Honey models are reached with
-- dingus.lua's grapple-first carpet engagement and velocity-glide movement.

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- Stop an older copy cleanly when the script is executed again.
if type(_G.AutoHoneyPickupSession) == "table" then
	_G.AutoHoneyPickupSession.cancelled = true

	for _, connection in ipairs(_G.AutoHoneyPickupSession.connections or {}) do
		pcall(function()
			connection:Disconnect()
		end)
	end

	if _G.AutoHoneyPickupSession.gui then
		pcall(function()
			_G.AutoHoneyPickupSession.gui:Destroy()
		end)
	end

	if _G.AutoHoneyPickupSession.testMarker then
		pcall(function()
			_G.AutoHoneyPickupSession.testMarker:Destroy()
		end)
	end
end

local session = {
	cancelled = false,
	connections = {},
	testActive = false,
	serverHopActive = false,
}
_G.AutoHoneyPickupSession = session

local config = _G.AutoHoneyPickupConfig

if type(config) ~= "table" then
	config = {}
	_G.AutoHoneyPickupConfig = config
end

-- These can be changed before executing the script, for example:
-- _G.AutoHoneyPickupConfig = { Enabled = true, Debug = true }
if config.Enabled == nil then config.Enabled = true end
if config.Debug == nil then config.Debug = false end
if config.ArrivalDistance == nil then config.ArrivalDistance = 4.5 end
if config.ScanInterval == nil then config.ScanInterval = 0.25 end
if config.TargetTimeout == nil then config.TargetTimeout = 30 end
if config.FlightTimeout == nil then config.FlightTimeout = 10 end
if config.CarpetSpeed == nil then config.CarpetSpeed = 150 end
config.InternalVersion = 2
if config.PreferredCarpet == nil then config.PreferredCarpet = "Flying Carpet" end
if config.UseGrapple == nil then config.UseGrapple = true end
if config.ServerHopEnabled == nil then config.ServerHopEnabled = true end
if config.ServerHopStartDelay == nil then config.ServerHopStartDelay = 20 end
if config.ServerHopIdleSeconds == nil then config.ServerHopIdleSeconds = 8 end
if config.ServerHopRetrySeconds == nil then config.ServerHopRetrySeconds = 10 end
if config.ServerHopMaxPages == nil then config.ServerHopMaxPages = 3 end
if config.RequeueOnTeleport == nil then config.RequeueOnTeleport = true end

local trackedJars = {}
local warnedMissingCarpet = false
local warnedMissingGrapple = false
local updateUIStatus = function() end
local automationStartedAt = os.clock()
local lastHoneyActivity = automationStartedAt
local sawHoneyThisServer = false
local lastHopAttempt = -math.huge
local lastHopCountdown
local LOADSTRING_URL = "https://raw.githubusercontent.com/David809r/auto-honey-pickup/main/autohoneypickup.lua"
local visitedServers = {}

pcall(function()
	local teleportData = TeleportService:GetLocalPlayerTeleportData()
	if type(teleportData) == "table" and type(teleportData.AutoHoneyVisitedServers) == "table" then
		for _, serverId in ipairs(teleportData.AutoHoneyVisitedServers) do
			if type(serverId) == "string" then
				visitedServers[serverId] = true
			end
		end
	end
end)

if game.JobId ~= "" then
	visitedServers[game.JobId] = true
end
local CARPET_NAMES = {
	"Flying Carpet",
	"Carpet",
	"Cloud",
	"Witch's Broom",
	"Cupid's Wings",
	"Santa's Sleigh",
	"Magic Carpet",
	"Waverider",
}
local GRAPPLE_NAMES = {
	"Grapple Hook",
	"Grappling Hook",
	"Grapple",
	"Hook",
	"Web Slinger",
	"Grapple Gun",
	"GrappleHook",
}

local function log(...)
	if config.Debug then
		print("[AutoHoneyPickup]", ...)
	end
end

local function isInWorkspace(instance)
	return instance ~= nil and instance:IsDescendantOf(Workspace)
end

local function getClaimPrompt(instance)
	if not instance then
		return nil
	end

	local prompt = instance:IsA("ProximityPrompt")
		and instance
		or instance:FindFirstChildWhichIsA("ProximityPrompt", true)

	-- Signature used by Bee.createHoneyModel(). This prevents unrelated models
	-- named "Honey" from being mistaken for an event pickup.
	if prompt
		and prompt.ActionText == ""
		and prompt.ObjectText == ""
		and prompt:GetAttribute("CustomStyleDisabled") == true
	then
		return prompt
	end

	return nil
end

local function hasHoneyJarIdentity(instance)
	return string.lower(instance.Name) == "honeyjar"
		or (instance:IsA("Model")
			and string.lower(instance.Name) == "honey"
			and getClaimPrompt(instance) ~= nil)
		or CollectionService:HasTag(instance, "HoneyJar")
		or CollectionService:HasTag(instance, "Honey Jar")
end

local function isHoneyJar(instance)
	if not isInWorkspace(instance) or not hasHoneyJarIdentity(instance) then
		return false
	end

	-- If both a model and one of its parts happen to use the same name, only
	-- track the outer jar so a single pickup cannot enter the queue twice.
	local ancestor = instance.Parent
	while ancestor and ancestor ~= Workspace do
		if hasHoneyJarIdentity(ancestor) then
			return false
		end
		ancestor = ancestor.Parent
	end

	return instance:IsA("Model")
		or instance:IsA("BasePart")
		or instance:IsA("Attachment")
		or instance:IsA("Folder")
end

local function getJarPosition(jar)
	if not isInWorkspace(jar) then
		return nil
	end

	if jar:IsA("Attachment") then
		return jar.WorldPosition
	end

	if jar:IsA("BasePart") then
		return jar.Position
	end

	if jar:IsA("Model") then
		local ok, pivot = pcall(function()
			return jar:GetPivot()
		end)

		if ok then
			return pivot.Position
		end
	end

	local part = jar:FindFirstChildWhichIsA("BasePart", true)
	if part then
		return part.Position
	end

	local attachment = jar:FindFirstChildWhichIsA("Attachment", true)
	return attachment and attachment.WorldPosition or nil
end

local function getArrivalDistance(jar)
	local prompt = getClaimPrompt(jar)

	if prompt then
		-- The real Bee event uses a 12-stud prompt. Stay comfortably inside its
		-- range so PromptShown fires and the game's own client requests the claim.
		return math.max(config.ArrivalDistance, prompt.MaxActivationDistance - 2)
	end

	return config.ArrivalDistance
end

local function trackJar(instance)
	if isHoneyJar(instance) and getJarPosition(instance) then
		if trackedJars[instance] == nil then
			trackedJars[instance] = 0
			sawHoneyThisServer = true
			lastHoneyActivity = os.clock()
			lastHopCountdown = nil
			log("Found", instance:GetFullName())
		end
	end
end

local function inspectAddedInstance(instance)
	-- A model/folder can replicate before its physical children. Checking its
	-- ancestors whenever a child arrives catches that staged replication case.
	local current = instance
	while current and current ~= Workspace do
		trackJar(current)
		current = current.Parent
	end
end

local function getCharacter()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if humanoid and root and humanoid.Health > 0 then
		return character, humanoid, root
	end

	return nil, nil, nil
end

local function findTool(name)
	local character = LocalPlayer.Character
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	return (character and character:FindFirstChild(name))
		or (backpack and backpack:FindFirstChild(name))
end

local function findGrapple()
	for _, name in ipairs(GRAPPLE_NAMES) do
		local tool = findTool(name)
		if tool and tool:IsA("Tool") then
			return tool
		end
	end

	return nil
end

local function equipCarpet()
	local character, humanoid = getCharacter()
	if not character or not humanoid then
		return nil
	end

	local preferred = findTool(config.PreferredCarpet)
	if preferred and preferred:IsA("Tool") then
		if preferred.Parent ~= character then
			pcall(function()
				humanoid:EquipTool(preferred)
			end)
		end
		return preferred
	end

	for _, name in ipairs(CARPET_NAMES) do
		local tool = findTool(name)
		if tool and tool:IsA("Tool") then
			if tool.Parent ~= character then
				pcall(function()
					humanoid:EquipTool(tool)
				end)
			end
			return tool
		end
	end

	return nil
end

local function engageCarpet()
	local character, humanoid = getCharacter()
	if not character or not humanoid then
		return nil
	end

	if config.UseGrapple then
		local grapple = findGrapple()

		if grapple then
			if grapple.Parent ~= character then
				pcall(function()
					humanoid:EquipTool(grapple)
				end)

				local equipDeadline = os.clock() + 0.5
				while grapple.Parent ~= character and os.clock() < equipDeadline do
					RunService.Heartbeat:Wait()
				end
			end

			local fired = false
			if grapple.Parent == character and type(_G.SXEFireGrapple2) == "function" then
				local ok, result = pcall(_G.SXEFireGrapple2)
				fired = ok and result ~= false
			end

			-- Standalone fallback: activating the equipped tool lets the game's own
			-- grapple LocalScript send its current UseItem request.
			if grapple.Parent == character and not fired then
				fired = pcall(function()
					grapple:Activate()
				end)
			end

			if fired then
				task.wait(0.22)
			end
		elseif not warnedMissingGrapple then
			warnedMissingGrapple = true
			warn("[AutoHoneyPickup] Grapple Hook not found; continuing with carpet only.")
		end
	end

	pcall(function()
		humanoid:UnequipTools()
	end)
	task.wait(0.1)

	local deadline = os.clock() + 1
	repeat
		local carpet = equipCarpet()
		if carpet and carpet.Parent == character then
			return carpet
		end
		RunService.Heartbeat:Wait()
	until os.clock() >= deadline

	return nil
end

local function stopMovement()
	local _, _, root = getCharacter()
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end

local function queueScriptForTeleport()
	if not config.RequeueOnTeleport then
		return false
	end

	local environment = _G
	if type(getgenv) == "function" then
		pcall(function()
			environment = getgenv()
		end)
	end

	local queueFunction = (environment and environment.queue_on_teleport)
		or queue_on_teleport
		or (syn and syn.queue_on_teleport)
		or (fluxus and fluxus.queue_on_teleport)

	if type(queueFunction) ~= "function" then
		return false
	end

	local queuedSource = string.format([[
_G.AutoHoneyPickupConfig = {
	Enabled = %s,
	CarpetSpeed = %d,
	UseGrapple = %s,
	ServerHopEnabled = %s,
	ServerHopStartDelay = %d,
	ServerHopIdleSeconds = %d,
	RequeueOnTeleport = true,
}
loadstring(game:HttpGet(%q))()
]],
		tostring(config.Enabled == true),
		math.floor(tonumber(config.CarpetSpeed) or 150),
		tostring(config.UseGrapple == true),
		tostring(config.ServerHopEnabled == true),
		math.floor(tonumber(config.ServerHopStartDelay) or 20),
		math.floor(tonumber(config.ServerHopIdleSeconds) or 8),
		LOADSTRING_URL
	)

	return pcall(queueFunction, queuedSource)
end

local function getVisitedServerList(extraServerId)
	local result = {}
	if type(extraServerId) == "string" and extraServerId ~= "" then
		visitedServers[extraServerId] = true
	end

	for serverId in pairs(visitedServers) do
		result[#result + 1] = serverId
		if #result >= 40 then
			break
		end
	end

	return result
end

local function findLowestPopulationServer()
	local bestUnvisited
	local bestAny
	local cursor
	local maxPages = math.clamp(tonumber(config.ServerHopMaxPages) or 3, 1, 10)

	local function isBetter(candidate, currentBest)
		return not currentBest
			or candidate.playing < currentBest.playing
			or (candidate.playing == currentBest.playing and candidate.id < currentBest.id)
	end

	for _ = 1, maxPages do
		local url = string.format(
			"https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100",
			game.PlaceId
		)

		if cursor and cursor ~= "" then
			url ..= "&cursor=" .. HttpService:UrlEncode(cursor)
		end

		local requestOk, body = pcall(function()
			return game:HttpGet(url)
		end)

		if not requestOk or type(body) ~= "string" then
			return nil, "Public server request failed"
		end

		local decodeOk, response = pcall(HttpService.JSONDecode, HttpService, body)
		if not decodeOk or type(response) ~= "table" or type(response.data) ~= "table" then
			return nil, "Invalid public server response"
		end

		for _, server in ipairs(response.data) do
			local serverId = server.id
			local playing = tonumber(server.playing)
			local capacity = tonumber(server.maxPlayers)

			if type(serverId) == "string"
				and serverId ~= ""
				and serverId ~= game.JobId
				and playing
				and capacity
				and playing < capacity
			then
				local candidate = { id = serverId, playing = playing, capacity = capacity }
				if isBetter(candidate, bestAny) then
					bestAny = candidate
				end
				if not visitedServers[serverId] and isBetter(candidate, bestUnvisited) then
					bestUnvisited = candidate
				end
			end
		end

		cursor = response.nextPageCursor
		if not cursor or cursor == "" then
			break
		end
	end

	-- Prefer a new server. If every low-population candidate has already been
	-- visited, reuse the lowest one rather than getting permanently stuck.
	return bestUnvisited or bestAny, bestUnvisited and nil or "Visited pool exhausted"
end

local function hopToLowestPopulationServer()
	if session.serverHopActive or session.testActive or session.cancelled then
		return false
	end

	session.serverHopActive = true
	lastHopAttempt = os.clock()
	stopMovement()
	updateUIStatus("Finding lowest-player public server", Color3.fromRGB(251, 191, 36))

	local server, lookupNote = findLowestPopulationServer()
	if not server then
		session.serverHopActive = false
		updateUIStatus(lookupNote or "No public server found", Color3.fromRGB(248, 113, 113))
		return false
	end

	local queued = queueScriptForTeleport()
	if not queued then
		warn("[AutoHoneyPickup] queue_on_teleport is unavailable; the script may need to be run again after hopping.")
	end

	visitedServers[server.id] = true
	local teleportData = {
		AutoHoneyVisitedServers = getVisitedServerList(server.id),
	}

	updateUIStatus(
		string.format("Hopping to %d/%d player server", server.playing, server.capacity),
		Color3.fromRGB(147, 197, 253)
	)

	local teleportOk, teleportError = pcall(function()
		-- TeleportAsync is server-only. TeleportToPlaceInstance remains the
		-- client-capable API for joining a chosen public instance.
		TeleportService:TeleportToPlaceInstance(
			game.PlaceId,
			server.id,
			LocalPlayer,
			"",
			teleportData
		)
	end)

	if not teleportOk then
		session.serverHopActive = false
		warn("[AutoHoneyPickup] Server hop failed:", teleportError)
		updateUIStatus("Server hop failed - retrying later", Color3.fromRGB(248, 113, 113))
		return false
	end

	if lookupNote then
		log(lookupNote)
	end
	return true
end

local function getClosestJar(root)
	local closest
	local closestDistance = math.huge
	local now = os.clock()

	for jar, retryAt in pairs(trackedJars) do
		local position = getJarPosition(jar)

		if not position then
			trackedJars[jar] = nil
		elseif retryAt <= now then
			local distance = (root.Position - position).Magnitude
			if distance < closestDistance then
				closest = jar
				closestDistance = distance
			end
		end
	end

	return closest
end

local function flyToJar(jar, useGrappleEngage)
	if session.testActive then
		return "test_override"
	end

	local _, humanoid, root = getCharacter()

	if not humanoid or not root then
		return "character_changed"
	end

	local carpet = useGrappleEngage and engageCarpet() or equipCarpet()
	if not carpet then
		return "no_carpet"
	end

	pcall(function()
		root.Anchored = false
	end)

	local startedAt = os.clock()
	local lastDistance = math.huge
	local stalledFrames = 0
	local nextEquipAt = 0
	local flightSpeed = math.max(1, tonumber(config.CarpetSpeed) or 150)

	while os.clock() - startedAt < config.FlightTimeout do
		if session.cancelled or not config.Enabled then
			stopMovement()
			return "cancelled"
		end

		if session.testActive then
			stopMovement()
			return "test_override"
		end

		if not humanoid.Parent or humanoid.Health <= 0 or not root.Parent then
			return "character_changed"
		end

		local targetPosition = getJarPosition(jar)
		if not targetPosition then
			stopMovement()
			return "collected"
		end

		local offset = targetPosition - root.Position
		local distance = offset.Magnitude

		if distance <= getArrivalDistance(jar) then
			stopMovement()
			task.wait(0.4)
			return getJarPosition(jar) and "arrived" or "collected"
		end

		if os.clock() >= nextEquipAt then
			if not equipCarpet() then
				stopMovement()
				return "no_carpet"
			end
			nextEquipAt = os.clock() + 0.5
		end

		if distance >= lastDistance - 0.05 then
			stalledFrames += 1
		else
			stalledFrames = 0
		end
		lastDistance = distance

		if stalledFrames >= 60 then
			stopMovement()
			return "stalled"
		end

		root.AssemblyLinearVelocity = offset.Unit * flightSpeed
		root.AssemblyAngularVelocity = Vector3.zero
		RunService.Heartbeat:Wait()
	end

	stopMovement()
	return "timeout"
end

local function flyToTestPoint(worldPosition)
	local _, humanoid, root = getCharacter()
	if not humanoid or not root then
		return false, "Character unavailable"
	end

	if not engageCarpet() then
		return false, "Carpet not found"
	end

	pcall(function()
		root.Anchored = false
	end)

	-- Mouse.Hit is on the clicked surface; lift the destination so the root does
	-- not aim below the floor.
	local destination = worldPosition + Vector3.new(0, 3, 0)
	local speed = math.max(1, tonumber(config.CarpetSpeed) or 150)
	local deadline = os.clock() + config.FlightTimeout

	while os.clock() < deadline do
		if session.cancelled then
			stopMovement()
			return false, "Cancelled"
		end

		if not humanoid.Parent or humanoid.Health <= 0 or not root.Parent then
			return false, "Character changed"
		end

		local offset = destination - root.Position
		if offset.Magnitude <= 4 then
			stopMovement()
			return true, "Test destination reached"
		end

		if not equipCarpet() then
			stopMovement()
			return false, "Carpet unequipped"
		end

		root.AssemblyLinearVelocity = offset.Unit * speed
		root.AssemblyAngularVelocity = Vector3.zero
		RunService.Heartbeat:Wait()
	end

	stopMovement()
	return false, "Test timed out"
end

local function collectJar(jar)
	local startedAt = os.clock()
	local nextAttemptAt = 0
	local arrivalAttempts = 0
	local grappleEngaged = false

	log("Flying to", jar:GetFullName())
	updateUIStatus("Honey found - starting grapple TP", Color3.fromRGB(147, 197, 253))

	while not session.cancelled
		and config.Enabled
		and getJarPosition(jar)
		and os.clock() - startedAt < config.TargetTimeout
	do
		if os.clock() < nextAttemptAt then
			task.wait(0.1)
		else
			local result = flyToJar(jar, not grappleEngaged)
			grappleEngaged = result ~= "character_changed" and result ~= "no_carpet"

			if result == "collected" then
				break
			elseif result == "cancelled" then
				return
			elseif result == "test_override" then
				return
			elseif result == "character_changed" then
				task.wait(0.5)
			elseif result == "no_carpet" then
				if not warnedMissingCarpet then
					warnedMissingCarpet = true
					warn("[AutoHoneyPickup] No supported carpet tool was found in the Backpack or character.")
				end
				trackedJars[jar] = os.clock() + 3
				break
			elseif result == "stalled" or result == "timeout" then
				trackedJars[jar] = os.clock() + 3
				break
			elseif result == "arrived" then
				arrivalAttempts += 1

				-- A jar can linger while its claim request/animation completes.
				-- Yield to other jars after a few checks, then retry this one later.
				if arrivalAttempts >= 3 and getJarPosition(jar) then
					trackedJars[jar] = os.clock() + 3
					break
				end
			end

			nextAttemptAt = os.clock() + 0.5
		end
	end

	if not getJarPosition(jar) then
		trackedJars[jar] = nil
		log("Collected", jar.Name)
		updateUIStatus("Honey claimed - scanning", Color3.fromRGB(74, 222, 128))
	elseif os.clock() - startedAt >= config.TargetTimeout then
		-- Briefly cool it down so an unreachable closest jar cannot prevent the
		-- remaining jars from being visited. It stays tracked for another try.
		trackedJars[jar] = os.clock() + 5
		log("Timed out; will retry", jar:GetFullName())
		updateUIStatus("Honey attempt timed out", Color3.fromRGB(248, 113, 113))
	end

	stopMovement()
end

local function createControlPanel()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local oldGui = playerGui:FindFirstChild("AutoHoneyPickupUI")
	if oldGui then
		oldGui:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "AutoHoneyPickupUI"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui
	session.gui = gui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Position = UDim2.fromOffset(24, 110)
	panel.Size = UDim2.fromOffset(340, 362)
	panel.BackgroundColor3 = Color3.fromRGB(9, 14, 27)
	panel.BorderSizePixel = 0
	panel.Active = true
	panel.Parent = gui

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 10)
	panelCorner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = Color3.fromRGB(35, 50, 78)
	panelStroke.Thickness = 1
	panelStroke.Parent = panel

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 54)
	header.BackgroundColor3 = Color3.fromRGB(30, 64, 175)
	header.BorderSizePixel = 0
	header.Active = true
	header.Parent = panel

	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 10)
	headerCorner.Parent = header

	local headerCover = Instance.new("Frame")
	headerCover.Position = UDim2.new(0, 0, 1, -10)
	headerCover.Size = UDim2.new(1, 0, 0, 10)
	headerCover.BackgroundColor3 = header.BackgroundColor3
	headerCover.BorderSizePixel = 0
	headerCover.Parent = header

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(14, 7)
	title.Size = UDim2.new(1, -62, 0, 22)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Text = "AUTO HONEY PICKUP"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 15
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = header

	local subtitle = Instance.new("TextLabel")
	subtitle.Position = UDim2.fromOffset(14, 29)
	subtitle.Size = UDim2.new(1, -62, 0, 16)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.Gotham
	subtitle.Text = "Grapple + carpet test console"
	subtitle.TextColor3 = Color3.fromRGB(191, 219, 254)
	subtitle.TextSize = 10
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.Parent = header

	local minimizeButton = Instance.new("TextButton")
	minimizeButton.Position = UDim2.new(1, -43, 0, 11)
	minimizeButton.Size = UDim2.fromOffset(30, 30)
	minimizeButton.BackgroundColor3 = Color3.fromRGB(23, 48, 133)
	minimizeButton.BorderSizePixel = 0
	minimizeButton.Font = Enum.Font.GothamBold
	minimizeButton.Text = "-"
	minimizeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	minimizeButton.TextSize = 16
	minimizeButton.Parent = header

	local minimizeCorner = Instance.new("UICorner")
	minimizeCorner.CornerRadius = UDim.new(0, 6)
	minimizeCorner.Parent = minimizeButton

	local content = Instance.new("Frame")
	content.Position = UDim2.fromOffset(0, 54)
	content.Size = UDim2.new(1, 0, 1, -54)
	content.BackgroundTransparency = 1
	content.Parent = panel

	local function makeLabel(text, x, y, width, height, size, color, bold)
		local label = Instance.new("TextLabel")
		label.Position = UDim2.fromOffset(x, y)
		label.Size = UDim2.fromOffset(width, height)
		label.BackgroundTransparency = 1
		label.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
		label.Text = text
		label.TextColor3 = color
		label.TextSize = size
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = content
		return label
	end

	local function makeButton(text, x, y, width, height, background)
		local button = Instance.new("TextButton")
		button.Position = UDim2.fromOffset(x, y)
		button.Size = UDim2.fromOffset(width, height)
		button.BackgroundColor3 = background
		button.BorderSizePixel = 0
		button.AutoButtonColor = true
		button.Font = Enum.Font.GothamBold
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 11
		button.Parent = content

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 7)
		corner.Parent = button
		return button
	end

	makeLabel("STATUS", 14, 12, 312, 14, 9, Color3.fromRGB(128, 148, 180), true)
	local status = makeLabel(
		"Scanning for Bee event Honey",
		14,
		28,
		312,
		26,
		11,
		Color3.fromRGB(74, 222, 128),
		true
	)
	status.BackgroundColor3 = Color3.fromRGB(15, 23, 42)
	status.BackgroundTransparency = 0
	status.TextXAlignment = Enum.TextXAlignment.Center

	local statusCorner = Instance.new("UICorner")
	statusCorner.CornerRadius = UDim.new(0, 6)
	statusCorner.Parent = status

	updateUIStatus = function(text, color)
		if status.Parent then
			status.Text = text
			status.TextColor3 = color or Color3.fromRGB(148, 163, 184)
		end
	end

	local automationButton = makeButton("", 14, 66, 98, 40, Color3.fromRGB(22, 101, 52))
	local hopperButton = makeButton("", 120, 66, 98, 40, Color3.fromRGB(30, 64, 175))
	makeLabel("SPEED", 230, 64, 96, 14, 9, Color3.fromRGB(128, 148, 180), true)

	local speedBox = Instance.new("TextBox")
	speedBox.Position = UDim2.fromOffset(230, 80)
	speedBox.Size = UDim2.fromOffset(96, 26)
	speedBox.BackgroundColor3 = Color3.fromRGB(15, 23, 42)
	speedBox.BorderSizePixel = 0
	speedBox.ClearTextOnFocus = false
	speedBox.Font = Enum.Font.GothamBold
	speedBox.Text = tostring(config.CarpetSpeed)
	speedBox.TextColor3 = Color3.fromRGB(226, 232, 240)
	speedBox.TextSize = 11
	speedBox.Parent = content

	local speedCorner = Instance.new("UICorner")
	speedCorner.CornerRadius = UDim.new(0, 6)
	speedCorner.Parent = speedBox

	local function renderAutomation()
		automationButton.Text = config.Enabled and "AUTO: ON" or "AUTO: OFF"
		automationButton.BackgroundColor3 = config.Enabled
			and Color3.fromRGB(22, 101, 52)
			or Color3.fromRGB(71, 85, 105)
	end
	local function renderHopper()
		hopperButton.Text = config.ServerHopEnabled and "HOPPER: ON" or "HOPPER: OFF"
		hopperButton.BackgroundColor3 = config.ServerHopEnabled
			and Color3.fromRGB(30, 64, 175)
			or Color3.fromRGB(71, 85, 105)
	end
	renderAutomation()
	renderHopper()

	local sectionLine = Instance.new("Frame")
	sectionLine.Position = UDim2.fromOffset(14, 120)
	sectionLine.Size = UDim2.fromOffset(312, 1)
	sectionLine.BackgroundColor3 = Color3.fromRGB(35, 50, 78)
	sectionLine.BorderSizePixel = 0
	sectionLine.Parent = content

	makeLabel("TELEPORT TEST", 14, 133, 312, 16, 10, Color3.fromRGB(147, 197, 253), true)
	local pointLabel = makeLabel(
		"No destination selected",
		14,
		153,
		312,
		32,
		10,
		Color3.fromRGB(148, 163, 184),
		false
	)
	pointLabel.TextWrapped = true

	local selectButton = makeButton(
		"1. SELECT WORLD POINT",
		14,
		193,
		312,
		40,
		Color3.fromRGB(37, 99, 235)
	)
	local testButton = makeButton(
		"2. RUN GRAPPLE TP",
		14,
		241,
		312,
		42,
		Color3.fromRGB(194, 65, 12)
	)
	local hint = makeLabel(
		"Select, click a surface in the world, then run the test.",
		14,
		290,
		312,
		16,
		9,
		Color3.fromRGB(100, 116, 139),
		false
	)
	hint.TextXAlignment = Enum.TextXAlignment.Center

	local selectedPoint
	local selectionArmed = false
	local testRunning = false
	local mouse = LocalPlayer:GetMouse()

	local function clearMarker()
		if session.testMarker then
			session.testMarker:Destroy()
			session.testMarker = nil
		end
	end

	local function showMarker(position)
		clearMarker()
		local marker = Instance.new("Part")
		marker.Name = "AutoHoneyTestDestination"
		marker.Shape = Enum.PartType.Ball
		marker.Size = Vector3.new(1.5, 1.5, 1.5)
		marker.Position = position + Vector3.new(0, 0.75, 0)
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.CanTouch = false
		marker.Material = Enum.Material.Neon
		marker.Color = Color3.fromRGB(249, 115, 22)
		marker.Parent = Workspace
		session.testMarker = marker
	end

	table.insert(session.connections, automationButton.Activated:Connect(function()
		config.Enabled = not config.Enabled
		renderAutomation()

		if config.Enabled then
			updateUIStatus("Automation resumed", Color3.fromRGB(74, 222, 128))
		else
			if not session.testActive then
				stopMovement()
			end
			updateUIStatus("Automation paused", Color3.fromRGB(148, 163, 184))
		end
	end))

	table.insert(session.connections, hopperButton.Activated:Connect(function()
		config.ServerHopEnabled = not config.ServerHopEnabled
		renderHopper()
		lastHoneyActivity = os.clock()
		lastHopAttempt = -math.huge
		lastHopCountdown = nil
		updateUIStatus(
			config.ServerHopEnabled and "Server hopper enabled" or "Server hopper disabled",
			config.ServerHopEnabled and Color3.fromRGB(147, 197, 253) or Color3.fromRGB(148, 163, 184)
		)
	end))

	table.insert(session.connections, speedBox.FocusLost:Connect(function()
		local speed = math.clamp(tonumber(speedBox.Text) or config.CarpetSpeed, 25, 500)
		config.CarpetSpeed = math.floor(speed + 0.5)
		speedBox.Text = tostring(config.CarpetSpeed)
		updateUIStatus("Speed set to " .. speedBox.Text, Color3.fromRGB(147, 197, 253))
	end))

	table.insert(session.connections, selectButton.Activated:Connect(function()
		selectionArmed = not selectionArmed
		selectButton.Text = selectionArmed and "CLICK A WORLD SURFACE..." or "1. SELECT WORLD POINT"
		selectButton.BackgroundColor3 = selectionArmed
			and Color3.fromRGB(180, 83, 9)
			or Color3.fromRGB(37, 99, 235)
		updateUIStatus(
			selectionArmed and "Destination selection armed" or "Selection cancelled",
			selectionArmed and Color3.fromRGB(251, 191, 36) or Color3.fromRGB(148, 163, 184)
		)
	end))

	table.insert(session.connections, mouse.Button1Down:Connect(function()
		if not selectionArmed or UserInputService:GetFocusedTextBox() then
			return
		end

		if not mouse.Target then
			updateUIStatus("Click a visible world surface", Color3.fromRGB(248, 113, 113))
			return
		end

		selectedPoint = mouse.Hit.Position
		selectionArmed = false
		selectButton.Text = "1. SELECT WORLD POINT"
		selectButton.BackgroundColor3 = Color3.fromRGB(37, 99, 235)
		pointLabel.Text = string.format(
			"X %.1f   Y %.1f   Z %.1f",
			selectedPoint.X,
			selectedPoint.Y,
			selectedPoint.Z
		)
		pointLabel.TextColor3 = Color3.fromRGB(251, 191, 36)
		showMarker(selectedPoint)
		updateUIStatus("Test destination selected", Color3.fromRGB(251, 191, 36))
	end))

	table.insert(session.connections, testButton.Activated:Connect(function()
		if testRunning then
			updateUIStatus("A teleport test is already running", Color3.fromRGB(251, 191, 36))
			return
		end

		if not selectedPoint then
			updateUIStatus("Select a world point first", Color3.fromRGB(248, 113, 113))
			return
		end

		testRunning = true
		session.testActive = true
		testButton.Text = "TEST IN PROGRESS..."
		testButton.BackgroundColor3 = Color3.fromRGB(124, 45, 18)
		updateUIStatus("Taking movement control", Color3.fromRGB(251, 191, 36))

		task.spawn(function()
			stopMovement()
			task.wait(0.15)
			updateUIStatus("Grappling, then flying to test point", Color3.fromRGB(147, 197, 253))
			local callSucceeded, success, message = pcall(flyToTestPoint, selectedPoint)
			if not callSucceeded then
				local errorMessage = success
				success = false
				message = "Test failed - check the console"
				warn("[AutoHoneyPickup] Test teleport error:", errorMessage)
			end
			session.testActive = false
			testRunning = false
			testButton.Text = "2. RUN GRAPPLE TP"
			testButton.BackgroundColor3 = Color3.fromRGB(194, 65, 12)
			updateUIStatus(
				message,
				success and Color3.fromRGB(74, 222, 128) or Color3.fromRGB(248, 113, 113)
			)
		end)
	end))

	local minimized = false
	table.insert(session.connections, minimizeButton.Activated:Connect(function()
		minimized = not minimized
		content.Visible = not minimized
		panel.Size = minimized and UDim2.fromOffset(340, 54) or UDim2.fromOffset(340, 362)
		minimizeButton.Text = minimized and "+" or "-"
	end))

	local dragging = false
	local dragStart
	local panelStart
	table.insert(session.connections, header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			dragStart = input.Position
			panelStart = panel.Position
		end
	end))
	table.insert(session.connections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = false
		end
	end))
	table.insert(session.connections, UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch)
		then
			local delta = input.Position - dragStart
			panel.Position = UDim2.new(
				panelStart.X.Scale,
				panelStart.X.Offset + delta.X,
				panelStart.Y.Scale,
				panelStart.Y.Offset + delta.Y
			)
		end
	end))
end

-- Catch jars that already exist when the script starts.
for _, descendant in ipairs(Workspace:GetDescendants()) do
	inspectAddedInstance(descendant)
end

-- Also support games that identify event pickups with a CollectionService tag.
for _, tagName in ipairs({ "HoneyJar", "Honey Jar" }) do
	for _, taggedInstance in ipairs(CollectionService:GetTagged(tagName)) do
		inspectAddedInstance(taggedInstance)
	end

	table.insert(session.connections, CollectionService:GetInstanceAddedSignal(tagName):Connect(
		inspectAddedInstance
	))
end

table.insert(session.connections, Workspace.DescendantAdded:Connect(inspectAddedInstance))
table.insert(session.connections, Workspace.DescendantRemoving:Connect(function(instance)
	if trackedJars[instance] then
		trackedJars[instance] = nil
		lastHoneyActivity = os.clock()
	end
end))

table.insert(session.connections, TeleportService.TeleportInitFailed:Connect(function(
	player,
	_,
	errorMessage
)
	if player == LocalPlayer and session.serverHopActive then
		session.serverHopActive = false
		lastHopAttempt = os.clock()
		warn("[AutoHoneyPickup] Teleport initialization failed:", errorMessage)
		updateUIStatus("Teleport failed - retrying later", Color3.fromRGB(248, 113, 113))
	end
end))

createControlPanel()
print("[AutoHoneyPickup] Running - waiting for Bee event Honey spawns.")

while not session.cancelled do
	if session.testActive then
		task.wait(0.1)
	elseif session.serverHopActive then
		task.wait(0.1)
	elseif not config.Enabled then
		stopMovement()
		task.wait(0.25)
	else
		local _, _, root = getCharacter()

		if not root then
			task.wait(0.5)
		else
			local jar = getClosestJar(root)

			if jar then
				collectJar(jar)
			else
				local now = os.clock()
				local waitAnchor = sawHoneyThisServer and lastHoneyActivity or automationStartedAt
				local requiredIdle = sawHoneyThisServer
					and (tonumber(config.ServerHopIdleSeconds) or 8)
					or (tonumber(config.ServerHopStartDelay) or 20)
				local remaining = math.max(0, requiredIdle - (now - waitAnchor))
				local retryReady = now - lastHopAttempt
					>= (tonumber(config.ServerHopRetrySeconds) or 10)

				if config.ServerHopEnabled and remaining <= 0 and retryReady then
					hopToLowestPopulationServer()
				elseif config.ServerHopEnabled then
					local displayedRemaining = math.ceil(math.max(
						remaining,
						(tonumber(config.ServerHopRetrySeconds) or 10) - (now - lastHopAttempt)
					))
					if displayedRemaining ~= lastHopCountdown then
						lastHopCountdown = displayedRemaining
						updateUIStatus(
							string.format("No available Honey - hopping in %ds", displayedRemaining),
							Color3.fromRGB(148, 163, 184)
						)
					end
				end

				task.wait(config.ScanInterval)
			end
		end
	end
end

stopMovement()
for _, connection in ipairs(session.connections) do
	pcall(function()
		connection:Disconnect()
	end)
end
