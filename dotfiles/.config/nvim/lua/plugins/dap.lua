local status_ok_dap, dap = pcall(require, "dap")
if not status_ok_dap then
	return
end

dap.adapters["pwa-node"] = {
	type = "server",
	host = "localhost",
	port = "${port}",
	executable = {
		command = "node",
		args = { os.getenv("HOME") .. "/.local/share/nvim/js-debug/src/dapDebugServer.js", "${port}" },
	},
}

dap.adapters.python = function(cb, config)
	if config.request == "attach" then
		---@diagnostic disable-next-line: undefined-field
		local port = (config.connect or config).port
		---@diagnostic disable-next-line: undefined-field
		local host = (config.connect or config).host or "127.0.0.1"
		cb({
			type = "server",
			port = assert(port, "`connect.port` is required for a python `attach` configuration"),
			host = host,
			options = {
				source_filetype = "python",
			},
		})
	else
		cb({
			type = "executable",
			command = "/home/guidiamond/.pyenv/shims/python",
			args = { "-m", "debugpy.adapter" },
			options = {
				source_filetype = "python",
			},
		})
	end
end

dap.configurations.python = {
	{
		-- The first three options are required by nvim-dap
		type = "python", -- the type here established the link to the adapter definition: `dap.adapters.python`
		request = "launch",
		name = "Launch file",
		justMyCode = false,

		-- Options below are for debugpy, see https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings for supported options

		program = "${file}", -- This configuration will launch the current file if used.
		pythonPath = function()
			-- debugpy supports launching an application with a different interpreter then the one used to launch debugpy itself.
			-- The code below looks for a `venv` or `.venv` folder in the current directly and uses the python within.
			-- You could adapt this - to for example use the `VIRTUAL_ENV` environment variable.
			local cwd = vim.fn.getcwd()
			if vim.fn.executable(cwd .. "/venv/bin/python") == 1 then
				return cwd .. "/venv/bin/python"
			elseif vim.fn.executable(cwd .. "/.venv/bin/python") == 1 then
				return cwd .. "/.venv/bin/python"
			else
				return "/home/guidiamond/.pyenv/shims/python"
			end
		end,
	},
}

-- dap.configurations.javascript = {
-- 	{
-- 		type = "pwa-node",
-- 		request = "launch",
-- 		name = "Launch file",
-- 		program = "${file}",
-- 		cwd = "${workspaceFolder}",
-- 	},
-- }
--
dap.configurations.javascript = {
	{
		type = "pwa-node",
		request = "launch",
		name = "Launch file (js)",
		program = "${file}",
		cwd = "${workspaceFolder}",
		runtimeExecutable = "node",
		console = "integratedTerminal",
		internalConsoleOptions = "neverOpen",
	},
}

-- DEPRECATED, but we didn't replace it with anything else
-- Keep it here for reference, in case we want to use it again in the future
-- require("dap.ext.vscode").load_launchjs(nil, {
-- 	["pwa-node"] = { "javascript", "typescript" },
-- 	["node"] = { "javascript", "typescript" },
-- })

dap.configurations.typescript = dap.configurations.javascript
dap.configurations.javascriptreact = dap.configurations.javascript
dap.configurations.typescriptreact = dap.configurations.javascript

local status_ok_dap_ui, dapui = pcall(require, "dapui")
if not status_ok_dap_ui then
	return
end

dap.listeners.before.attach.dapui_config = function()
	dapui.open()
end
dap.listeners.before.launch.dapui_config = function()
	dapui.open()
end
dap.listeners.before.event_terminated.dapui_config = function()
	dapui.close()
end
dap.listeners.before.event_exited.dapui_config = function()
	dapui.close()
end

vim.fn.sign_define("DapBreakpoint", {
	text = "󰯯", -- icon in the gutter
	texthl = "DiagnosticError", -- highlight group
	linehl = "", -- line highlight
	numhl = "", -- number column highlight
})

vim.fn.sign_define("DapBreakpointCondition", {
	text = "✖",
	texthl = "DiagnosticWarn",
})

vim.fn.sign_define("DapLogPoint", {
	text = "🔵",
	texthl = "DiagnosticInfo",
})

vim.fn.sign_define("DapStopped", {
	text = "", -- or '👉', '▶️'
	texthl = "DiagnosticOk", -- or create your own
	linehl = "CursorLine", -- highlight entire line
	numhl = "DiagnosticOk",
})

dapui.setup()
