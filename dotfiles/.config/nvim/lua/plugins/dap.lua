local status_ok_dap, dap = pcall(require, "dap")
if not status_ok_dap then
	return
end

local status_ok_dap_ui, dapui = pcall(require, "dapui")
if not status_ok_dap_ui then
	return
end
dapui.setup()
