local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local make_entry = require("telescope.make_entry")
local entry_display = require("telescope.pickers.entry_display")
local devicons = require("nvim-web-devicons")

local M = {}

local state = {
	regex_enabled = false,
	filetype_filter = nil,
	test_filter = nil,
}

-- rg type aliases that map extensions to rg --type values
local EXT_TO_RG_TYPE = {
	lua = "lua", py = "py", js = "js", ts = "ts", tsx = "ts", jsx = "js",
	go = "go", rs = "rust", c = "c", cpp = "cpp", java = "java", rb = "ruby",
	sh = "sh", json = "json", yaml = "yaml", yml = "yaml", toml = "toml",
	html = "html", css = "css", scss = "css", md = "markdown", vim = "vim",
}

-- Reverse map: rg type → the extensions it covers, for glob-based filters.
-- Kept in sync with `rg --type-list` so glob filters match --type exactly.
local RG_TYPE_EXTS = {
	lua = "lua", py = "py,pyi", js = "js,jsx,cjs,mjs,vue", ts = "ts,tsx,cts,mts",
	go = "go", rust = "rs", c = "c,h", cpp = "cpp,cc,cxx,hpp,hh,hxx",
	java = "java,jsp", ruby = "rb,rbw,rake", sh = "sh,bash,zsh,ksh,csh",
	json = "json", yaml = "yaml,yml", toml = "toml", html = "html,htm,ejs",
	css = "css,scss", markdown = "md,markdown,mdx", vim = "vim",
}

--- Glob matching every file of an rg type, e.g. "ts" → "*.{ts,tsx}"
local function type_glob(rg_type)
	local exts = RG_TYPE_EXTS[rg_type]
	return exts and ("*.{" .. exts .. "}") or ("*." .. rg_type)
end

local PRIORITY_TYPES = { "ts" }

-- Test-file naming conventions, minus the extension (see test_globs)
local TEST_FILE_PATTERNS = { "*.test", "*.spec", "*_test", "*_spec", "**/test_*" }
local TEST_DIRS = { "__tests__", "__mocks__", "tests", "test" }

--- Globs matching test files, restricted to `exts` ("ts,tsx") when given.
--- The extension has to be baked in for the *positive* ("only tests") case:
--- a positive --glob whitelists a file outright rather than intersecting with
--- --type, so `--type ts --glob '*.test.*'` would drag in .md, .xlsx, etc.
--- Negative globs do intersect, so the exclude case can leave `exts` nil.
local function test_globs(exts)
	local suffix = exts and ("{" .. exts .. "}") or "*"
	local globs = {}
	for _, pattern in ipairs(TEST_FILE_PATTERNS) do
		table.insert(globs, pattern .. "." .. suffix)
	end
	for _, dir in ipairs(TEST_DIRS) do
		-- unrestricted: prune the whole dir; restricted: only matching files in it
		table.insert(globs, exts and ("**/" .. dir .. "/**/*." .. suffix) or ("**/" .. dir .. "/**"))
	end
	return globs
end

-- Cycle order for the test-file axis, independent of the filetype axis
local TEST_FILTERS = { "all", "exclude", "only" }

local TEST_FILTER_LABEL = { exclude = "NoTests", only = "OnlyTests" }

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
	local ft_filter = state.filetype_filter
	local parts = {
		state.regex_enabled and "[Regex]" or "[Fuzzy]",
		(ft_filter and ft_filter ~= "all") and ft_filter or "All",
	}
	local test_label = TEST_FILTER_LABEL[state.test_filter]
	if test_label then
		table.insert(parts, test_label)
	end
	return " " .. table.concat(parts, "  ") .. "  "
end

local function build_args()
	local args = { "rg", "--color=never", "--no-heading", "--with-filename", "--line-number", "--column" }
	if not state.regex_enabled then
		table.insert(args, "--fixed-strings")
	end
	local ft = state.filetype_filter
	if ft == "all" then
		ft = nil
	end

	if state.test_filter == "only" then
		-- Positive globs bypass --type, so they carry the filetype axis themselves
		for _, glob in ipairs(test_globs(ft and RG_TYPE_EXTS[ft])) do
			table.insert(args, "--glob=" .. glob)
		end
	else
		if ft then
			table.insert(args, "--type")
			table.insert(args, ft)
		end
		if state.test_filter == "exclude" then
			for _, glob in ipairs(test_globs(nil)) do
				table.insert(args, "--glob=!" .. glob)
			end
		end
	end
	return args
end

local function cycle_value(list, current, direction)
	local idx = 1
	for i, value in ipairs(list) do
		if value == current then
			idx = i
			break
		end
	end
	if direction > 0 then
		return list[idx % #list + 1]
	end
	return list[(idx - 2) % #list + 1]
end

local function cycle_filetype(direction)
	state.filetype_filter = cycle_value(get_project_filetypes(), state.filetype_filter or "all", direction)
end

local function cycle_test_filter(direction)
	state.test_filter = cycle_value(TEST_FILTERS, state.test_filter or "all", direction)
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

			map("i", "<C-e>", relaunch_with(function()
				cycle_test_filter(1)
			end))

			map("i", "<C-S-e>", relaunch_with(function()
				cycle_test_filter(-1)
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
					-- Spectre turns each whitespace-separated token into `rg -g <token>`
					local ft = state.filetype_filter
					if ft == "all" then
						ft = nil
					end
					local globs = {}
					if state.test_filter == "only" then
						globs = test_globs(ft and RG_TYPE_EXTS[ft])
					else
						if ft then
							table.insert(globs, type_glob(ft))
						end
						if state.test_filter == "exclude" then
							for _, glob in ipairs(test_globs(nil)) do
								table.insert(globs, "!" .. glob)
							end
						end
					end
					if #globs > 0 then
						spectre_opts.path = table.concat(globs, " ")
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
	state.test_filter = "all"
	cached_filetypes = nil -- re-scan project filetypes
	launch()
end

return M
