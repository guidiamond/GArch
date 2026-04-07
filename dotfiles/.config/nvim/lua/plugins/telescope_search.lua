local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local make_entry = require("telescope.make_entry")
local entry_display = require("telescope.pickers.entry_display")
local devicons = require("nvim-web-devicons")

local M = {}

local state = {
	regex_enabled = false,
	filetype_filter = nil,
}

-- rg type aliases that map extensions to rg --type values
local EXT_TO_RG_TYPE = {
	lua = "lua", py = "py", js = "js", ts = "ts", tsx = "ts", jsx = "js",
	go = "go", rs = "rust", c = "c", cpp = "cpp", java = "java", rb = "ruby",
	sh = "sh", json = "json", yaml = "yaml", yml = "yaml", toml = "toml",
	html = "html", css = "css", scss = "css", md = "markdown", vim = "vim",
}

-- Reverse map: rg type → glob pattern for spectre
local RG_TYPE_TO_GLOB = {
	lua = "*.lua", py = "*.py", js = "*.{js,jsx}", ts = "*.{ts,tsx}",
	go = "*.go", rust = "*.rs", c = "*.c", cpp = "*.{cpp,cc,cxx,hpp}",
	java = "*.java", ruby = "*.rb", sh = "*.sh", json = "*.json",
	yaml = "*.{yaml,yml}", toml = "*.toml", html = "*.html",
	css = "*.{css,scss}", markdown = "*.md", vim = "*.vim",
}

local PRIORITY_TYPES = { "ts" }

local cached_filetypes = nil

--- Scan the project for file extensions and build the filetype list
local function get_project_filetypes()
	if cached_filetypes then
		return cached_filetypes
	end

	local output = vim.fn.systemlist("fd --type f --hidden --exclude .git --exclude node_modules . 2>/dev/null")
	local ext_set = {}
	for _, file in ipairs(output) do
		local ext = file:match("%.([^%./ ]+)$")
		if ext and EXT_TO_RG_TYPE[ext] then
			ext_set[EXT_TO_RG_TYPE[ext]] = true
		end
	end

	-- Build ordered list: priority types first, then alphabetical
	local priority = {}
	local rest = {}
	local priority_set = {}
	for _, t in ipairs(PRIORITY_TYPES) do
		if ext_set[t] then
			table.insert(priority, t)
			priority_set[t] = true
		end
	end

	for rg_type in pairs(ext_set) do
		if not priority_set[rg_type] then
			table.insert(rest, rg_type)
		end
	end
	table.sort(rest)

	-- "all" sentinel first, then priority, then rest
	cached_filetypes = { "all" }
	for _, t in ipairs(priority) do
		table.insert(cached_filetypes, t)
	end
	for _, t in ipairs(rest) do
		table.insert(cached_filetypes, t)
	end

	return cached_filetypes
end

local PATH_ABBREV_THRESHOLD = 60

