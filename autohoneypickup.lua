-- AutoHoneyPickup
-- Run as a client/LocalScript. Live Bee-event Honey models are reached with
-- dingus.lua's grapple-first carpet engagement and velocity-glide movement.

if not game:IsLoaded() then
	game.Loaded:Wait()
end
task.wait(1.5)

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local PathfindingService = game:GetService("PathfindingService")
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

	for _, cleanup in ipairs(_G.AutoHoneyPickupSession.cleanup or {}) do
		pcall(cleanup)
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
	cleanup = {},
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
local previousInternalVersion = tonumber(config.InternalVersion) or 0
if config.Enabled == nil then config.Enabled = true end
if config.Debug == nil then config.Debug = false end
if config.ArrivalDistance == nil then config.ArrivalDistance = 4.5 end
if config.TestArrivalDistance == nil then config.TestArrivalDistance = 5 end
if config.ScanInterval == nil then config.ScanInterval = 0.25 end
if config.TargetTimeout == nil then config.TargetTimeout = 30 end
if config.FlightTimeout == nil then config.FlightTimeout = 10 end
if config.CarpetSpeed == nil then config.CarpetSpeed = 150 end
if config.PreferredCarpet == nil then config.PreferredCarpet = "Flying Carpet" end
if config.UseGrapple == nil then config.UseGrapple = true end
if config.AntiRagdoll == nil then config.AntiRagdoll = true end
if config.AntiRagdollRecoverySeconds == nil then config.AntiRagdollRecoverySeconds = 0.6 end
if config.AntiFlingSpeedLimit == nil then config.AntiFlingSpeedLimit = 220 end
if config.UsePathfinding == nil then config.UsePathfinding = true end
if config.PathAgentRadius == nil then config.PathAgentRadius = 4 end
if config.PathWaypointReach == nil then config.PathWaypointReach = 1.5 end
if config.PathGridSize == nil then config.PathGridSize = 8 end
if config.PathGridMargin == nil then config.PathGridMargin = 80 end
if config.PathMaxGridNodes == nil then config.PathMaxGridNodes = 6000 end
if config.PathStallSeconds == nil then config.PathStallSeconds = 1.75 end
if config.ServerHopEnabled == nil then config.ServerHopEnabled = true end
if config.ServerHopStartDelay == nil then config.ServerHopStartDelay = 5 end
if config.ServerHopIdleSeconds == nil then config.ServerHopIdleSeconds = 2 end
if config.ServerHopRetrySeconds == nil then config.ServerHopRetrySeconds = 3 end
if config.ServerHopMaxPages == nil then config.ServerHopMaxPages = 1 end
if config.RequeueOnTeleport == nil then config.RequeueOnTeleport = true end
if config.BeeEventCheckInterval == nil then config.BeeEventCheckInterval = 0.5 end

-- Version 8 uses elapsed progress time instead of frame counts for stall
-- detection, avoiding false stalls at different client frame rates.
if previousInternalVersion < 4 then
	config.ServerHopStartDelay = 5
	config.ServerHopIdleSeconds = 2
	config.ServerHopRetrySeconds = 3
	config.ServerHopMaxPages = 1
end
if previousInternalVersion < 6 then
	config.PathWaypointReach = 1.5
end
config.InternalVersion = 8

local trackedJars = {}
local warnedMissingCarpet = false
local warnedMissingGrapple = false
local updateUIStatus = function() end
local updateBeeEventIndicator = function() end
local automationStartedAt = os.clock()
local lastHoneyActivity = automationStartedAt
local sawHoneyThisServer = false
local lastHopAttempt = -math.huge
local lastHopCountdown
local lastBeeEventCheck = -math.huge
local cachedBeeEventActive
local cachedBeeEventSource = "checking"
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

local function hasVisibleBeeEventIcon()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local camera = Workspace.CurrentCamera
	if not playerGui or not camera then
		return false
	end

	local viewport = camera.ViewportSize
	if viewport.X <= 0 or viewport.Y <= 0 then
		return false
	end

	for _, instance in ipairs(playerGui:GetDescendants()) do
		if instance:IsA("GuiObject")
			and (not session.gui or not instance:IsDescendantOf(session.gui))
			and instance.Visible
		then
			local visible = true
			local identifiesBee = false
			local current = instance

			while current and current ~= playerGui do
				if current:IsA("GuiObject") and not current.Visible then
					visible = false
					break
				elseif current:IsA("LayerCollector") and not current.Enabled then
					visible = false
					break
				end

				if string.find(string.lower(current.Name), "bee", 1, true) then
					identifiesBee = true
				end
				current = current.Parent
			end

			if visible and identifiesBee then
				local center = instance.AbsolutePosition + (instance.AbsoluteSize / 2)
				if center.X >= viewport.X * 0.6 and center.Y >= viewport.Y * 0.55 then
					return true
				end
			end
		end
	end

	return false
end

