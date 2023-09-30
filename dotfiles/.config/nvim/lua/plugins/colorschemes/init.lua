local colorscheme = 'onedark'

local function set_colorscheme(colorscheme_name)
  if colorscheme == colorscheme_name then
    return
  end

  local status_ok, color = pcall(require, "plugins.colorschemes." .. colorscheme_name)
  if not status_ok then
    return
  end
end


return {
  set_colorscheme = set_colorscheme
}
