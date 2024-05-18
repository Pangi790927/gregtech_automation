local th = require("thread_helper")

local reciper2crafter = th.create_channel("r2c")
local crafter2reciper = th.create_channel("c2r")
local random_buss = th.create_channel("randbus")

function main_reciper()
	while (true) do
		os.sleep(1)
		th.tprint("Will send a message to the crafter")
		reciper2crafter.send("[DO WORK]")
		local some_chann = th.wait_any(crafter2reciper, random_buss, th.rs_chann)
		if some_chann.name == "c2r" then
			local msg = some_chann.recv()
			th.tprint("Message from crafter: " .. msg)
		else
			th.tprint("HUH?")
		end
	end
end

function main_crafter()
	while (true) do
		local msg = reciper2crafter.recv()
		th.tprint("Message from reciper: " .. msg)
		th.tprint("Will send a message to the reciper")
		os.sleep(1)
		crafter2reciper.send("[DONE WORK]")
		-- x.dox()
	end
end

local t1 = th.create_thread(main_crafter)
local t2 = th.create_thread(main_reciper)

th.handle_threads()