local function detectBeeEvent()
	local now = os.clock()
	if now - lastBeeEventCheck < math.max(0.1, tonumber(config.BeeEventCheckInterval) or 0.5) then
		return cachedBeeEventActive, cachedBeeEventSource
	end
	lastBeeEventCheck = now

	-- The Bee EventController sets this exact part to 0 on OnStart and 1 on
	-- OnStop. It is more reliable than depending on one particular UI layout.
	local beehive = Workspace:FindFirstChild("Beehive")
	local activeModel = beehive and beehive:FindFirstChild("Active")
	local activeNeon = activeModel and activeModel:FindFirstChild("ActiveNeon")

	if activeNeon and activeNeon:IsA("BasePart") then
		cachedBeeEventActive = activeNeon.Transparency < 0.5
		cachedBeeEventSource = "hive"
	else
		cachedBeeEventActive = nil
		cachedBeeEventSource = "checking"
	end

	-- A live event Bee or Honey is an unambiguous positive signal, including
	-- during the brief window before the hive visuals have fully replicated.
	for _, child in ipairs(Workspace:GetChildren()) do
		if string.sub(string.lower(child.Name), 1, 12) == "event bee - "
			or (hasHoneyJarIdentity(child) and getClaimPrompt(child) ~= nil)
		then
			cachedBeeEventActive = true
			cachedBeeEventSource = "live event model"
			break
		end
	end

	-- Keep the visible bottom-right Bee indicator as a fallback for places where
	-- the Beehive model is streamed out or renamed.
	if cachedBeeEventActive == nil and hasVisibleBeeEventIcon() then
		cachedBeeEventActive = true
		cachedBeeEventSource = "event UI"
	end

	updateBeeEventIndicator(cachedBeeEventActive, cachedBeeEventSource)
	return cachedBeeEventActive, cachedBeeEventSource
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
	local configuredDistance = math.clamp(tonumber(config.ArrivalDistance) or 4.5, 1, 6)

	if prompt then
		-- The real Bee event uses a 12-stud prompt. Stop no farther than half of
		-- that range (and never beyond 6 studs), rather than riding its edge.
		return math.min(configuredDistance, prompt.MaxActivationDistance * 0.5, 6)
	end

	return configuredDistance
end

