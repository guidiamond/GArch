local status_ok, typescript_tools = pcall(require, "typescript-tools")

if not status_ok then
	return
end

typescript_tools.setup({})
