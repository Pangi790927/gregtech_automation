item_helper = {}

function item_helper.label2cell_label(label)
	return label .. "_cell"
end

function item_helper.is_cell_label(label)
	local cell_str = "_cell"
	return label:sub(-#cell_str) == cell_str
end

function item_helper.get_cell_label_fluid_name(label)
	local cell_str = "_cell"
	local liq_label = label:sub(1, #label - #cell_str)
	return liq_label
end

function item_helper.is_cell(item)
	local label = string.lower(item.label)
	local cell_str = " cell"
	return label:sub(-#cell_str) == cell_str
end

function item_helper.get_cell_fluid_name(item)
	local label = string.lower(item.label)
	local cell_str = " cell"
	label = label:sub(1, #label - #cell_str)
	local ret = label:gsub(" ", "_")
	return ret
end

function item_helper.get_fluid_cell_name(item)
	local label = string.lower(item.label)
	return label .. "_cell"
end

function item_helper.name_format(name)
	local label = string.lower(name)
	local ret = label:gsub(" ", "_")
	return ret
end

function item_helper.get_name(item)
	if not item then
		return nil
	end
	local ret = item_helper.name_format(item.label)
	if ret == "integrated_logic_circuit" then
		if item.name == "gregtech:gt.metaitem.01" then
			ret = ret .. "2"
		end
	end
	return ret
end

function item_helper.count(item)
	return item.size
end

return item_helper