local function abbreviate_path(filepath)
	if #filepath <= PATH_ABBREV_THRESHOLD then
		return filepath
	end

	local parts = {}
	for part in filepath:gmatch("[^/]+") do
		table.insert(parts, part)
	end

	if #parts <= 1 then
		return filepath
	end

	local filename = parts[#parts]
	local abbreviated = {}
	for i = 1, #parts - 1 do
		table.insert(abbreviated, parts[i]:sub(1, 1))
	end
	local short = table.concat(abbreviated, "/") .. "/" .. filename

	if #short <= PATH_ABBREV_THRESHOLD then
		for expand = #parts - 1, 1, -1 do
			abbreviated[expand] = parts[expand]
			local candidate = table.concat(abbreviated, "/") .. "/" .. filename
			if #candidate > PATH_ABBREV_THRESHOLD then
				abbreviated[expand] = parts[expand]:sub(1, 1)
				break
			end
			short = candidate
		end
	end

	return short
end

local function make_search_entry(opts)
	local base_maker = make_entry.gen_from_vimgrep(opts)

	local displayer = entry_display.create({
		separator = " ",
		items = {
			{ width = 2 },
			{ remaining = true },
			{ remaining = true },
		},
	})

	return function(line)
		local entry = base_maker(line)
		if not entry then
			return nil
		end

		entry.display = function(e)
			local path = e.filename or ""
			local lnum = e.lnum or 0
			local text = e.text or ""

			local ext = vim.fn.fnamemodify(path, ":e")
			local icon, icon_hl = devicons.get_icon(path, ext, { default = true })

			local short_path = abbreviate_path(path)
			local location = short_path .. ":" .. lnum

			return displayer({
				{ icon,     icon_hl },
				{ location, "TelescopeResultsComment" },
				{ text,     "TelescopeResultsNormal" },
			})
		end

		return entry
	end
end

local function get_prompt_prefix()
	local mode = state.regex_enabled and " [Regex]" or " [Fuzzy]"
	local ft_filter = state.filetype_filter
	local ft = (ft_filter and ft_filter ~= "all") and (" " .. ft_filter) or " All"
	return mode .. " " .. ft .. "  "
end

local function build_args()
	local args = { "rg", "--color=never", "--no-heading", "--with-filename", "--line-number", "--column" }
	if not state.regex_enabled then
		table.insert(args, "--fixed-strings")
	end
	if state.filetype_filter and state.filetype_filter ~= "all" then
		table.insert(args, "--type")
		table.insert(args, state.filetype_filter)
	end
	return args
end

local function cycle_filetype(direction)
	local ft_list = get_project_filetypes()
	local current_idx = 1
	for i, ft in ipairs(ft_list) do
		if ft == (state.filetype_filter or "all") then
			current_idx = i
			break
		end
	end
	if direction > 0 then
		current_idx = current_idx % #ft_list + 1
	else
		current_idx = (current_idx - 2) % #ft_list + 1
	end
	state.filetype_filter = ft_list[current_idx]
end

local function launch(initial_query)
	require("telescope.builtin").live_grep({
		prompt_title = "Advanced Search",
		layout_strategy = "horizontal",
		layout_config = {
			width = 0.95,
			height = 0.95,
			preview_width = 0.55,
			prompt_position = "bottom",
		},
		prompt_prefix = get_prompt_prefix(),
		default_text = initial_query or "",
		vimgrep_arguments = build_args(),
		entry_maker = make_search_entry({}),
		attach_mappings = function(prompt_bufnr, map)
			local function relaunch_with(fn)
				return function()
					local query = action_state.get_current_line()
					fn()
					actions.close(prompt_bufnr)
					vim.schedule(function()
						launch(query)
					end)
				end
			end

			map("i", "<C-r>", relaunch_with(function()
				state.regex_enabled = not state.regex_enabled
			end))

			map("i", "<C-t>", relaunch_with(function()
				cycle_filetype(1)
			end))

			map("i", "<C-S-t>", relaunch_with(function()
				cycle_filetype(-1)
			end))

			-- Copy relative path of selected entry
			map("i", "<C-y>", function()
				local entry = action_state.get_selected_entry()
				if entry and entry.filename then
					vim.fn.setreg("+", entry.filename)
					vim.notify("Copied: " .. entry.filename, vim.log.levels.INFO)
				end
			end)

			-- Copy absolute path of selected entry
			map("i", "<C-S-y>", function()
				local entry = action_state.get_selected_entry()
				if entry and entry.filename then
					local abs = vim.fn.fnamemodify(entry.filename, ":p")
					vim.fn.setreg("+", abs)
					vim.notify("Copied: " .. abs, vim.log.levels.INFO)
				end
			end)

			-- Copy path:line of selected entry
			map("i", "<C-l>", function()
				local entry = action_state.get_selected_entry()
				if entry and entry.filename then
					local loc = entry.filename .. ":" .. (entry.lnum or 0)
					vim.fn.setreg("+", loc)
					vim.notify("Copied: " .. loc, vim.log.levels.INFO)
				end
			end)

			-- Open Spectre with current search query for search & replace
			map("i", "<C-s>", function()
				local query = action_state.get_current_line()
				actions.close(prompt_bufnr)
				vim.schedule(function()
					local spectre_opts = { search_text = query, is_insert_mode = true }
					if state.filetype_filter and state.filetype_filter ~= "all" then
						spectre_opts.path = RG_TYPE_TO_GLOB[state.filetype_filter] or ("*." .. state.filetype_filter)
					end
					require("spectre").open(spectre_opts)
				end)
			end)

			return true
		end,
	})
end

function M.advanced_search()
	state.regex_enabled = false
	state.filetype_filter = "all"
	cached_filetypes = nil -- re-scan project filetypes
	launch()
end

return M
