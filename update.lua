shell = require("shell")

file_list = {
    "helpers.lua",
    "hw_crafting.lua",
    "hw_interface.lua",
    "item_helper.lua",
    "update.lua",
    "gtnh_ae2ex.lua",
    "crc32.lua",
    "nbt.lua",
    "deflate.lua",
    "gtnh_item_router.lua",
    "thread_helper.lua"
}

for k,f in ipairs(file_list) do
    shell.execute("rm /home/" .. f)
    shell.execute("wget https://github.com/Pangi790927/gregtech_automation/raw/main/" .. f)
end

shell.execute("reboot")
