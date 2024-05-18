local thread 	= require("thread")
local ev 		= require("event")

local th = {}

th.managed_threads = {}

function th.tprint(str)
	ev.push("gtnh_print", str)
end

function th.abort()
	ev.push("gtnh_abort")
end

function th.err_msg()
	th.tprint(debug.traceback())
end

function th.create_thread(fn)
	local new_th = thread.create(function ()
		local ok, result = xpcall(fn, th.err_msg)
		if not ok then
			th.tprint("ERR_RESULT: " .. tostring(result))
		end
	end)
	table.insert(th.managed_threads, new_th)
	return new_th
end

function th.kill_all()
	for i, v in ipairs(th.managed_threads) do
		v:kill()
	end
end

function th.create_channel(name)
	-- This may be the most horific way to do this, but I don't think I care
	local chann = {}

	chann.name = name
	chann._name = "gtnh_event_" .. name .. "_" .. tostring(math.random(0, 65535))

	chann.send = function(msg)
		table.insert(chann._queue, msg)
		ev.push(chann._name)
	end
	
	chann.recv = function()
		-- assuming events can't come between the if and the pull 
		while #chann._queue == 0 do
			ev.pull(chann._name)
		end
		return table.remove(chann._queue, 1)
	end

	chann._queue = {}

	return chann
end

function th.wait_any(...)
	local channels = { ... }
	while true do
		local chann_ids = {}
		local any_event = false
		for i, v in ipairs(channels) do
			table.insert(chann_ids, v._name)
			if #v._queue > 0 then
				any_event = true
				break
			end
		end
		if any_event then
			break
		end
		ev.pullMultiple(table.unpack(chann_ids))
	end
	for i, v in ipairs(channels) do
		if #v._queue > 0 then
			return v
		end
	end
end

-- Only one thread should ever listen to this channel
th.rs_chann = th.create_channel("redstone")

function th.handle_threads()
	while true do
		local registered_events = {
			"interrupted", "redstone",
			"gtnh_abort", "gtnh_print"
		}
		local name, var = ev.pullMultiple(table.unpack(registered_events))
		if name == "interrupted" or name == "gtnh_abort" then
			print("will exit [" .. name .. "]")
			th.kill_all()
			return
		elseif name == "redstone" then
			-- Do stuff with redstone 
			th.rs_chann.send("redstone_changed_event")
		elseif name == "gtnh_print" then
			print("MSG: " .. var)
		else
			print("Recived an unknown message, will exit")
			th.kill_all()
			return
		end
	end
end

return th