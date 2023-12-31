local Packages = script.Parent

local TableUtil = require(Packages.TableUtil)
local Observe = require(Packages.Observe)
local Promise = require(Packages.Promise)
local Trove = require(Packages.Trove)

--- @class Runtime
local Runtime = {}
Runtime.__index = Runtime

--- Constructs a new [[Runtime]].
function Runtime.new()
	local self = setmetatable({}, Runtime)

	self._isRunning = false

	self._bindHandlers = {}
	self._trove = Trove.new()

	self._startupScheduler = Promise.new(function(resolve, reject)
		self._doStart = resolve
	end)

	return self
end

--- Destroys the runtime when the server closes.
--- Note: This binding cannot be undone, as Roblox lacks the functionality to remove it.
function Runtime:BindToClose()
	-- When the server is shutting down, destroy the runtime
	game:BindToClose(function()
		self:Destroy()
	end)
end

--- Returns whether or not the runtime is running.
function Runtime:IsRunning()
	return self._isRunning
end

--- Adds a handler for a given pattern. If the pattern matches a module's path when being added, the callback will be used.
--- Only one handler may be "bound" on an module. Handlers may still execute without binding.
--- A return value of `false` indicates that the handler should not bind, regardless of the fact that it matched.
--- Handlers may not be added to runtimes which have already been started.
--[=[ Here's a simple example for matching services:
	```
	runtime:Handle("^.-Service$", function(module: Instance, Module: any)
		-- If the service has a Start method
		if Module.Start and typeof(Module.Start) == "function" then
			-- Add the service to the scheduler
			runtime:OnStart():andThenCall(Module.Start, Module)
		end

		-- If the service has a Stop method
		if Module.Stop and typeof(Module.Stop) == "function" then
			-- Return a function which shuts down the service when the runtime is shut down.
			return function()
				Module:Stop()
			end
		end

		-- Return nothing, there is no cleanup to be done on shutdown.
		return
	end)
	```
]=]
--- @param priority -- The priority of the handler.
--- @param callback -- The callback to run when a module is matched.
function Runtime:Handle(pattern: string, callback: (Module: any) -> (false | () -> ())?, priority: number?): () -> ()
	assert(not table.isfrozen(self._bindHandlers), "The runtime cannot have any more handlers added.")

	local index = #self._bindHandlers + 1

	if priority then
		-- If a priority is specified, determine at which location to place the new bind handler
		index = TableUtil.Reduce(self._bindHandlers, function(currentIndex, handler, handlerIndex)
			-- If the new handler should take priority
			if handler.Priority and priority > handler.Priority then
				-- Select the inspected index if it's smaller than the current index
				return math.min(currentIndex, handlerIndex)
			end

			-- Return the current handler index
			return currentIndex
		end, index)
	end

	-- Create the handler
	local handler = {
		Pattern = pattern;
		Callback = callback;
		Priority = priority;
	}

	-- Insert the bind handler at the index
	table.insert(self._bindHandlers, index, handler)

	-- Return cleanup function
	return function()
		if not handler then
			return
		end

		local index = table.find(self._bindHandlers, handler)
		if index then
			table.remove(self._bindHandlers, index)
			handler = nil :: any
		end
	end
end

function Runtime:_add(instance: Instance): (() -> ())?
	if instance:IsA("ModuleScript") then
		-- If the instance is a module
		local Module = require(instance)
		local modulePath = instance:GetFullName()

		-- Attempt to match each handler sequentially
		for _, handler in self._bindHandlers do
			local pattern = handler.Pattern
			local callback = handler.Callback

			-- If the module does not match the handler, skip
			if not string.match(modulePath, pattern) then
				continue
			end

			-- Call the handler & collect the cleanup callback
			local cleanup = callback(instance, Module)

			-- Add the cleanup callback to the trove
			if typeof(cleanup) == "function" then
				return cleanup
			end

			-- The pattern matched. Break unless the result is `false`.
			if cleanup ~= false then
				break
			end
		end
	end

	-- Return nothing, there is nothing to clean up
	return
end

--- Adds an instance to the runtime. Only `ModuleScript`s are considered.
--- May return a cleanup method, which will also be called when the runtime is shut down.
function Runtime:Add(instance: Instance): (() -> ())?
	assert(self._startupScheduler, "The Runtime is destroyed.")

	-- Add the instance and collect the cleanup function
	local cleanup = self:_add(instance)

	-- If a cleanup function is provided, add it to the trove
	if cleanup then
		self._trove:Connect(instance.Destroying, cleanup)
		return self._trove:Add(cleanup)
	end

	-- No cleanup function was produced when adding the instance
	return
end

--- Adds all of an instance's descendants to the runtime.
--- Returns a function which cleans up the instances.
function Runtime:AddDescendants(instance: Instance): () -> ()
	assert(self._startupScheduler, "The Runtime is destroyed.")

	return self._trove:Add(Observe.ObserveDescendants(instance, function(instance)
		return self:_add(instance)
	end))
end

--- Starts the runtime. Instances may continue to be added and removed.
--- If you would like to "restart" a runtime, you should define re-usable code which creates a new runtime instead of trying to re-use runtimes.
function Runtime:Start()
	local doStart = self._doStart
	self._isRunning = true
	self._doStart = nil

	-- Freeze bind handlers
	table.freeze(self._bindHandlers)

	if doStart then
		doStart()
	end

	return self._startupScheduler
end

--- Returns a promise which is resolved when the runtime has started. A rejected promise will be returned if the Runtime is destroyed.
function Runtime:OnStart()
	return self._startupScheduler or Promise.reject("The Runtime is destroyed.")
end

--- Stops the runtime, making it completely immutable.
function Runtime:Stop()
	self._trove:Clean()
	self._trove = nil
	self._isRunning = false
	self._startupScheduler = nil
	table.freeze(self)
end

--- Calls [[`Runtime:Stop()`]].
function Runtime:Destroy()
	self:Stop()
end

return Runtime