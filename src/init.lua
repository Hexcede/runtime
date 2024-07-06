--!strict
local Packages = script.Parent

local TableUtil = require(Packages.TableUtil)
local Observe = require(Packages.Observe)
local Future = require(Packages.Future)
local Trove = require(Packages.Trove)

export type HandlerCallback = (moduleInstance: ModuleScript, module: any) -> (false | () -> ())?

type Handler = {
	Pattern: string;
	Callback: HandlerCallback?;
	Priority: number?;
}

--- @class Runtime
local Runtime = {}
Runtime.__index = Runtime

--- @field OnStart Future
--- A [Future](https://util.redblox.dev/future.html) which completes when the runtime starts.

--- Constructs a new [[Runtime]]. Runtimes can only be used once and should be discarded if you plan to stop them before server shutdown.
function Runtime.new()
	local self = setmetatable({}, Runtime)

	self._isRunning = false
	self._isUsed = false

	self._bindHandlers = {}
	self._trove = Trove.new()

	self.OnStart = Future.new(function()
		self._startThread = coroutine.running()
		coroutine.yield()
	end)

	return self
end

export type Runtime = typeof(Runtime.new())

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
	runtime:Handle("^.-Service$", function(moduleInstance: ModuleScript, module: any)
		-- If the service has a Start method
		if module.Start and typeof(module.Start) == "function" then
			-- Add the service to the scheduler
			runtime.OnStart:After(function()
				module:Start()
			end)
		end

		-- If the service has a Stop method
		if module.Stop and typeof(module.Stop) == "function" then
			-- Return a function which shuts down the service when the runtime is shut down.
			return function()
				module:Stop()
			end
		end

		-- Return nothing, there is no cleanup to be done on shutdown.
		return
	end)

	-- Add the contents of the Server folder
	runtime:AddDescendants(ServerScriptService.Server)
	```
]=]
--- @param priority -- The priority of the handler.
--- @param callback -- The callback to run when a module is matched.
function Runtime:Handle(pattern: string, callback: HandlerCallback?, priority: number?): () -> ()
	assert(not table.isfrozen(self._bindHandlers), "The runtime cannot have any more handlers added.")

	local index = #self._bindHandlers + 1

	if priority then
		-- If a priority is specified, determine at which location to place the new bind handler
		index = TableUtil.Reduce(self._bindHandlers, function(currentIndex: number, handler: Handler, handlerIndex: number)
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
	local handler: Handler = {
		Pattern = pattern;
		Callback = callback;
		Priority = priority;
	}

	-- Insert the bind handler at the index
	table.insert(self._bindHandlers, index, handler)

	-- Define cleanup function
	local function doCleanup()
		local index = table.find(self._bindHandlers, handler)

		if index then
			table.remove(self._bindHandlers, index)
		end
	end

	return doCleanup
end

function Runtime:_add(instance: Instance): (() -> ())?
	-- Cancel if the instance isn't a module
	if not instance:IsA("ModuleScript") then
		return nil
	end

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
		local cleanup = callback(instance, require(instance) :: any)

		-- Add the cleanup callback to the trove
		if typeof(cleanup) == "function" then
			return cleanup
		end

		-- The pattern matched. Break unless the result is `false`.
		if cleanup ~= false then
			break
		end
	end

	-- There is nothing to clean up, return nothing
	return nil
end

--- Adds an instance to the runtime. Only `ModuleScript`s are considered.
--- May return a cleanup method, which will also be called when the runtime is shut down.
function Runtime:Add(instance: Instance): (() -> ())?
	assert(not self._isUsed, "The Runtime is destroyed.")

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
	assert(not self._isUsed, "The Runtime is destroyed.")

	return self._trove:Add(Observe.Descendants(instance, function(instance)
		return self:_add(instance)
	end))
end

--- Starts the runtime. Instances may continue to be added and removed.
--- If you would like to "restart" a runtime, you should define re-usable code which creates a new runtime instead of trying to re-use runtimes.
function Runtime:Start()
	self._isRunning = true
	local startThread = self._startThread
	self._startThread = nil

	-- Freeze bind handlers
	table.freeze(self._bindHandlers)

	-- Start the thread
	if startThread then
		coroutine.resume(startThread)
	end

	return self._startupScheduler
end

--- Stops the runtime, making it completely immutable.
function Runtime:Stop()
	self._isRunning = false
	self._isUsed = true
	self._trove:Clean()
	table.freeze(self)
end

--- Calls [[`Runtime:Stop()`]].
function Runtime:Destroy()
	self:Stop()
end

return Runtime