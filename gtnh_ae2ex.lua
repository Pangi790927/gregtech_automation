h       = require("helpers")
thread  = require("thread")
event   = require("event")
ser     = require("serialization")
fs      = require("filesystem")
deflate = require("deflate")
nbt     = require("nbt")

local crafting_registrations = {}
local crafting_recipes = {}

local requests_path = "/home/requests.db"
local crafts_path = "/home/crafts.db"

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
    LOG("registering recipe uid: %s", registration)

    crafts[registration.uid] = { registration }

    LOG("serialized: %d", ser.serialize(crafts))

    update_files()
end

-- This is the thread that receives the requests from the ae2 system and crafts them it will exit
-- on error and should be independent of the main_reciper, except from receiving crafting recipes
-- from it
function main_crafter()
    while true do
        -- TODO: event: redstone from the request chest
        local ev_name = event.pullMultiple("_added_recipe", "interrupted")

        if ev_name == "_added_recipe" then
            LOG("Received event")
            local registration = table.remove(crafting_registrations, 1)
            add_crafting_recipe(registration)
        elseif ev_name == "interrupted" then
            LOG("Program interupted")
            os.exit()
        end

        -- print("I'm still alive in the background")
        os.sleep(1)

        -- find the first label in the chest
        -- wait for as many from each recipe as stated by the label
        -- transfer the recipe to the crafting chest
        -- start the crafting process
    end
end

local pattern_slot = 20
local machine_slot = 23
local config_slot = 26
local liquid_in_slot = 38
local liquid_out_slot = 44

function read_recipe()
    local pattern = hwif.rchest_get(pattern_slot)
    local out = {}
    deflate.gunzip({input = pattern.tag, output = function(byte)out[#out+1]=string.char(byte)end})
    local r = nbt.readFromNBT(out)

    local uid = nil
    for i, v in ipairs(r["in"]) do
    	if v.tag then
    		if v.tag.InscribeName then
    			uid = v.tag.InscribeName
    		end
    	end
    end
    if not uid then
    	print("Pattern needs to have a label inside")
    	return nil
    else
    	print("Recipe uid: " .. uid)
    end

    local recipe = {}
    recipe.uid = uid
    recipe.batch = {}
    recipe.batch.inputs = {}

    return recipe

-- stack = hwif.rchest_get(1)
-- out = {}
-- deflate.gunzip({input = stack.tag,output = function(byte)out[#out+1]=string.char(byte)end})
-- r = nbt.readFromNBT(out)
-- r["in"] -- list of 
-- r["in"][1] -- first item
-- r["in"][1].tag.InscribeName


    -- TODO: after geting the nbt info, find the label, the items and construct the new pattern info,
    -- like in the return bellow.

    -- TODO: we make a great assumption here: the name in the pattern is the label in our crafting
    -- system
    -- TODO: make a database keeping the infos(msz, label...) for known items, when all the items
    -- from a recipe are known, register them and make crafting batches, instead of single craftings

    -- return {
    --     pattern_name="smart_glass",
    --     input_items={
    --         { name="name", cnt=2 }
    --     },
    --     output_items={
    --         { name="x", cnt=3 }
    --     }
    --     liq_in_name={cell_name="oxygen_cell", cnt=4, msz=144},
    --     liq_out_name=nil
    -- }
end

function create_batch()
    return {
        inputs={
            ["item_name"] = { as_liq=false, cnt=32 },
            ["liquid_name"] = { as_liq=true, cnt=1000 } -- msz is important for liquids, so read it
        },
        outs={
            { label="itemname", as_liq=false, cnt=32 }
            { label="liquid_name", as_liq=false, cnt=3000 }
        }
    }
end

-- This is the reciper, this will be used to add recipes into the system
function main_reciper()
    while true do
        io.write("> Configure the recipe and press enter: ")
        local r = io.read() -- TODO: replace with button wait
        
        -- 0. Read the recipe pattern
        local pattern_recipe = read_recipe()
        if pattern_recipe then
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

        -- -- TODO: remove temporary
        -- recipe["in"] = {{id=2, count=5}, {id=5, count=2}}
        -- recipe["out"] = {{id=7, count=1}}

        -- -- 1. Find the label inside the recipe and remove it from the recipe
        -- -- 2. Read the machine from the machine slot
        -- -- 3. Read the config from the config slot
        -- -- 4. Read the liquid from the input liquid slot
        -- -- 5. Read the liquid from the output liquid slot

        -- -- 6. Compose a recipe add request
        -- local registration = {}
        -- registration.recipe = h.copy(recipe)

        -- -- TODO: remove temporary
        -- registration.mach_id = 1
        -- registration.mach_cfg = 1
        -- registration.liq_in_id = 4
        -- registration.liq_out_id = -1

        -- -- 7. The name comming from the label
        -- registration.name = "A label name"

        -- TODO: print the recipe
        
    end
end

thread.create(main_reciper)
main_crafter()

-- 20 -> pattern
-- 23 -> machine
-- 26 -> config of machine
-- 38 -> input_liquid
-- 44 -> output_liquid

-- TODO: main program that waits for AE2 crafting requests

-- hwif = require("hw_interface")
-- deflate = require("deflate")
-- nbt = require("nbt")

-- stack = hwif.rchest_get(1)
-- out = {}
-- deflate.gunzip({input = stack.tag,output = function(byte)out[#out+1]=string.char(byte)end})
-- r = nbt.readFromNBT(out)
-- r["in"] -- list of 
-- r["in"][1] -- first item
-- r["in"][1].tag.InscribeName

-- ip = hwif.cchest_get(2)
-- out2 = {}
-- deflate.gunzip({input = ip.tag,output = function(byte)out2[#out2+1]=string.char(byte)end})
-- t2 = nbt.readFromNBT(out2)

-- 7206, 4, 4357
