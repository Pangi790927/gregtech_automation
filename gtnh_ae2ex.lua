h    	= require("helpers")
thread 	= require("thread")
event	= require("event")
ser		= require("serialization")
fs 		= require("filesystem")

crafting_registrations = {}
crafting_recipes = {}

requests_path = "/home/requests.db"
crafts_path = "/home/crafts.db"

local rf = fs.open(requests_path, "r")
if rf then
	requests = ser.unserialize(rf:read(1000000000))
else
	requests = {}
end

local cf = fs.open(crafts_path)
if cf then
	crafts = ser.unserialize(cf:read(1000000000))
else
	crafts = {}
end

function update_files()
	local rf = fs.open(requests_path, "w")
	rf:write(ser.serialize(requests))
	rf:close()

	local cf = fs.open(crafts_path, "w")
	cf:write(ser.serialize(crafts))
	cf:close()
end

function add_crafting_recipe(registration)
	LOG("registering recipe for: %s", registration.name)

	crafts.registration = {registration}

	LOG("serialized: %d", ser.serialize(crafts))

	update_files()
end

-- This is the thread that receives the requests from the ae2 system and crafts them it will exit
-- on error and should be independent of the main_reciper, except from receiving crafting recipes
-- from it
function main_crafter()
	while true do
		local ev_name = event.pullMultiple("_added_recipe", "interrupted")

		if ev_name == "_added_recipe" then
			LOG("Received event")
			registration = table.remove(crafting_registrations, 1)
			add_crafting_recipe(registration)
		elseif ev_name == "interrupted" then
			LOG("Program interupted")
			os.exit()
		end

		-- print("I'm still alive in the background")
		os.sleep(1)
	end
end

-- This is the reciper, this will be used to add recipes into the system
function main_reciper()
	io.write("> Configure the recipe and press enter: ")
	local r = io.read() -- TODO: replace with button wait
	
	-- 0. Read the recipe pattern
	local recipe = {}

	-- TODO: remove temporary
	recipe["in"] = {{id=2, count=5}, {id=5, count=2}}
	recipe["out"] = {{id=7, count=1}}

	-- 1. Find the label inside the recipe and remove it from the recipe
	-- 2. Read the machine from the machine slot
	-- 3. Read the config from the config slot
	-- 4. Read the liquid from the input liquid slot
	-- 5. Read the liquid from the output liquid slot

	-- 6. Compose a recipe add request
	local registration = {}
	registration.recipe = h.copy(recipe)

	-- TODO: remove temporary
	registration.mach_id = 1
	registration.mach_cfg = 1
	registration.liq_in_id = 4
	registration.liq_out_id = -1

	-- 7. The name comming from the label
	registration.name = "A label name"

	-- TODO: print the recipe
	io.write("> Would you like to save the recipe [y/n]: ")
	r = io.read()
	if r == "y" or r == "Y" then
		table.insert(crafting_registrations, h.copy(registration))
		event.push("_added_recipe")
		LOGP("> Recipe sent to the crafting unit, please install the new recipe in the interface" ..
				" and clean the recipe editor slots.")
	else
		LOGP("> Recipe was not added, please clean the recipe editor before leaving.")
	end
end

thread.create(main_crafter)
while true do
	local status, err = pcall(main_reciper)
	if not status then
		LOGP("Shall exit")
		os.exit()
	end
end
