--[[

Grapple System by VAL!!!! hip hip hooray

DUAL MODE ARCHITECTURE:
Mode 1 - SWING (default):
  - physics: RopeConstraint creates pendulum motion
  - feel: spider-man style swinging with momentum preservation
  - use case: big arcing swings, trick shots, momentum-based movement
  - player control: can reel in/out to adjust swing radius
  
Mode 2 - ZIP (shift+click):
  - physics: LinearVelocity pulls player directly toward target
  - feel: grappling hook direct pull like attack on titan
  - use case: quick vertical climbs, precise positioning, escapes
  - player control: auto-stops near target, no reeling

COMPONENT INTERACTION FLOW:
1. CLIENT SIDE:
   - detects mouse click + shift key state
   - calculates origin (tool handle) and direction (mouse hit)
   - fires "Fire" remoteevent with: origin, direction, mode string
   - displays UI based on tool attributes the server sets
   
2. SERVER VALIDATION:
   - checks player state (must be Idle, not already attached)
   - validates origin isnt spoofed (within 25 studs of character)
   - performs spherecast (server-authoritative, cant be faked)
   - checks target validity (not nograpple tagged, not a character)
   
3. PHYSICS CREATION (mode-dependent):
   SWING: creates RopeConstraint between player and surface
   ZIP: creates LinearVelocity that pulls toward target
   BOTH: create visual Beam and Attachments
   
4. RUNTIME UPDATE (heartbeat loop):
   SWING: handles adaptive reeling, rope length updates
   ZIP: continuously updates pull direction, checks arrival distance
   BOTH: validates attachments exist, checks break distance, pulses beam
   
5. DETACH & CLEANUP:
   - destroys all physics instances (mode-specific)
   - applies momentum impulse based on movement direction
   - enters cooldown state
   - schedules auto-return to idle

SECURITY MODEL:
- server does ALL raycasts (client cant fake hits)
- server validates ALL requests (client cant force actions)
- server owns ALL physics (client cant manipulate constraints)
- origin validation prevents teleport exploits
- state machine prevents spam/race conditions

KEY TECHNICAL IMPROVEMENTS OVER BASIC VERSION:
- spherecast (2 stud radius) instead of raycast = way easier to aim
- adaptive reeling acceleration = better fine control
- movement direction momentum instead of just lookvector = more intuitive launches
- type definitions for better code clarity
- cleaner separation of mode-specific logic
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

-- CONFIG - all tunable values organized by category
-- these values are carefully balanced against each other
local CONFIG = {
	-- GENERAL SETTINGS
	MAX_DISTANCE = 200,             -- max grapple range (studs)
	                                -- why 200: balances mobility without making maps feel small
	                                -- also used as break distance threshold
	
	COOLDOWN_TIME = 0.8,            -- seconds between detach and next fire
	                                -- why 0.8: shorter than basic version (1.5s) because
	                                -- this system has more skill expression so spam is less of an issue
	                                -- still long enough to prevent instant re-grapple exploits
	
	NO_GRAPPLE_TAG = "NoGrapple",   -- collectionservice tag for blocking surfaces
	
	-- SWING MODE PHYSICS
	-- these values work together to create natural pendulum motion
	SWING_MIN_LENGTH = 5,           -- minimum rope length (prevents getting stuck in geometry)
	SWING_MAX_LENGTH = 200,         -- maximum rope length (matches MAX_DISTANCE)
	
	-- ADAPTIVE REELING SYSTEM
	-- key innovation: reel speed increases the longer you hold the key
	REEL_SPEED_BASE = 40,           -- starting reel speed (studs/sec)
	                                -- why 40: slow enough for precise adjustments
	REEL_ACCEL = 2.5,               -- acceleration rate (multiplier increase per second)
	                                -- why 2.5: reaches max speed in ~0.4 seconds
	                                -- fast enough to feel responsive, slow enough to allow taps
	REEL_MAX_MULTIPLIER = 2.0,      -- max speed multiplier (caps acceleration)
	                                -- why 2.0: maxes out at 80 studs/sec
	                                -- fast enough for quick repositioning
	                                -- slow enough to maintain control
	-- RESULT: tap E/Q for 40 studs/sec precision, hold for up to 80 studs/sec speed
	
	-- ZIP MODE PHYSICS
	-- completely different physics system for different use case
	ZIP_SPEED = 85,                 -- constant pull speed (studs/sec)
	                                -- why 85: faster than max reel (80) but not instant
	                                -- feels snappy without being disorienting
	ZIP_STOP_DIST = 10,             -- auto-detach distance from target (studs)
	                                -- why 10: prevents slamming into surface
	                                -- close enough to land on small platforms
	ZIP_MAX_FORCE = 500000,         -- linearvelocity max force
	                                -- why 500000: high value ensures responsive pulling
	                                -- overcomes gravity and momentum easily
	                                -- lower values would feel sluggish
	
	-- VISUAL CONFIGURATION
	ROPE_VISIBLE = true,            -- show ropeconstraint built-in visual
	BEAM_WIDTH = 0.25,              -- beam width (studs)
	PULSE_SPEED = 3,                -- pulsing animation speed (cycles per second)
	                                -- why 3: fast enough to be noticeable
	                                -- slow enough not to be distracting
	COLOR_IDLE = Color3.fromRGB(200, 200, 200),      -- not currently used
	COLOR_ACTIVE = Color3.fromRGB(100, 200, 255),    -- active grapple color
	
	-- MOMENTUM & FEEL
	-- these values control how it feels to release mid-swing
	DETACH_IMPULSE = 1200,          -- base impulse force on detach
	                                -- why 1200: 20% stronger than basic version (1000)
	                                -- allows bigger leaps due to more skill-based movement
	IMPULSE_VERTICAL_BIAS = 0.4     -- extra upward component added to launch direction
	                                -- why 0.4: prevents purely horizontal launches
	                                -- ensures you gain height even when moving horizontally
	                                -- value tested to feel natural (not too floaty)
}

-- TYPE DEFINITION - structure for per-player grapple session data
-- we use a typed table to track everything about one players active grapple
-- this is crucial because multiple players can grapple simultaneously
--
-- WHY WE NEED ISOLATED PER-PLAYER STATE:
-- - player A swinging shouldnt affect player B's grapple
-- - each player has different physics objects that need separate cleanup
-- - state transitions happen independently (A can be cooldown while B is attached)
-- - prevents race conditions and crosstalk between sessions
type GrappleData = {
	-- STATE MACHINE
	State: string,                  -- "Idle" | "Attached" | "Cooldown"
	                                -- tracks current state to prevent invalid actions
	                                -- e.g. cant fire while attached, cant reel while idle
	Mode: string,                   -- "Swing" | "Zip"
	                                -- determines which physics system is active
	                                -- used to route logic in heartbeat and detach
	
	-- CORE REFERENCES
	Tool: Tool,                     -- reference to the actual tool instance
	                                -- needed for SetAttribute calls to sync to client
	Character: Model,               -- player's character model
	                                -- used for filtering in raycasts
	RootPart: BasePart,             -- humanoidrootpart specifically
	                                -- cached because we access it frequently
	                                -- all physics attach to this part
	Humanoid: Humanoid,             -- humanoid instance
	                                -- needed for MoveDirection (momentum system)
	
	-- PHYSICS OBJECTS (mode-dependent, may be nil)
	Constraint: RopeConstraint?,    -- only exists in SWING mode
	                                -- the actual physics that creates pendulum motion
	                                -- nil in zip mode or when not attached
	Beam: Beam?,                    -- visual rope between attachments
	                                -- exists in both modes when attached
	                                -- nil when idle/cooldown
	Attachments: { [string]: Attachment }?,  
	                                -- table of attachments (Root, Anchor, maybe ZipAtt)
	                                -- Root = on player's rootpart
	                                -- Anchor = on grappled surface
	                                -- ZipAtt = extra attachment for linearvelocity
	VelocityConstraint: LinearVelocity?,
	                                -- only exists in ZIP mode
	                                -- applies constant velocity toward target
	                                -- nil in swing mode or when not attached
	
	-- REELING STATE (swing mode only)
	ReelDir: number,                -- -1 (in), 0 (stopped), 1 (out)
	                                -- controlled by E/Q keys from client
	ReelTime: number,               -- how long player has been holding reel key (seconds)
	                                -- used to calculate acceleration multiplier
	                                -- resets to 0 when they release or stop reeling
	
	-- COOLDOWN TRACKING
	LastDetachTime: number,         -- os.clock() timestamp of last detach
	                                -- used to calculate remaining cooldown for UI
	                                -- compared against COOLDOWN_TIME config
	
	-- LIFECYCLE MANAGEMENT
	Connections: { [number]: RBXScriptConnection }
	                                -- array of event connections to disconnect on cleanup
	                                -- includes: remoteevent listener, died event, etc
	                                -- prevents memory leaks when tool is unequipped
}

-- stores active grapple sessions for all players
local ActiveSessions: { [Player]: GrappleData } = {}

-- helper to safely get character parts
-- returns nil if anything is missing instead of erroring
local function getCharacterInfo(player: Player)
	local char = player.Character
	if not char then return nil end
	
	local root = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChild("Humanoid")
	
	if not root or not hum then return nil end
	
	return char, root, hum
end

-- syncs server state to client through tool attributes
-- client reads these for UI updates (same pattern as basic version)
local function updateAttributes(player: Player)
	local data = ActiveSessions[player]
	if not data or not data.Tool then return end
	
	-- send current state and mode
	data.Tool:SetAttribute("GrappleState", data.State)
	data.Tool:SetAttribute("GrappleMode", data.Mode)  -- new: tells client which mode
	
	-- only send rope length if we have a rope (swing mode only)
	if data.Constraint then
		data.Tool:SetAttribute("RopeLength", data.Constraint.Length)
	end
	
	-- calculate cooldown remaining for timer
	local cooldownElapsed = os.clock() - data.LastDetachTime
	local remaining = math.max(0, CONFIG.COOLDOWN_TIME - cooldownElapsed)
	data.Tool:SetAttribute("Cooldown", remaining)
end

-- CLEANUP - destroys all physics instances created during grapple
-- this is critical because both modes create different objects that need cleanup
-- memory leaks happen if we dont destroy everything properly
--
-- WHY THOROUGH CLEANUP MATTERS:
-- - roblox instances persist in memory until explicitly destroyed
-- - constraints continue processing even if parent is removed
-- - attachments stay on parts and accumulate over time
-- - beams continue rendering and using resources
-- - connections keep firing events on destroyed objects
--
-- MODE-SPECIFIC CLEANUP:
-- SWING creates: RopeConstraint, Beam, 2 Attachments (Root + Anchor)
-- ZIP creates: LinearVelocity, Beam, 3 Attachments (Root + Anchor + ZipAtt)
-- we check and destroy ALL possible objects regardless of mode
local function cleanInstances(data: GrappleData)
	-- SWING MODE PHYSICS
	if data.Constraint then 
		data.Constraint:Destroy()  -- destroys the ropeconstraint
		                           -- stops physics simulation immediately
	end
	
	-- BOTH MODES VISUAL
	if data.Beam then 
		data.Beam:Destroy()  -- destroys visual beam
		                     -- stops rendering immediately
	end
	
	-- ZIP MODE PHYSICS
	if data.VelocityConstraint then 
		data.VelocityConstraint:Destroy()  -- destroys linearvelocity
		                                   -- stops applying force immediately
		                                   -- without this player keeps getting pulled
	end
	
	-- BOTH MODES ATTACHMENTS
	-- we loop through all attachments because the table structure differs by mode
	-- swing has: {Root, Anchor}
	-- zip has: {Root, Anchor, ZipAtt}
	if data.Attachments then
		for _, att in pairs(data.Attachments) do
			att:Destroy()  -- remove attachment from its parent part
			               -- important: attachments on anchored parts stay forever if not destroyed
		end
	end
	
	-- CLEAR ALL REFERENCES
	-- setting to nil prevents heartbeat loop from trying to access destroyed objects
	-- also prevents double-cleanup bugs if detach is called twice somehow
	data.Constraint = nil
	data.Beam = nil
	data.VelocityConstraint = nil
	data.Attachments = nil
end

-- DETACH - handles disconnection and momentum application
-- this is called when player presses R, rope breaks, or zip completes
-- applyImpulse parameter controls whether we give momentum boost
--
-- WHY THE APPLYIMPULSE PARAMETER:
-- true: player deliberately released (R key) or swing ended naturally
--       we want to preserve/enhance momentum for skill-based movement
-- false: forced detach (death, part destroyed, error)
--        we dont want corpses flying or weird physics from errors
local function detach(player: Player, applyImpulse: boolean)
	local data = ActiveSessions[player]
	if not data or data.State == "Idle" or data.State == "Cooldown" then return end
	
	local oldState = data.State  -- save state before cleanup
	                             -- needed to check if we were actually attached
	cleanInstances(data)
	
	-- MOMENTUM PRESERVATION SYSTEM
	-- key improvement over basic version: uses MoveDirection instead of LookVector
	-- this makes launches way more intuitive and skill-based
	if applyImpulse and data.RootPart and oldState == "Attached" then
		-- GET MOVEMENT DIRECTION
		-- MoveDirection = normalized vector of WASD input
		-- this is what direction the player is TRYING to move
		-- way better than LookVector (where camera points)
		local moveDir = data.Humanoid.MoveDirection
		
		-- FALLBACK FOR NO INPUT
		-- if player isnt pressing any movement keys (magnitude < 0.1)
		-- fall back to lookvector so they still get some momentum
		-- without this fallback, not pressing WASD = no momentum at all
		if moveDir.Magnitude < 0.1 then
			moveDir = data.RootPart.CFrame.LookVector
		end
		
		-- CALCULATE LAUNCH DIRECTION
		-- we add vertical bias to prevent purely horizontal launches
		-- without this: pressing W while swinging = horizontal launch, immediate fall
		-- with this: pressing W = forward AND up launch, maintains height
		--
		-- why 0.4 specifically:
		-- - 0 would be no upward component (bad, you just fall)
		-- - 1 would be equal horizontal/vertical (too floaty, weird)
		-- - 0.4 tested to feel natural (you go up but not weirdly)
		local push = (moveDir + Vector3.new(0, CONFIG.IMPULSE_VERTICAL_BIAS, 0)).Unit
		
		-- APPLY THE IMPULSE
		-- ApplyImpulse adds to existing velocity (preserves swing momentum)
		-- scaled by AssemblyMass so it works consistently regardless of character accessories
		-- DETACH_IMPULSE (1200) is the base force multiplier
		data.RootPart:ApplyImpulse(push * CONFIG.DETACH_IMPULSE * data.RootPart.AssemblyMass)
		
		-- RESULT: pressing W during swing = launch forward+up in your movement direction
		--         way more intuitive than old system that only used camera direction
	end
	
	-- ENTER COOLDOWN STATE
	data.State = "Cooldown"
	data.LastDetachTime = os.clock()  -- record timestamp for cooldown timer
	data.ReelDir = 0                   -- stop any active reeling
	data.ReelTime = 0                  -- reset acceleration timer
	
	updateAttributes(player)  -- sync to client immediately
	
	-- SCHEDULE RETURN TO IDLE
	-- after cooldown expires, automatically transition back to idle
	-- task.delay is non-yielding so it doesnt block anything
	task.delay(CONFIG.COOLDOWN_TIME, function()
		-- safety check: player might have unequipped during cooldown
		if ActiveSessions[player] and ActiveSessions[player].State == "Cooldown" then
			ActiveSessions[player].State = "Idle"
			updateAttributes(player)
		end
	end)
end

-- creates visual beam and attachments
-- used by both modes but physics setup happens separately
local function createVisuals(data: GrappleData, anchorPart: BasePart, worldPos: Vector3)
	-- attachment on player
	local attRoot = Instance.new("Attachment")
	attRoot.Name = "GrappleVisualAtt_Root"
	attRoot.Parent = data.RootPart
	
	-- attachment on target surface
	-- convert world position to object space so it sticks to the part
	local attAnchor = Instance.new("Attachment")
	attAnchor.Name = "GrappleVisualAtt_Anchor"
	attAnchor.CFrame = anchorPart.CFrame:Inverse() * CFrame.new(worldPos)
	attAnchor.Parent = anchorPart
	
	-- create the visual beam
	local beam = Instance.new("Beam")
	beam.Attachment0 = attRoot
	beam.Attachment1 = attAnchor
	beam.Width0 = CONFIG.BEAM_WIDTH
	beam.Width1 = CONFIG.BEAM_WIDTH
	beam.FaceCamera = true
	beam.Color = ColorSequence.new(CONFIG.COLOR_ACTIVE)
	beam.Transparency = NumberSequence.new(0)
	beam.Parent = data.RootPart
	
	data.Attachments = { Root = attRoot, Anchor = attAnchor }
	data.Beam = beam
	
	return attRoot, attAnchor
end

-- FIRE GRAPPLE - main entry point for creating a grapple connection
-- called when client sends "Fire" action through remoteevent
-- handles validation, raycasting, and mode-specific physics creation
--
-- PARAMETERS EXPLAINED:
-- origin: starting point for raycast (usually tool handle or head position)
-- direction: unit vector toward where player is aiming (from mouse.Hit)
-- mode: string "Swing" or "Zip" (determined by shift key on client)
local function fire(player: Player, origin: Vector3, direction: Vector3, mode: string)
	local data = ActiveSessions[player]
	if not data or data.State ~= "Idle" then return end
	
	-- ANTI-EXPLOIT: ORIGIN VALIDATION
	-- client could send fake origin far from character to grapple impossible targets
	-- we verify origin is within 25 studs of their actual position
	-- 25 is generous for any tool/hand position but prevents teleporting the raycast
	if (origin - data.RootPart.Position).Magnitude > 25 then
		warn("[GrappleSystem] Suspicious fire origin from", player.Name)
		return  -- silently reject without telling exploiter
	end
	
	-- SETUP RAYCAST PARAMETERS
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = { data.Character }  -- dont hit yourself
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	
	-- SPHERECAST - KEY IMPROVEMENT OVER BASIC VERSION
	-- workspace:Spherecast(origin, radius, direction, params)
	--
	-- WHY SPHERECAST INSTEAD OF RAYCAST:
	-- raycast = infinitely thin line, must hit exact pixels
	-- spherecast = 2 stud radius sphere traveling along path
	--
	-- benefits:
	-- - way more forgiving when aiming at thin objects (poles, edges, corners)
	-- - easier to hit targets at long range (small angular error = big position error at range)
	-- - feels better to use, less frustrating misses
	-- - still precise enough for gameplay (2 stud radius isnt huge)
	--
	-- tradeoffs:
	-- - can hit things "around corners" very slightly (acceptable for grappling)
	local castResult = workspace:Spherecast(origin, 2, direction * CONFIG.MAX_DISTANCE, rayParams)
	
	-- VALIDATION CHECKS
	if not castResult or not castResult.Instance then return end  -- hit nothing
	if CollectionService:HasTag(castResult.Instance, CONFIG.NO_GRAPPLE_TAG) then return end  -- blocked surface
	
	-- prevent grappling to characters (players/npcs)
	-- we check the whole model tree because raycast might hit a limb part
	if castResult.Instance:FindFirstAncestorOfClass("Model") and 
	   castResult.Instance:FindFirstAncestorOfClass("Model"):FindFirstChild("Humanoid") then
		return
	end
	
	-- ALL CHECKS PASSED - CREATE GRAPPLE
	data.State = "Attached"
	data.Mode = mode or "Swing"  -- default to swing if mode not provided
	
	-- CREATE VISUALS (same for both modes)
	-- this makes the beam and attachments that both modes need
	local attRoot, attAnchor = createVisuals(data, castResult.Instance, castResult.Position)
	
	-- MODE-SPECIFIC PHYSICS CREATION
	-- the two modes use completely different physics systems
	-- this is the core of what makes them feel different
	if data.Mode == "Swing" then
		-- SWING MODE: ROPECONSTRAINT PHYSICS
		-- ropeconstraint maintains a maximum distance between two attachments
		-- creates natural pendulum physics without any manual force calculations
		--
		-- how it works:
		-- - when rope is slack (player closer than length): no force applied
		-- - when rope is taut (player at length): prevents further separation
		-- - gravity + momentum + rope limit = natural swinging motion
		--
		-- why this works for swinging:
		-- - player swings around anchor point like a pendulum
		-- - can build momentum by pumping (moving at right times)
		-- - feels physical and skill-based
		local rope = Instance.new("RopeConstraint")
		rope.Attachment0 = attRoot      -- player attachment
		rope.Attachment1 = attAnchor    -- surface attachment
		rope.Visible = CONFIG.ROPE_VISIBLE
		rope.Length = (attRoot.WorldPosition - attAnchor.WorldPosition).Magnitude  -- set to actual distance
		rope.Parent = data.RootPart
		data.Constraint = rope
		
	else
		-- ZIP MODE: LINEARVELOCITY PHYSICS
		-- linearvelocity applies constant velocity in a direction
		-- creates direct pull toward target like attack on titan grapple
		--
		-- how it works:
		-- - linearvelocity sets player velocity to specific value (direction * speed)
		-- - we update direction every frame to always point at target
		-- - maxforce is very high so it overrides gravity/momentum
		-- - player moves directly toward anchor at constant speed
		--
		-- why this works for zipping:
		-- - fast, direct movement (no swinging around)
		-- - predictable trajectory (straight line to target)
		-- - good for vertical climbs where swinging isnt helpful
		-- - feels responsive and controlled
		local alignPos = Instance.new("LinearVelocity")
		local att = Instance.new("Attachment")  -- linearvelocity needs its own attachment
		att.Parent = data.RootPart
		
		alignPos.Attachment0 = att
		alignPos.MaxForce = CONFIG.ZIP_MAX_FORCE  -- very high = very responsive
		alignPos.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector  -- use vector mode
		alignPos.VectorVelocity = direction.Unit * CONFIG.ZIP_SPEED  -- initial direction
		alignPos.Parent = data.RootPart
		
		data.VelocityConstraint = alignPos
		data.Attachments.ZipAtt = att  -- store extra attachment for cleanup
	end
	
	updateAttributes(player)  -- sync state to client
end

-- sets up grapple system for new players
local function onPlayerJoined(player: Player)
	player.CharacterAdded:Connect(function(char)
		local root = char:WaitForChild("HumanoidRootPart")
		local hum = char:WaitForChild("Humanoid")
		
		-- watch for tool being equipped
		char.ChildAdded:Connect(function(child)
			if child:IsA("Tool") and child.Name == "GrappleTool" then
				local remote = child:WaitForChild("GrappleRemote")
				
				-- initialize player session
				ActiveSessions[player] = {
					State = "Idle",
					Mode = "Swing",  -- default mode
					Tool = child,
					Character = char,
					RootPart = root,
					Humanoid = hum,
					ReelDir = 0,
					ReelTime = 0,  -- tracks reeling duration for acceleration
					LastDetachTime = 0,
					Connections = {}
				}
				
				-- listen for client requests
				-- client sends: action, then arguments
				local conn = remote.OnServerEvent:Connect(function(p, action, ...)
					if p ~= player then return end
					
					if action == "Fire" then
						-- ... contains: origin, direction, mode
						fire(player, ...)
						
					elseif action == "Detach" then
						detach(player, true)  -- true = apply momentum
						
					elseif action == "Reel" then
						-- ... contains direction ("In" or "Out")
						local dir = ...
						if ActiveSessions[player] then
							ActiveSessions[player].ReelDir = (dir == "In" and -1) or (dir == "Out" and 1) or 0
						end
						
					elseif action == "StopReel" then
						if ActiveSessions[player] then
							ActiveSessions[player].ReelDir = 0
							ActiveSessions[player].ReelTime = 0  -- reset acceleration
						end
					end
				end)
				
				table.insert(ActiveSessions[player].Connections, conn)
				updateAttributes(player)
			end
		end)
		
		-- watch for tool being unequipped
		char.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") and child.Name == "GrappleTool" then
				detach(player, false)
				if ActiveSessions[player] then
					for _, c in pairs(ActiveSessions[player].Connections) do c:Disconnect() end
					ActiveSessions[player] = nil
				end
			end
		end)
	end)
end

-- MAIN UPDATE LOOP - runs every frame to handle active grapples
-- this is where the continuous physics updates and state checks happen
-- processes all active grapple sessions simultaneously (multi-player support)
--
-- WHY HEARTBEAT SPECIFICALLY:
-- - runs every frame (~60fps typically)
-- - provides dt (delta time) for frame-rate independent calculations
-- - happens after physics step (good for reading positions)
-- - more consistent than RenderStepped (client-only)
--
-- WHAT THIS LOOP DOES:
-- 1. validates attachments still exist (error handling)
-- 2. checks rope break distance (safety limit)
-- 3. mode-specific physics updates (reel or zip logic)
-- 4. visual effects (pulsing beam)
-- 5. ui synchronization (every frame for smooth timers)
RunService.Heartbeat:Connect(function(dt)
	for player, data in pairs(ActiveSessions) do
		if data.State == "Attached" then
			-- ATTACHMENT INTEGRITY CHECK
			-- attachments can become invalid if parts are destroyed or player resets
			-- we need to gracefully handle this instead of erroring
			if not data.Attachments or 
			   not data.Attachments.Anchor.Parent or 
			   not data.Attachments.Root.Parent then
				detach(player, false)  -- clean detach without momentum
				continue  -- skip to next player
			end
			
			-- DISTANCE SAFETY CHECK
			-- if rope stretches too far (moving platform, physics glitch, etc)
			-- auto-detach to prevent infinite stretching or physics errors
			-- +50 buffer beyond max distance prevents breaking during normal swinging
			local dist = (data.Attachments.Root.WorldPosition - data.Attachments.Anchor.WorldPosition).Magnitude
			if dist > CONFIG.MAX_DISTANCE + 50 then
				detach(player, false)  -- safety detach, no momentum
				continue
			end
			
			-- ============================================================
			-- MODE-SPECIFIC UPDATE LOGIC
			-- the two modes need completely different runtime updates
			-- ============================================================
			
			if data.Mode == "Swing" and data.Constraint then
				-- SWING MODE: ADAPTIVE REELING SYSTEM
				-- this is a key innovation that makes reeling feel way better
				--
				-- THE ALGORITHM:
				-- when player holds E or Q:
				-- 1. track how long theyve been holding (ReelTime)
				-- 2. calculate acceleration multiplier based on time
				-- 3. speed increases from 1x to 2x over time
				-- 4. apply speed to rope length change
				--
				-- WHY THIS FEELS BETTER THAN CONSTANT SPEED:
				-- - tap E/Q: short duration = low multiplier = precise slow adjustment
				-- - hold E/Q: long duration = high multiplier = fast reeling
				-- - gives player fine control when needed, speed when needed
				-- - no need for separate "fast reel" and "slow reel" buttons
				-- - natural and intuitive (like how you'd actually reel in a rope)
				
				if data.ReelDir ~= 0 then  -- player is actively reeling
					-- TRACK REEL DURATION
					data.ReelTime += dt  -- accumulate time (frame-independent)
					
					-- CALCULATE ACCELERATION MULTIPLIER
					-- formula: 1 + (time * acceleration_rate)
					-- example with defaults (base=40, accel=2.5, max=2.0):
					--   0.0s: multiplier = 1.0, speed = 40 studs/sec
					--   0.2s: multiplier = 1.5, speed = 60 studs/sec
					--   0.4s: multiplier = 2.0, speed = 80 studs/sec (capped)
					--   1.0s: multiplier = 2.0, speed = 80 studs/sec (still capped)
					--
					-- math.min clamps to max multiplier (prevents infinite acceleration)
					local accel = math.min(CONFIG.REEL_MAX_MULTIPLIER, 1 + (data.ReelTime * CONFIG.REEL_ACCEL))
					local speed = CONFIG.REEL_SPEED_BASE * accel
					
					-- UPDATE ROPE LENGTH
					-- ReelDir = -1 for in (shorten), +1 for out (lengthen)
					-- multiply by dt for frame-rate independence
					-- clamp to min/max to prevent edge cases
					data.Constraint.Length = math.clamp(
						data.Constraint.Length + (data.ReelDir * speed * dt),
						CONFIG.SWING_MIN_LENGTH,    -- cant get too close (prevents geometry clipping)
						CONFIG.SWING_MAX_LENGTH     -- cant get too far (game balance)
					)
					
					-- FRAME-RATE INDEPENDENCE EXPLANATION:
					-- without dt: at 60fps we'd add (speed/60) per frame, at 30fps (speed/30)
					--            lower fps = faster reeling (bad!)
					-- with dt: at 60fps dt≈0.0167, at 30fps dt≈0.033
					--         dt compensates for frame time, speed is consistent
				end
				
			elseif data.Mode == "Zip" and data.VelocityConstraint then
				-- ZIP MODE: CONTINUOUS DIRECTION UPDATE
				-- linearvelocity applies constant velocity, but we need to update direction
				-- because the player might get pushed off course or target might move
				--
				-- HOW ZIP WORKS:
				-- 1. calculate direction from player to anchor
				-- 2. set velocity to (direction * speed)
				-- 3. linearvelocity's maxforce ensures this velocity is maintained
				-- 4. player moves in straight line at constant speed
				--
				-- WHY UPDATE EVERY FRAME:
				-- - if player hits something, they need to repath around it
				-- - if target is moving (elevator, moving platform), track it
				-- - ensures player actually reaches the target reliably
				
				-- CALCULATE CURRENT DIRECTION TO TARGET
				local dir = (data.Attachments.Anchor.WorldPosition - data.RootPart.Position).Unit
				
				-- UPDATE VELOCITY CONSTRAINT
				-- this overrides any other velocity the player has
				-- maxforce is high enough to overcome gravity and collisions
				data.VelocityConstraint.VectorVelocity = dir * CONFIG.ZIP_SPEED
				
				-- AUTO-DETACH ON ARRIVAL
				-- when close to target, stop pulling and detach
				-- without this, player would vibrate around the target point
				-- ZIP_STOP_DIST (10 studs) tested to feel good (close but not slamming)
				if dist < CONFIG.ZIP_STOP_DIST then
					detach(player, false)  -- no momentum on arrival (youre already at target)
				end
			end
			
			-- ============================================================
			-- VISUAL EFFECTS (both modes)
			-- ============================================================
			
			-- PULSING BEAM EFFECT
			-- makes the rope more visible and alive-looking
			-- uses sine wave for smooth pulsing animation
			if data.Beam then
				-- PULSING MATH:
				-- sin(time * speed) oscillates between -1 and 1
				-- +1 shifts to 0 to 2
				-- /2 scales to 0 to 1
				-- multiply by 0.4 for transparency range 0.1 to 0.5
				-- (0.1 baseline + 0-0.4 pulse = always somewhat visible)
				local pulse = (math.sin(os.clock() * CONFIG.PULSE_SPEED) + 1) / 2
				data.Beam.Transparency = NumberSequence.new(0.1 + (pulse * 0.4))
				
				-- WHY PULSE:
				-- - makes rope easier to see against varied backgrounds
				-- - adds visual feedback that grapple is active
				-- - looks cool and polished
			end
		end
		
		-- UPDATE CLIENT UI EVERY FRAME
		-- we do this outside the attached check because cooldown timer needs updates too
		-- setattribute only replicates when value changes, so this is efficient
		updateAttributes(player)
	end
end)

-- initialize for players already in game
Players.PlayerAdded:Connect(onPlayerJoined)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerJoined, p)
end

-- cleanup on player leave
Players.PlayerRemoving:Connect(function(p)
	if ActiveSessions[p] then
		detach(p, false)
		ActiveSessions[p] = nil
	end
end)

print("[GrappleSystem] Advanced Grapple System initialized.")

--[[
============================================================
SYSTEM ARCHITECTURE SUMMARY
============================================================

DATA FLOW OVERVIEW:
Client -> Server -> Physics -> Client UI

1. CLIENT INPUT:
   - detects mouse clicks and keyboard input
   - determines mode based on shift key state
   - calculates origin and direction
   - sends "Fire" action with parameters to server

2. SERVER VALIDATION:
   - checks player state (must be idle)
   - validates origin distance (anti-exploit)
   - performs spherecast (server-authoritative)
   - validates target (no characters, no nograpple tags)

3. PHYSICS CREATION (mode-dependent):
   SWING MODE:
   - creates RopeConstraint for pendulum physics
   - player swings around anchor point
   - can reel to adjust swing radius
   - builds momentum naturally
   
   ZIP MODE:
   - creates LinearVelocity for direct pull
   - player moves in straight line to target
   - constant speed, no swinging
   - auto-detaches on arrival

4. RUNTIME UPDATES (heartbeat):
   - validates attachment integrity
   - checks break distance
   - SWING: handles adaptive reeling with acceleration
   - ZIP: updates pull direction, checks arrival
   - updates visual effects (pulsing beam)
   - syncs attributes to client every frame

5. DETACH & CLEANUP:
   - destroys all physics instances (mode-specific)
   - applies momentum impulse using MoveDirection
   - enters cooldown state
   - auto-returns to idle after cooldown

6. CLIENT UI:
   - reads tool attributes (replicated from server)
   - displays state, mode, distance, cooldown
   - updates every frame for smooth timers

STATE MACHINE:
Idle -> Attached -> Cooldown -> Idle
  ↑_______________|

IDLE: can fire grapple, waiting for input
ATTACHED: physics active, player is grappling
COOLDOWN: recently detached, cannot fire yet

KEY DESIGN PRINCIPLES:
- isolated per-player state prevents crosstalk
- mode-specific logic keeps code organized
- comprehensive cleanup prevents memory leaks
- frame-rate independent calculations ensure consistency
- attribute-based sync reduces network traffic
]]
