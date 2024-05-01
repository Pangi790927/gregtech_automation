help = {}

-- 49x14 CxL

maxline = 
"--------------------------------------------------"

help.helper_texts = {
"USAGE MANUAL\n" ..
"\n" ..
"For now the main program will not do anything\n" ..
"more than to print the instructions.\n" ..
"To run the program you will need to use the lua\n" ..
"interpreter, by using the \"lua\" command inside\n" ..
"the terminal. By example:\n" ..
"    /home # lua\n" ..
"\n" ..
"Once inside the lua program, the prompt will\n" ..
"change to:\n" ..
"    lua>\n" ..
"\n" ..
"Press any key or press enter for the next page\n" ..
""
,
"The first thing that you need to do in the lua\n" ..
"interpreter is to load the crafter library.\n" ..
"Use the following command:\n" ..
"   lua> require(\"gtnh_crafter\")\n" ..
"After loading the library you can give crafting\n" ..
"commands to the PC. To do that use the function\n" ..
"craft_recipe(name, cnt), for example:\n" ..
"   lua> craft_recipe(\"advanced_circuit\", 9)\n" ..
"You can use middle mouse button click to paste\n" ..
"from your clipboard. \n" ..
"If there are not enough items to craft the\n" ..
"requested query you must supply them by placing\n" ..
"them in THE chest.\n" ..
"Press any key or press enter for the next page\n" ..
""

,
"The function can be then called again to start\n" ..
"the crafting. Usually you would call the\n" ..
"crafting function, supply the missing materials\n" ..
"and call it again until the crafting starts.\n" ..
"If the program mallfunctions you can retry\n" ..
"the same query again and maybe it helps...\n" ..
"\n" ..
"IMPORTANT: whatever the malfunction, check\n" ..
"to see if the 9 machines, are still there, if\n" ..
"not, call the maintanance guy.\n" ..
"\n" ..
"The next pages heve a list of crafting recipes.\n" ..
"\n" ..
"Press any key or press enter for the next page\n" ..
""

,
"1.  integrated_logic_circuit\n" ..
"2.  advanced_circuit\n" .. 
"3.  copper_foil\n" ..
"4.  circuit_board\n" ..
"5.  tin_bolt\n" ..
"6.  fine_copper_wire\n" ..
"7.  fine_annealed_copper_wire\n" ..
"8.  diode\n" ..
"9.  1x_annealed_copper_wire\n" ..
"10. integrated_logic_circuit_(wafer)\n" ..
"11. silver_bolt\n" ..
"12. fine_gold_wire\n" ..
"\n" ..
"Press any key or press enter for the next page\n" ..
""

,
"13. gold_foil\n" ..
"14. fine_electrum_wire\n" ..
"15. annealed_copper_bolt\n" ..
"16. smd_resistor\n" .. 
"17. iron_iii_chloride\n" .. 
"18. hydrochloric_acid_cell\n" .. 
"19. good_circuit_board\n" .. 
"20. good_integrated_circuit\n" .. 
"21. integrated_logic_circuit2\n" .. 
"22. gallium_foil\n" .. 
"23. random_access_memory_chip_\n(wafer)" .. 
"24. random_access_memory_chip\n" .. 
"\n" ..
"Press any key or press enter for the next page\n" ..
""

,
"25. smd_transistor\n" .. 
"\n" ..
"\n" ..
"\n" ..
"\n" ..
"\n" ..
"\n" ..
"\n" ..
"\n" ..
"\n" ..
"\n" ..
"\n" ..
"\n" ..
"Press any key or press enter for the next page\n" ..
""

-- "------------\n" ..
-- "------------\n" ..
-- "------------\n" ..
-- "------------\n" ..
-- "------------\n" ..
-- ""
-- ,
-- "------------\n" ..
-- "------------\n" ..
-- "------------\n" ..
-- "------------\n" ..
-- "------------\n" ..
-- ""
}

return help