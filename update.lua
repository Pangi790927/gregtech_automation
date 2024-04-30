shell = require("shell")

file_list = {
	"gtnh_crafter.lua",
	"gtnh_reciper.lua",
	"helpers.lua",
	"hw_crafting.lua",
	"hw_interface.lua",
	"item_helper.lua",
	"recipe_db.lua",
	"cleanroom.lua",
	"main.lua",
	"update.lua",
}

for f in file_list do
	shell.execute("rm " .. f)
	shell.execute("wget https://raw.githubusercontent.com/Pangi790927/gregtech_automation/main/" .. f)
end
