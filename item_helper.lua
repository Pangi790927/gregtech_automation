item_helper = {}

function item_helper.label2cell_label(label)
	return label .. "_cell"
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

function item_helper.get_name(item)
	if not item then
		return nil
	end
	local label = string.lower(item.label)
	local ret = label:gsub(" ", "_")
	return ret
end

function item_helper.count(item)
	return item.size
end

return item_helper
