local lib = require("neotest.lib")

--- @param file_path string
local function get_package_name(file_path)
	for _, line in ipairs(lib.files.read_lines(file_path)) do
		local package = line:match("^package ([^;]+);")
		if package then
			return package
		end
	end
	return ""
end

return {
	get_package_name = get_package_name,
}
