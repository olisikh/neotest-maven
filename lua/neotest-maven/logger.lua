local M = {}

local DEFAULT_LEVEL = vim.log.levels.WARN

local function normalize_level(level)
	if type(level) == "number" then
		return level
	end

	if type(level) == "string" then
		local normalized = level:upper()
		return vim.log.levels[normalized]
	end
end

local function get_level()
	return normalize_level(vim.g.neotest_maven_log_level) or DEFAULT_LEVEL
end

local function should_log(level)
	return level >= get_level()
end

local function resolve_message(message)
	if type(message) == "function" then
		return message()
	end

	return message
end

local function notify(level, message)
	if not should_log(level) then
		return
	end

	vim.notify(resolve_message(message), level, { title = "neotest-maven" })
end

function M.debug(message)
	notify(vim.log.levels.DEBUG, message)
end

function M.info(message)
	notify(vim.log.levels.INFO, message)
end

function M.warn(message)
	notify(vim.log.levels.WARN, message)
end

function M.error(message)
	notify(vim.log.levels.ERROR, message)
end

function M.enabled(level)
	local normalized = normalize_level(level)
	return normalized ~= nil and should_log(normalized)
end

return M