local function getPathIgnoreList(jar)
	local ignore = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			ignore[#ignore + 1] = player.Character
		end
	end
	if jar then
		ignore[#ignore + 1] = jar
	end
	return ignore
end

local function findBlockingObstacle(origin, target, jar)
	local direction = target - origin
	if direction.Magnitude < 0.05 then
		return nil
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local ignore = getPathIgnoreList(jar)
	local rayOrigin = origin

	-- Skip non-collidable decoration until a real wall/structure is reached.
	for _ = 1, 64 do
		params.FilterDescendantsInstances = ignore
		local remaining = target - rayOrigin
		if remaining.Magnitude < 0.05 then
			return nil
		end

		local result = Workspace:Raycast(rayOrigin, remaining, params)
		if not result then
			return nil
		end

		local instance = result.Instance
		if instance == Workspace.Terrain
			or (instance:IsA("BasePart") and instance.CanCollide)
		then
			return result
		end

		ignore[#ignore + 1] = instance
		rayOrigin = result.Position + remaining.Unit * 0.2
	end

	return nil
end

local function isFlightSegmentClear(origin, target, jar)
	local direction = target - origin
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.1 then
		return findBlockingObstacle(origin, target, jar) == nil
	end

	local clearance = math.clamp(tonumber(config.PathAgentRadius) or 4, 2, 8)
	local perpendicular = Vector3.new(-flat.Z, 0, flat.X).Unit * clearance
	for _, offset in ipairs({ Vector3.zero, perpendicular, -perpendicular }) do
		if findBlockingObstacle(origin + offset, target + offset, jar) then
			return false
		end
	end

	return true
end

local function getGroundRoutePosition(position, jar)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = getPathIgnoreList(jar)
	params.IgnoreWater = true

	local origin = position + Vector3.new(0, 4, 0)
	local result = Workspace:Raycast(origin, Vector3.new(0, -80, 0), params)
	if result then
		return result.Position + Vector3.new(0, 3, 0)
	end
	return position
end

local function isRoutePointClear(position, jar)
	local clearance = math.clamp(tonumber(config.PathAgentRadius) or 4, 2, 8)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = getPathIgnoreList(jar)

	-- Keep the volume above the floor so the floor itself is not treated as a
	-- wall, while still rejecting wall/building parts occupying player space.
	local parts = Workspace:GetPartBoundsInBox(
		CFrame.new(position + Vector3.new(0, 2, 0)),
		Vector3.new(clearance * 2, 4, clearance * 2),
		params
	)
	for _, part in ipairs(parts) do
		if part.CanCollide then
			return false
		end
	end
	return true
end

local function areRouteSegmentsClear(fromPosition, route, jar)
	local previous = fromPosition
	for _, waypoint in ipairs(route) do
		if not isFlightSegmentClear(previous, waypoint, jar) then
			return false
		end
		previous = waypoint
	end
	return true
end

local function simplifyTravelRoute(fromPosition, route, jar)
	local points = { fromPosition }
	for _, waypoint in ipairs(route) do
		points[#points + 1] = waypoint
	end

	local simplified = {}
	local index = 1
	while index < #points do
		local candidate = #points
		while candidate > index + 1
			and not isFlightSegmentClear(points[index], points[candidate], jar)
		do
			candidate -= 1
		end
		simplified[#simplified + 1] = points[candidate]
		index = candidate
	end
	return simplified
end

local function computeGridRoute(fromPosition, targetPosition, jar)
	local cellSize = math.clamp(tonumber(config.PathGridSize) or 8, 6, 14)
	local margin = math.clamp(tonumber(config.PathGridMargin) or 80, 32, 160)
	local maxExpanded = math.clamp(tonumber(config.PathMaxGridNodes) or 6000, 1000, 12000)
	local targetGridX = math.round((targetPosition.X - fromPosition.X) / cellSize)
	local targetGridZ = math.round((targetPosition.Z - fromPosition.Z) / cellSize)
	local padding = math.ceil(margin / cellSize)
	local minX = math.min(0, targetGridX) - padding
	local maxX = math.max(0, targetGridX) + padding
	local minZ = math.min(0, targetGridZ) - padding
	local maxZ = math.max(0, targetGridZ) + padding
	local startKey = "0:0"

	local function keyFor(x, z)
		return tostring(x) .. ":" .. tostring(z)
	end

	local function pointFor(x, z)
		return Vector3.new(
			fromPosition.X + x * cellSize,
			fromPosition.Y,
			fromPosition.Z + z * cellSize
		)
	end

	local function heuristic(x, z)
		local dx = targetGridX - x
		local dz = targetGridZ - z
		return math.sqrt(dx * dx + dz * dz)
	end

	local heap = {}
	local function heapPush(node)
		heap[#heap + 1] = node
		local index = #heap
		while index > 1 do
			local parent = math.floor(index / 2)
			if heap[parent].f <= node.f then
				break
			end
			heap[index] = heap[parent]
			index = parent
		end
		heap[index] = node
	end

	local function heapPop()
		if #heap == 0 then
			return nil
		end
		local first = heap[1]
		local last = table.remove(heap)
		if #heap > 0 then
			local index = 1
			while true do
				local left = index * 2
				local right = left + 1
				if left > #heap then
					break
				end
				local child = right <= #heap and heap[right].f < heap[left].f and right or left
				if heap[child].f >= last.f then
					break
				end
				heap[index] = heap[child]
				index = child
			end
			heap[index] = last
		end
		return first
	end

	local scores = { [startKey] = 0 }
	local parents = {}
	local coordinates = { [startKey] = { 0, 0 } }
	local pointClearCache = { [startKey] = true }
	local edgeClearCache = {}
	local closed = {}
	local expanded = 0
	local goalKey
	heapPush({ key = startKey, x = 0, z = 0, g = 0, f = heuristic(0, 0) })

	local directions = {
		{ 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
		{ 1, 1, 1.414 }, { 1, -1, 1.414 }, { -1, 1, 1.414 }, { -1, -1, 1.414 },
	}

	while #heap > 0 and expanded < maxExpanded do
		local current = heapPop()
		if closed[current.key] or current.g ~= scores[current.key] then
			continue
		end
		closed[current.key] = true
		expanded += 1
		if expanded % 150 == 0 then
			RunService.Heartbeat:Wait()
			if session.cancelled then
				return nil
			end
		end

		local currentPoint = pointFor(current.x, current.z)
		local flatToTarget = Vector3.new(
			targetPosition.X - currentPoint.X,
			0,
			targetPosition.Z - currentPoint.Z
		)
		if flatToTarget.Magnitude <= cellSize * 1.75
			and isFlightSegmentClear(currentPoint, targetPosition, jar)
		then
			goalKey = current.key
			break
		end

		for _, direction in ipairs(directions) do
			local nextX = current.x + direction[1]
			local nextZ = current.z + direction[2]
			if nextX < minX or nextX > maxX or nextZ < minZ or nextZ > maxZ then
				continue
			end

			local nextKey = keyFor(nextX, nextZ)
			if closed[nextKey] then
				continue
			end

			local nextPoint = pointFor(nextX, nextZ)
			if pointClearCache[nextKey] == nil then
				pointClearCache[nextKey] = isRoutePointClear(nextPoint, jar)
			end
			if not pointClearCache[nextKey] then
				continue
			end

			local edgeKey = current.key < nextKey
				and (current.key .. "|" .. nextKey)
				or (nextKey .. "|" .. current.key)
			if edgeClearCache[edgeKey] == nil then
				edgeClearCache[edgeKey] = isFlightSegmentClear(currentPoint, nextPoint, jar)
			end
			if not edgeClearCache[edgeKey] then
				continue
			end

			local nextScore = current.g + direction[3]
			if scores[nextKey] == nil or nextScore < scores[nextKey] then
				scores[nextKey] = nextScore
				parents[nextKey] = current.key
				coordinates[nextKey] = { nextX, nextZ }
				heapPush({
					key = nextKey,
					x = nextX,
					z = nextZ,
					g = nextScore,
					f = nextScore + heuristic(nextX, nextZ),
				})
			end
		end
	end

	if not goalKey then
		log("Grid route exhausted after", expanded, "nodes")
		return nil
	end

	local reverseRoute = {}
	local currentKey = goalKey
	while currentKey and currentKey ~= startKey do
		local coordinate = coordinates[currentKey]
		reverseRoute[#reverseRoute + 1] = pointFor(coordinate[1], coordinate[2])
		currentKey = parents[currentKey]
	end

	local route = {}
	for index = #reverseRoute, 1, -1 do
		route[#route + 1] = reverseRoute[index]
	end
	route[#route + 1] = targetPosition
	route = simplifyTravelRoute(fromPosition, route, jar)
	if not areRouteSegmentsClear(fromPosition, route, jar) then
		return nil
	end

	log("Grid route expanded", expanded, "nodes")
	return route
end

local function computeTravelRoute(fromPosition, targetPosition, jar, routeLabel)
	routeLabel = routeLabel or "Honey"
	if not config.UsePathfinding or isFlightSegmentClear(fromPosition, targetPosition, jar) then
		return { targetPosition }, false
	end

	updateUIStatus(
		string.format("Wall detected - planning %s route", routeLabel),
		Color3.fromRGB(251, 191, 36)
	)
	local route = computeGridRoute(fromPosition, targetPosition, jar)
	if not route then
		-- Roblox navigation remains a fallback, but every returned segment must
		-- pass our own clearance rays before the carpet is allowed to move.
		local startPosition = getGroundRoutePosition(fromPosition, jar)
		local endPosition = getGroundRoutePosition(targetPosition, jar)
		local path = PathfindingService:CreatePath({
			AgentRadius = math.clamp(tonumber(config.PathAgentRadius) or 4, 2, 8),
			AgentHeight = 5,
			AgentCanJump = true,
			AgentCanClimb = true,
			AgentJumpHeight = 10,
			AgentMaxSlope = 89,
			WaypointSpacing = 5,
		})

		local computed = pcall(function()
			path:ComputeAsync(startPosition, endPosition)
		end)
		if computed and path.Status == Enum.PathStatus.Success then
			route = {}
			for index, waypoint in ipairs(path:GetWaypoints()) do
				if index > 1 then
					local lift = waypoint.Action == Enum.PathWaypointAction.Jump and 5 or 3
					route[#route + 1] = waypoint.Position + Vector3.new(0, lift, 0)
				end
			end

			if #route > 0 then
				route[#route + 1] = targetPosition
				route = simplifyTravelRoute(fromPosition, route, jar)
				if not areRouteSegmentsClear(fromPosition, route, jar) then
					route = nil
				end
			else
				route = nil
			end
		else
			log("Roblox pathfinding fallback failed", path.Status.Name)
		end
	end

	if not route then
		return nil, true
	end

	log("Planned", routeLabel, "route with", #route, "waypoints")
	updateUIStatus(
		string.format("%s route ready - %d waypoints", routeLabel, #route),
		Color3.fromRGB(147, 197, 253)
	)
	return route, true
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

local ANTI_RAGDOLL_STATES = {
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.PlatformStanding,
}
local BAD_RECOVERY_STATES = {
	[Enum.HumanoidStateType.Ragdoll] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
	[Enum.HumanoidStateType.Physics] = true,
}
local configuredAntiRagdollHumanoids = setmetatable({}, { __mode = "k" })

local function stabilizeHumanoid(humanoid, root, movementActive)
	if not config.AntiRagdoll or not humanoid or not root
		or not humanoid.Parent or not root.Parent
	then
		return
	end

	local state = humanoid:GetState()
	local severelyTilted = root.CFrame.UpVector.Y < 0.45
	local needsRecovery = BAD_RECOVERY_STATES[state] == true
		or humanoid.PlatformStand
		or severelyTilted
	if movementActive then
		humanoid.Sit = false
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
	end

	root.AssemblyAngularVelocity = Vector3.zero
	if needsRecovery then
		root.AssemblyLinearVelocity = Vector3.zero
		humanoid.PlatformStand = false
		humanoid.Sit = false
		humanoid.AutoRotate = true
		if severelyTilted then
			local flatLook = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
			if flatLook.Magnitude < 0.1 then
				flatLook = Vector3.new(0, 0, -1)
			end
			root.CFrame = CFrame.lookAt(root.Position, root.Position + flatLook.Unit, Vector3.yAxis)
		end
		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	elseif root.AssemblyLinearVelocity.Magnitude
		> math.max(50, tonumber(config.AntiFlingSpeedLimit) or 220)
	then
		-- Clamp unexpected launch impulses. Normal route velocity is reapplied by
		-- the movement loop on the next frame.
		root.AssemblyLinearVelocity = root.AssemblyLinearVelocity.Unit
			* math.max(50, tonumber(config.AntiFlingSpeedLimit) or 220)
	end
end

local function configureHumanoidAntiRagdoll(humanoid)
	if not config.AntiRagdoll or not humanoid or configuredAntiRagdollHumanoids[humanoid] then
		return
	end
	configuredAntiRagdollHumanoids[humanoid] = true

	local originalStates = {}
	for _, state in ipairs(ANTI_RAGDOLL_STATES) do
		local ok, enabled = pcall(function()
			return humanoid:GetStateEnabled(state)
		end)
		if ok then
			originalStates[state] = enabled
		else
			originalStates[state] = true
		end
		pcall(function()
			humanoid:SetStateEnabled(state, false)
		end)
	end

	local stateConnection = humanoid.StateChanged:Connect(function(_, newState)
		if BAD_RECOVERY_STATES[newState] then
			local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")
			stabilizeHumanoid(humanoid, root, false)
		end
	end)
	table.insert(session.connections, stateConnection)
	table.insert(session.cleanup, function()
		if humanoid.Parent then
			for state, enabled in pairs(originalStates) do
				pcall(function()
					humanoid:SetStateEnabled(state, enabled)
				end)
			end
		end
	end)
end

local function recoverHumanoidFor(humanoid, root, duration, holdPosition)
	if not config.AntiRagdoll then
		return
	end
	local deadline = os.clock() + math.max(0, duration or 0)
	repeat
		stabilizeHumanoid(humanoid, root, true)
		if holdPosition and root and root.Parent then
			root.AssemblyLinearVelocity = Vector3.zero
		end
		RunService.Heartbeat:Wait()
	until os.clock() >= deadline or session.cancelled
end

do
	local _, humanoid, root = getCharacter()
	if humanoid then
		configureHumanoidAntiRagdoll(humanoid)
		stabilizeHumanoid(humanoid, root, false)
	end

	table.insert(session.connections, LocalPlayer.CharacterAdded:Connect(function(character)
		task.spawn(function()
			local newHumanoid = character:WaitForChild("Humanoid", 5)
			local newRoot = character:WaitForChild("HumanoidRootPart", 5)
			if newHumanoid and newRoot and not session.cancelled then
				configureHumanoidAntiRagdoll(newHumanoid)
				stabilizeHumanoid(newHumanoid, newRoot, false)
			end
		end)
	end))
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
				recoverHumanoidFor(humanoid, character:FindFirstChild("HumanoidRootPart"), 0.22, false)
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
	local _, humanoid, root = getCharacter()
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		stabilizeHumanoid(humanoid, root, true)
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
	ArrivalDistance = %.2f,
	TestArrivalDistance = %.2f,
	CarpetSpeed = %d,
	UseGrapple = %s,
	AntiRagdoll = %s,
	AntiRagdollRecoverySeconds = %.2f,
	AntiFlingSpeedLimit = %.2f,
	UsePathfinding = %s,
	PathAgentRadius = %.2f,
	PathWaypointReach = %.2f,
	PathGridSize = %.2f,
	PathGridMargin = %.2f,
	PathMaxGridNodes = %d,
	PathStallSeconds = %.2f,
	ServerHopEnabled = %s,
	ServerHopStartDelay = %d,
	ServerHopIdleSeconds = %d,
	BeeEventCheckInterval = %.2f,
	RequeueOnTeleport = true,
}
loadstring(game:HttpGet(%q))()
]],
		tostring(config.Enabled == true),
		math.clamp(tonumber(config.ArrivalDistance) or 4.5, 1, 6),
		math.clamp(tonumber(config.TestArrivalDistance) or 5, 3, 6),
		math.floor(tonumber(config.CarpetSpeed) or 150),
		tostring(config.UseGrapple == true),
		tostring(config.AntiRagdoll == true),
		math.clamp(tonumber(config.AntiRagdollRecoverySeconds) or 0.6, 0.1, 2),
		math.max(50, tonumber(config.AntiFlingSpeedLimit) or 220),
		tostring(config.UsePathfinding == true),
		math.clamp(tonumber(config.PathAgentRadius) or 4, 2, 8),
		math.clamp(tonumber(config.PathWaypointReach) or 1.5, 0.75, 4),
		math.clamp(tonumber(config.PathGridSize) or 8, 6, 14),
		math.clamp(tonumber(config.PathGridMargin) or 80, 32, 160),
		math.floor(math.clamp(tonumber(config.PathMaxGridNodes) or 6000, 1000, 12000)),
		math.clamp(tonumber(config.PathStallSeconds) or 1.75, 0.75, 4),
		tostring(config.ServerHopEnabled == true),
		math.floor(tonumber(config.ServerHopStartDelay) or 5),
		math.floor(tonumber(config.ServerHopIdleSeconds) or 2),
		math.max(0.1, tonumber(config.BeeEventCheckInterval) or 0.5),
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

local function getExecutorRequestFunction()
	local environment = _G
	if type(getgenv) == "function" then
		pcall(function()
			environment = getgenv()
		end)
	end

	return (environment and (environment.request or environment.http_request))
		or request
		or http_request
		or (syn and syn.request)
		or (http and http.request)
		or (fluxus and fluxus.request)
end

local function requestServerListBody(url)
	local lastBody
	local lastError
	local requestFunction = getExecutorRequestFunction()

	if type(requestFunction) == "function" then
		local ok, response = pcall(requestFunction, {
			Url = url,
			Method = "GET",
			Headers = {
				Accept = "application/json",
				["Cache-Control"] = "no-cache",
			},
		})

		if ok and type(response) == "table" then
			local status = tonumber(response.StatusCode or response.Status)
			local body = response.Body or response.body
			if type(body) == "string" then
				lastBody = body
			end
			if status and status >= 200 and status < 300 and lastBody then
				return lastBody
			end
			lastError = status and ("HTTP " .. tostring(status)) or "Executor request failed"
		elseif ok and type(response) == "string" then
			return response
		else
			lastError = tostring(response)
		end
	end

	-- The second argument requests a fresh response on executors that implement
	-- the no-cache form of DataModel:HttpGet.
	local httpGetOk, httpGetBody = pcall(function()
		return game:HttpGet(url, true)
	end)
	if httpGetOk and type(httpGetBody) == "string" and httpGetBody ~= "" then
		return httpGetBody
	end

	return lastBody, lastError or tostring(httpGetBody)
end

local function decodeServerList(body)
	if type(body) ~= "string" or body == "" then
		return nil, "Empty public server response"
	end

	local decodeOk, response = pcall(HttpService.JSONDecode, HttpService, body)
	if not decodeOk or type(response) ~= "table" then
		return nil, "Public server response was not JSON"
	end

	if type(response.data) ~= "table" then
		local apiMessage
		if type(response.errors) == "table" and type(response.errors[1]) == "table" then
			apiMessage = response.errors[1].message
		end
		return nil, apiMessage or "Public server response had no data list"
	end

	return response
end

local function fetchServerPage(cursor)
	local cursorSuffix = ""
	if cursor and cursor ~= "" then
		cursorSuffix = "&cursor=" .. HttpService:UrlEncode(cursor)
	end

	-- Limit 50 avoids Roblox's known empty/invalid limit=100 responses. The
	-- numeric server-type route is retained as a fallback for API rollouts that
	-- reject the named Public route.
	local urls = {
		string.format(
			"https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=50%s",
			game.PlaceId,
			cursorSuffix
		),
		string.format(
			"https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=50%s",
			game.PlaceId,
			cursorSuffix
		),
		string.format(
			"https://games.roblox.com/v1/games/%d/servers/0?sortOrder=2&excludeFullGames=true&limit=50%s",
			game.PlaceId,
			cursorSuffix
		),
	}

	local lastError = "Public server request failed"
	local emptyResponse

	for attempt = 1, 2 do
		for _, url in ipairs(urls) do
			local body, requestError = requestServerListBody(url)
			local response, decodeError = decodeServerList(body)
			if response then
				if #response.data > 0 then
					return response
				end
				emptyResponse = response
			else
				lastError = requestError or decodeError or lastError
			end
		end

		if attempt < 2 then
			task.wait(0.5)
		end
	end

	return emptyResponse, emptyResponse and nil or lastError
end

local function findLowestPopulationServer()
	local bestUnvisited
	local bestAny
	local cursor
	local maxPages = math.clamp(tonumber(config.ServerHopMaxPages) or 1, 1, 10)

	local function isBetter(candidate, currentBest)
		return not currentBest
			or candidate.playing < currentBest.playing
			or (candidate.playing == currentBest.playing and candidate.id < currentBest.id)
	end

	for _ = 1, maxPages do
		local response, responseError = fetchServerPage(cursor)
		if not response then
			return nil, responseError
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
	local selected = bestUnvisited or bestAny
	if not selected then
		return nil, "No joinable public server was returned"
	end
	return selected, bestUnvisited and nil or "Visited pool exhausted"
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
	local useMatchmakingFallback = server == nil
	if useMatchmakingFallback then
		warn(
			"[AutoHoneyPickup] Server list unavailable; using public matchmaking:",
			lookupNote or "unknown response"
		)
	end

	local queued = queueScriptForTeleport()
	if not queued then
		warn("[AutoHoneyPickup] queue_on_teleport is unavailable; the script may need to be run again after hopping.")
	end

	if server then
		visitedServers[server.id] = true
	end
	local teleportData = {
		AutoHoneyVisitedServers = getVisitedServerList(server and server.id or nil),
	}

	if server then
		updateUIStatus(
			string.format("Hopping to %d/%d player server", server.playing, server.capacity),
			Color3.fromRGB(147, 197, 253)
		)
	else
		updateUIStatus("Server list blocked - using matchmaking", Color3.fromRGB(251, 191, 36))
	end

	local teleportOk, teleportError = pcall(function()
		if server then
			-- TeleportAsync is server-only. TeleportToPlaceInstance remains the
			-- client-capable API for joining a chosen public instance.
			TeleportService:TeleportToPlaceInstance(
				game.PlaceId,
				server.id,
				LocalPlayer,
				"",
				teleportData
			)
		else
			TeleportService:Teleport(game.PlaceId, LocalPlayer, teleportData)
		end
	end)

	if not teleportOk then
		session.serverHopActive = false
		warn("[AutoHoneyPickup] Server hop failed:", teleportError)
		updateUIStatus("Server hop failed - retrying later", Color3.fromRGB(248, 113, 113))
		return false
	end

	if lookupNote and not useMatchmakingFallback then
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
	configureHumanoidAntiRagdoll(humanoid)
	stabilizeHumanoid(humanoid, root, true)

	local carpet = useGrappleEngage and engageCarpet() or equipCarpet()
	if not carpet then
		return "no_carpet"
	end

	pcall(function()
		root.Anchored = false
	end)

	local startedAt = os.clock()
	local initialTarget = getJarPosition(jar)
	if not initialTarget then
		return "collected"
	end

	local route, usedPathfinding = computeTravelRoute(root.Position, initialTarget, jar, "Honey")
	if not route then
		stopMovement()
		updateUIStatus("No safe path to Honey - trying another", Color3.fromRGB(248, 113, 113))
		return "no_path"
	end

	local waypointIndex = 1
	local plannedTarget = initialTarget
	local bestWaypointDistance = math.huge
	local lastProgressAt = os.clock()
	local nextEquipAt = 0
	local nextSegmentCheckAt = 0
	local flightSpeed = math.max(1, tonumber(config.CarpetSpeed) or 150)
	local waypointReach = math.clamp(tonumber(config.PathWaypointReach) or 1.5, 0.75, 4)
	local replans = 0

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
			recoverHumanoidFor(
				humanoid,
				root,
				math.clamp(tonumber(config.AntiRagdollRecoverySeconds) or 0.6, 0.1, 2),
				true
			)
			return getJarPosition(jar) and "arrived" or "collected"
		end

		-- Honey can still be falling when first replicated. Recompute the complete
		-- route if its destination moved materially after the original plan.
		if (targetPosition - plannedTarget).Magnitude > 8 and replans < 2 then
			local newRoute, newUsedPathfinding = computeTravelRoute(root.Position, targetPosition, jar, "Honey")
			if not newRoute then
				stopMovement()
				return "no_path"
			end
			route = newRoute
			usedPathfinding = newUsedPathfinding
			waypointIndex = 1
			plannedTarget = targetPosition
			bestWaypointDistance = math.huge
			lastProgressAt = os.clock()
			replans += 1
		end

		-- Keep only the final destination synchronized with the live Honey model;
		-- all preceding points remain the predetermined obstacle-avoidance route.
		route[#route] = targetPosition
		local waypoint = route[waypointIndex]
		local waypointOffset = waypoint - root.Position
		local waypointDistance = waypointOffset.Magnitude

		while waypointIndex < #route and waypointDistance <= waypointReach do
			waypointIndex += 1
			waypoint = route[waypointIndex]
			waypointOffset = waypoint - root.Position
			waypointDistance = waypointOffset.Magnitude
			bestWaypointDistance = math.huge
			lastProgressAt = os.clock()
		end

		if os.clock() >= nextSegmentCheckAt then
			nextSegmentCheckAt = os.clock() + 0.2
			if not isFlightSegmentClear(root.Position, waypoint, jar) then
				if replans >= 2 then
					stopMovement()
					return "no_path"
				end
				local newRoute, newUsedPathfinding = computeTravelRoute(
					root.Position,
					targetPosition,
					jar,
					"Honey"
				)
				if not newRoute then
					stopMovement()
					return "no_path"
				end
				route = newRoute
				usedPathfinding = newUsedPathfinding
				waypointIndex = 1
				plannedTarget = targetPosition
				bestWaypointDistance = math.huge
				lastProgressAt = os.clock()
				replans += 1
				continue
			end
		end

		if os.clock() >= nextEquipAt then
			if not equipCarpet() then
				stopMovement()
				return "no_carpet"
			end
			nextEquipAt = os.clock() + 0.5
		end

		if waypointDistance < bestWaypointDistance - 0.25 then
			bestWaypointDistance = waypointDistance
			lastProgressAt = os.clock()
		end

		if os.clock() - lastProgressAt
			>= math.clamp(tonumber(config.PathStallSeconds) or 1.75, 0.75, 4)
		then
			if usedPathfinding and replans < 2 then
				local newRoute, newUsedPathfinding = computeTravelRoute(root.Position, targetPosition, jar, "Honey")
				if newRoute then
					route = newRoute
					usedPathfinding = newUsedPathfinding
					waypointIndex = 1
					plannedTarget = targetPosition
					bestWaypointDistance = math.huge
					lastProgressAt = os.clock()
					replans += 1
					continue
				end
			end
			stopMovement()
			return "stalled"
		end

		local segmentSpeed = math.min(flightSpeed, math.max(30, waypointDistance * 6))
		root.AssemblyLinearVelocity = waypointOffset.Unit * segmentSpeed
		root.AssemblyAngularVelocity = Vector3.zero
		stabilizeHumanoid(humanoid, root, true)
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
	configureHumanoidAntiRagdoll(humanoid)
	stabilizeHumanoid(humanoid, root, true)

	if not engageCarpet() then
		return false, "Carpet not found"
	end

	pcall(function()
		root.Anchored = false
	end)

	-- Mouse.Hit is on the clicked surface; lift the destination so the root does
	-- not aim below the floor.
	local destination = worldPosition + Vector3.new(0, 3, 0)
	local route = computeTravelRoute(root.Position, destination, nil, "Test")
	if not route then
		stopMovement()
		return false, "No safe path to test destination"
	end

	local speed = math.max(1, tonumber(config.CarpetSpeed) or 150)
	local waypointReach = math.clamp(tonumber(config.PathWaypointReach) or 1.5, 0.75, 4)
	local testArrivalDistance = math.clamp(tonumber(config.TestArrivalDistance) or 5, 3, 6)
	local waypointIndex = 1
	local bestWaypointDistance = math.huge
	local lastProgressAt = os.clock()
	local nextEquipAt = 0
	local nextSegmentCheckAt = 0
	local replans = 0
	local deadline = os.clock() + config.FlightTimeout

	while os.clock() < deadline do
		if session.cancelled then
			stopMovement()
			return false, "Cancelled"
		end

		if not humanoid.Parent or humanoid.Health <= 0 or not root.Parent then
			return false, "Character changed"
		end

		local destinationOffset = destination - root.Position
		if destinationOffset.Magnitude <= testArrivalDistance then
			stopMovement()
			recoverHumanoidFor(
				humanoid,
				root,
				math.clamp(tonumber(config.AntiRagdollRecoverySeconds) or 0.6, 0.1, 2),
				true
			)
			return true, "Test destination reached"
		end

		local waypoint = route[waypointIndex]
		local waypointOffset = waypoint - root.Position
		local waypointDistance = waypointOffset.Magnitude
		while waypointIndex < #route and waypointDistance <= waypointReach do
			waypointIndex += 1
			waypoint = route[waypointIndex]
			waypointOffset = waypoint - root.Position
			waypointDistance = waypointOffset.Magnitude
			bestWaypointDistance = math.huge
			lastProgressAt = os.clock()
		end

		if os.clock() >= nextSegmentCheckAt then
			nextSegmentCheckAt = os.clock() + 0.2
			if not isFlightSegmentClear(root.Position, waypoint, nil) then
				if replans >= 2 then
					stopMovement()
					return false, "Test route became blocked"
				end
				local newRoute = computeTravelRoute(root.Position, destination, nil, "Test")
				if not newRoute then
					stopMovement()
					return false, "No safe path to test destination"
				end
				route = newRoute
				waypointIndex = 1
				bestWaypointDistance = math.huge
				lastProgressAt = os.clock()
				replans += 1
				continue
			end
		end

		if os.clock() >= nextEquipAt then
			if not equipCarpet() then
				stopMovement()
				return false, "Carpet unequipped"
			end
			nextEquipAt = os.clock() + 0.5
		end

		if waypointDistance < bestWaypointDistance - 0.25 then
			bestWaypointDistance = waypointDistance
			lastProgressAt = os.clock()
		end
		if os.clock() - lastProgressAt
			>= math.clamp(tonumber(config.PathStallSeconds) or 1.75, 0.75, 4)
		then
			if replans < 2 then
				local newRoute = computeTravelRoute(root.Position, destination, nil, "Test")
				if newRoute then
					route = newRoute
					waypointIndex = 1
					bestWaypointDistance = math.huge
					lastProgressAt = os.clock()
					replans += 1
					continue
				end
			end
			stopMovement()
			return false, "Test route stalled after replanning"
		end

		local segmentSpeed = math.min(speed, math.max(30, waypointDistance * 6))
		root.AssemblyLinearVelocity = waypointOffset.Unit * segmentSpeed
		root.AssemblyAngularVelocity = Vector3.zero
		stabilizeHumanoid(humanoid, root, true)
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
			elseif result == "no_path" or result == "stalled" or result == "timeout" then
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
	subtitle.Text = "BEE EVENT: CHECKING"
	subtitle.TextColor3 = Color3.fromRGB(191, 219, 254)
	subtitle.TextSize = 10
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.Parent = header

	updateBeeEventIndicator = function(active)
		if not subtitle.Parent then
			return
		end

		if active == true then
			subtitle.Text = "BEE EVENT: ACTIVE"
			subtitle.TextColor3 = Color3.fromRGB(134, 239, 172)
		elseif active == false then
			subtitle.Text = "BEE EVENT: INACTIVE"
			subtitle.TextColor3 = Color3.fromRGB(253, 186, 116)
		else
			subtitle.Text = "BEE EVENT: CHECKING"
			subtitle.TextColor3 = Color3.fromRGB(191, 219, 254)
		end
	end

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
detectBeeEvent()
print("[AutoHoneyPickup] Running - waiting for Bee event Honey spawns.")

while not session.cancelled do
	local beeEventActive = detectBeeEvent()

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
					and (tonumber(config.ServerHopIdleSeconds) or 2)
					or (tonumber(config.ServerHopStartDelay) or 5)
				local remaining = math.max(0, requiredIdle - (now - waitAnchor))
				local retryReady = now - lastHopAttempt
					>= (tonumber(config.ServerHopRetrySeconds) or 3)

				if config.ServerHopEnabled and beeEventActive == true and remaining <= 0 and retryReady then
					hopToLowestPopulationServer()
				elseif config.ServerHopEnabled and beeEventActive == true then
					local displayedRemaining = math.ceil(math.max(
						remaining,
						(tonumber(config.ServerHopRetrySeconds) or 3) - (now - lastHopAttempt)
					))
					if displayedRemaining ~= lastHopCountdown then
						lastHopCountdown = displayedRemaining
						local eventText = beeEventActive == true and "Bee active, no Honey"
							or (beeEventActive == false and "Bee event inactive" or "Checking Bee event")
						updateUIStatus(
							string.format("%s - hopping in %ds", eventText, displayedRemaining),
							Color3.fromRGB(148, 163, 184)
						)
					end
				elseif config.ServerHopEnabled then
					local waitingState = beeEventActive == false and "inactive" or "checking"
					if lastHopCountdown ~= waitingState then
						lastHopCountdown = waitingState
						updateUIStatus(
							beeEventActive == false
								and "Bee event inactive - hopper waiting"
								or "Confirming Bee event - hopper waiting",
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
for _, cleanup in ipairs(session.cleanup) do
	pcall(cleanup)
end
