-- todo: rename programs as gtnh_*.lua and libs at gtl_*.lua

shell = require("shell")

file_list = {
	"gtnh_crafter.lua",
	"gtnh_reciper.lua",
	"helpers.lua",
	"hw_crafting.lua",
	"hw_interface.lua",
	"item_helper.lua",
	"recipe_db.lua",
	"main.lua",
	"update.lua",
	"help.lua"
	"gtnh_ae2ex.lua",
	"crc32.lua",
	"nbt.lua",
	"deflate.lua",
	"gtnh_ae2recieper.lua"
}

for k,f in ipairs(file_list) do
	shell.execute("rm /home/" .. f)
	shell.execute("wget https://github.com/Pangi790927/gregtech_automation/raw/main/" .. f)
end

shell.execute("reboot")