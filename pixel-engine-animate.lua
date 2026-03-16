local function load_module(plugin, relative_path)
  return dofile(app.fs.joinPath(plugin.path, relative_path))
end

local command_module = nil

function init(plugin)
  math.randomseed(os.time())

  local config = load_module(plugin, "lib/pixel_engine/config.lua")
  local support = load_module(plugin, "lib/utils/support.lua")(config)
  local sprite_ops = load_module(plugin, "lib/pixel_engine/sprite_ops.lua")(config, support)
  local prompt_enhance = load_module(plugin, "lib/openai/prompt_enhance.lua")(config, support)

  command_module = load_module(plugin, "lib/pixel_engine/animate_command.lua")(config, support, sprite_ops, prompt_enhance)
  command_module.init(plugin)
end

function exit(plugin)
  if command_module and command_module.exit then
    command_module.exit(plugin)
  end
end
