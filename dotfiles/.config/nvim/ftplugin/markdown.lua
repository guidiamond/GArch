--- Smart "gd" for markdown files:
---   URL          → open in browser
---   file path    → open in nvim
---   #section ref → jump to heading
local function markdown_gd()
	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-indexed byte column

	-- Find the markdown link under cursor: [text](target) or <url>
	local target = nil

	-- Check for [text](target) style links
	for start_byte, link_target, end_byte in line:gmatch("()%[.-%]%((.-)%)()") do
		-- start_byte..end_byte covers the entire [text](target)
		if col >= start_byte - 1 and col < end_byte - 1 then
			target = link_target
			break
		end
	end

	-- Check for <url> style links
	if not target then
		for start_byte, link_target, end_byte in line:gmatch("()<(.-)>()") do
			if col >= start_byte - 1 and col < end_byte - 1 then
				target = link_target
				break
			end
		end
	end

	-- Check for bare URLs (http/https)
	if not target then
		for start_byte, link_target, end_byte in line:gmatch("()(https?://[%w%-%._~:/?#%[%]@!$&'*+,;=%%]+)()") do
			if col >= start_byte - 1 and col < end_byte - 1 then
				target = link_target
				break
			end
		end
	end

	-- Check for [[wiki-style]] links
	if not target then
		for start_byte, link_target, end_byte in line:gmatch("()%[%[(.-)%]%]()") do
			if col >= start_byte - 1 and col < end_byte - 1 then
				target = link_target
				break
			end
		end
	end

	if not target or target == "" then
		vim.notify("No link under cursor", vim.log.levels.WARN)
		return
	end

	-- URL → open in browser
	if target:match("^https?://") or target:match("^www%.") then
		vim.ui.open(target)
		return
	end

	-- Split target into file and anchor parts: "file.md#section" or "#section"
	local file_part, anchor = target:match("^(.-)#(.+)$")
	if not file_part then
		file_part = target
		anchor = nil
	end

	-- Pure anchor (#section) → jump to heading in current buffer
	if file_part == "" and anchor then
		local heading_pattern = anchor:gsub("-", "[- ]"):gsub("%%", "%%%%")
		local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
		for i, l in ipairs(lines) do
			-- Match any heading level: # Heading, ## Heading, etc.
			local heading_text = l:match("^#+%s+(.*)")
			if heading_text then
				-- Normalize heading: lowercase, spaces/special chars become dashes
				local slug = heading_text:lower():gsub("[^%w%s-]", ""):gsub("%s+", "-"):gsub("%-+$", "")
				if slug == anchor:lower() then
					vim.api.nvim_win_set_cursor(0, { i, 0 })
					vim.cmd("normal! zz")
					return
				end
			end
		end
		-- Fallback: search for the heading text directly
		local search_ok = pcall(vim.cmd, "/" .. heading_pattern .. "\\c")
		if search_ok then
			vim.cmd("nohlsearch")
			vim.cmd("normal! zz")
		else
			vim.notify("Section not found: #" .. anchor, vim.log.levels.WARN)
		end
		return
	end

	-- File reference → resolve relative to current file's directory
	if file_part ~= "" then
		local current_dir = vim.fn.expand("%:p:h")
		local resolved = vim.fn.resolve(current_dir .. "/" .. file_part)

		if vim.fn.filereadable(resolved) == 1 then
			vim.cmd("edit " .. vim.fn.fnameescape(resolved))
			-- If there's also an anchor, jump to it in the opened file
			if anchor then
				vim.schedule(function()
					local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
					for i, l in ipairs(lines) do
						local heading_text = l:match("^#+%s+(.*)")
						if heading_text then
							local slug = heading_text:lower():gsub("[^%w%s-]", ""):gsub("%s+", "-"):gsub("%-+$", "")
							if slug == anchor:lower() then
								vim.api.nvim_win_set_cursor(0, { i, 0 })
								vim.cmd("normal! zz")
								return
							end
						end
					end
				end)
			end
		elseif vim.fn.isdirectory(resolved) == 1 then
			vim.cmd("edit " .. vim.fn.fnameescape(resolved))
		else
			vim.notify("File not found: " .. resolved, vim.log.levels.WARN)
		end
		return
	end
end

local function set_gd()
	vim.keymap.set("n", "gd", markdown_gd, { buffer = true, desc = "Smart markdown go-to-definition" })
end

-- Set now, and re-set after any LSP attaches (so it overrides Lspsaga's gd)
set_gd()
vim.api.nvim_create_autocmd("LspAttach", {
	buffer = 0,
	callback = function()
		vim.schedule(set_gd)
	end,
})
