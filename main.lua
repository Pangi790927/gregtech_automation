h = require("helpers")
help = require("help")

for k,v in ipairs(help.helper_texts) do
	print(v)
	h.wait_key()
end
