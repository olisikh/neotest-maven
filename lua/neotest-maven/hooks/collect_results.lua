local lib = require("neotest.lib")
local xml = require("neotest.lib.xml")
local logger = require("neotest-maven.logger")

local XML_FILE_SUFFIX = ".xml"
local STATUS_PASSED = "passed" --- see neotest.Result.status
local STATUS_FAILED = "failed" --- see neotest.Result.status

--- @param directory_path string
--- @param report_name_suffix string | nil
--- @return string[]
local function list_xml_files(directory_path, report_name_suffix)
	local xml_files = {}
	for part in directory_path:gmatch("([^:]+)") do
		local pattern = report_name_suffix and ("/*" .. report_name_suffix .. XML_FILE_SUFFIX) or ("/*" .. XML_FILE_SUFFIX)
		vim.list_extend(xml_files, vim.fn.glob(part .. pattern, false, true))
	end
	return xml_files
end

--- Searches for all files XML files in this directory (not recursive) and
--- parses their content as Lua tables using some Neotest utility.
---
--- @param directory_path string
--- @param report_name_suffix string | nil
--- @return table[] - list of parsed XML tables
local function parse_xml_files_from_directory(directory_path, report_name_suffix)
	local xml_files = list_xml_files(directory_path, report_name_suffix)
	if #xml_files == 0 then
		local suffix_message = report_name_suffix and (" for suffix '" .. report_name_suffix .. "'") or ""
		logger.warn("No XML test reports found in " .. directory_path .. suffix_message)
	else
		logger.debug(function()
			return "Parsing " .. #xml_files .. " XML test report(s) from " .. directory_path
		end)
	end

	return vim.tbl_map(function(file_path)
		local content = lib.files.read(file_path)
		if file_path:sub(-#XML_FILE_SUFFIX) == XML_FILE_SUFFIX then
			return xml.parse(content)
		end
	end, xml_files)
end

--- If the value is a list itself it gets returned as is. Else a new list will be
--- created with the value as first element.
--- E.g.: { 'a', 'b' } => { 'a', 'b' } | 'a' => { 'a' }
---
--- @param value any
--- @return table
local function asList(value)
	return (type(value) == "table" and #value > 0) and value or { value }
end

local function extract_before_parenthesis(input)
	-- Use pattern matching to find everything before the first '('
	local result = string.match(input, "^[^%(]+")
	return result
end

--- @param test_case_node table
--- @param report_name_suffix string | nil
local function strip_report_name_suffix(test_case_node, report_name_suffix)
	if not report_name_suffix or not test_case_node._attr or not test_case_node._attr.classname then
		return
	end

	test_case_node._attr.classname = test_case_node._attr.classname:gsub(vim.pesc(report_name_suffix) .. "$", "")
end

--- This tries to find the position in the tree that belongs to this test case
--- result from the JUnit report XML. Therefore it parses the location from the
--- node attributes and compares it with the position information in the tree.
---
--- @param tree table - see neotest.Tree
--- @param test_case_node table - XML node of test case result
--- @return table | nil - see neotest.Position
local function find_position_for_test_case(tree, test_case_node)
	local function_name_complete = test_case_node._attr.name:gsub("%(%)", "")
	local function_name = extract_before_parenthesis(function_name_complete)
	local package_and_class = (test_case_node._attr.classname:gsub("%$", "%."))

	for _, position in tree:iter() do
		if function_name == position.name and vim.startswith(position.id, package_and_class) then
			return position
		end
	end
end

--- Returns true if the test case is a parameterized test.
---@param test_case_node table
---@return boolean
local function is_parameterized_test(test_case_node)
	local function_name = test_case_node._attr.name
	local parameterized_test_pattern = "^.+%(.+%)%[.+%]$"
	return function_name:match(parameterized_test_pattern) ~= nil
end

local function extract_test_case_basename(test_case_node)
	local function_name = test_case_node._attr.name
	return function_name:match("^(.-)%(")
end

local function find_first_number_after_known_string(input, knownString)
	-- Find the position of the known string in the input
	local startPos = string.find(input, knownString)

	-- If the known string is found
	if startPos then
		-- Extract the substring that starts right after the known string
		local remainingSubstring = string.sub(input, startPos + #knownString)

		-- Match the first sequence of digits in the remaining substring
		local number = string.match(remainingSubstring, "%d+")

		return tonumber(number) - 1
	end

	-- Return nil if the known string is not found
	return nil
end

--- Convert a JUnit failure report into a Neotest error. It parses the failure
--- message and removes the Exception path from it. Furthermore it tries to parse
--- the stack trace to find a line number within the executed test case.
---
--- @param failure_node table - XML node of failure report in of a test case
--- @return table - see neotest.Error
local function extract_message_and_stack_trace(failure_node)
	local attrs = failure_node._attr or {}
	local stack_trace = failure_node[1] or ""
	local type = attrs.type or ""
	local first_line = stack_trace:match("^([^\n]+)")
	local message = attrs.message or first_line or type

	if type ~= "" and message ~= type then
		message = message:gsub("^" .. vim.pesc(type) .. ":?%s*", "")
	end

	message = message:gsub("^%s+", ""):gsub("%s+$", "")

	if message == "" then
		message = first_line or type
	end

	return message, stack_trace
end

local function parse_error_from_failure_xml(failure_node, test_case_node)
	local short_message, stack_trace = extract_message_and_stack_trace(failure_node)
	local message = stack_trace ~= "" and stack_trace or short_message

	local line_number = find_first_number_after_known_string(stack_trace, test_case_node._attr.name)

	return { message = message, line = line_number }
end

--- @param test_case_node table
--- @return table | nil
local function get_failure_node(test_case_node)
	return test_case_node.failure or test_case_node.error
end

--- @param test_case_node table
--- @param results_directory string
--- @return string
local function write_systemout_to_file(test_case_node, results_directory)
	local filename = test_case_node["_attr"]["classname"] .. "#" .. test_case_node["_attr"]["name"] .. ".txt"
	local reports_dir = results_directory:match("([^:]+)")
	local parent_path = reports_dir:match("(.+)/[^/]+")
	local neotest_output_files = parent_path .. "/neotest-output"

	vim.uv.fs_mkdir(neotest_output_files, tonumber("755", 8))

	local path_to_file = neotest_output_files .. "/" .. filename
	local file = io.open(path_to_file, "w")
	if file then
		file:write(test_case_node["system-out"])
		if test_case_node.failure ~= nil then
			file:write("\n\n")
			file:write(test_case_node.failure[1])
		end
		file:close()
	else
		logger.error("Could not write test output file: " .. path_to_file)
	end

	return path_to_file
end

local function get_parameter_number(test_case_node)
	local function_name = test_case_node._attr.name
	return function_name:match("%[(.+)%]")
end

local function write_output_for_parameterized_tests(test_case_node, results_directory)
	local test_case_node_name = extract_test_case_basename(test_case_node)
	local filename = test_case_node["_attr"]["classname"] .. "#" .. test_case_node_name .. ".txt"
	local reports_dir = results_directory:match("([^:]+)")
	local parent_path = reports_dir:match("(.+)/[^/]+")
	local neotest_output_files = parent_path .. "/neotest-output"

	local test_number = tonumber(get_parameter_number(test_case_node))
	local failure_node = get_failure_node(test_case_node)
	local status = failure_node == nil and STATUS_PASSED or STATUS_FAILED

	vim.uv.fs_mkdir(neotest_output_files, tonumber("755", 8))

	local path_to_file = neotest_output_files .. "/" .. filename

	local file
	if test_number == 1 then
		file = io.open(path_to_file, "w")
	else
		file = io.open(path_to_file, "a")
	end

	if file then
		file:write("Parameter #" .. test_number .. " - Test " .. status .. "\n\n")
		if test_case_node["system-out"] ~= nil then
			file:write(test_case_node["system-out"])
		else
			file:write("Empty output for: " .. test_case_node._attr.name)
		end
		file:write("\n\n")
		file:close()
	else
		logger.error("Could not write parameterized test output file: " .. path_to_file)
	end

	return path_to_file
end

--- Check if the current status of the test is already failed.
--- If it is, it returns failed since the test cannot be passed anymore.
--- Otherwise, return the status of the current test.
---@param test_case_node table
---@param table_tests table
---@return string
local function get_status_for_parameterized(test_case_node, table_tests)
	local test_case_node_name = extract_test_case_basename(test_case_node)
	if table_tests[test_case_node_name].status == STATUS_FAILED then
		return STATUS_FAILED
	else
		local failure_node = get_failure_node(test_case_node)
		return failure_node == nil and STATUS_PASSED or STATUS_FAILED
	end
end

local function get_error_details(failure_node, test_case_node)
	if not failure_node then
		return nil, nil
	end

	local short_message = extract_message_and_stack_trace(failure_node)
	local error = parse_error_from_failure_xml(failure_node, test_case_node)

	return short_message, error
end

--- See Neotest adapter specification.
---
--- This builds a list of test run results. Therefore it parses all JUnit report
--- files and traverses trough the reports inside. The reports are matched back
--- to Neotest positions.
--- It also tries to determine why and where a test possibly failed for
--- additional Neotest features like diagnostics.
---
--- @param build_specfication table - see neotest.RunSpec
--- @param tree table - see neotest.Tree
--- @return table<string, table> - see neotest.Result
return function(build_specfication, _, tree)
	local results = {}
	local parameterized_tests = {}
	local position = tree:data()
	local results_directory = build_specfication.context.test_results_directory
	local report_name_suffix = build_specfication.context.report_name_suffix
	local juris_reports = parse_xml_files_from_directory(results_directory, report_name_suffix)

	for _, juris_report in pairs(juris_reports) do
		for _, test_suite_node in pairs(asList(juris_report.testsuite)) do
			for _, test_case_node in pairs(asList(test_suite_node.testcase)) do
				strip_report_name_suffix(test_case_node, report_name_suffix)
				local is_parameterized = is_parameterized_test(test_case_node)
				local matched_position = find_position_for_test_case(tree, test_case_node)
				local failure_node = get_failure_node(test_case_node)

				if is_parameterized and matched_position ~= nil then
					local test_case_node_name = extract_test_case_basename(test_case_node)
					local number = tonumber(get_parameter_number(test_case_node))
					local short_message, error = get_error_details(failure_node, test_case_node)
					if number == 1 then
						local status = failure_node == nil and STATUS_PASSED or STATUS_FAILED
						parameterized_tests[test_case_node_name] = {
							status = status,
							output = write_output_for_parameterized_tests(test_case_node, results_directory),
							short = short_message,
							errors = error and { error } or {},
						}
					else
						local existing_test = parameterized_tests[test_case_node_name]
						parameterized_tests[test_case_node_name] = {
							status = get_status_for_parameterized(test_case_node, parameterized_tests),
							output = write_output_for_parameterized_tests(test_case_node, results_directory),
							short = existing_test.short or short_message,
							errors = (#existing_test.errors > 0 and existing_test.errors) or (error and { error } or {}),
						}
					end

					results[matched_position.id] = parameterized_tests[test_case_node_name]
				elseif matched_position ~= nil then
					local path_to_file
					if test_case_node["system-out"] ~= nil then -- essa verificação provavelmente deve ficar dentro de write_systemout_to_file
						path_to_file = write_systemout_to_file(test_case_node, results_directory) -- escrever também o failure -> failure_node[1]
					else
						path_to_file = nil
					end

					local status = failure_node == nil and STATUS_PASSED or STATUS_FAILED
					local short_message, error = get_error_details(failure_node, test_case_node)
					local result = {
						status = status,
						output = path_to_file,
						short = short_message,
						errors = error and { error } or {},
					}
					results[matched_position.id] = result
				elseif failure_node ~= nil then
					local classname = (test_case_node._attr or {}).classname or "<unknown class>"
					local name = (test_case_node._attr or {}).name or "<unknown test>"
					logger.debug(function()
						return "Could not match failed test case to neotest position: " .. classname .. "#" .. name
					end)
				end
			end
		end
	end

	logger.debug(function()
		return "Collected " .. vim.tbl_count(results) .. " test result(s)"
	end)

	return results
end
