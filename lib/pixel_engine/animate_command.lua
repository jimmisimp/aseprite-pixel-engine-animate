return function(config, support, sprite_ops)
  local command = {}

  local function is_valid_palette_size(value)
    local string_value = tostring(value)
    for _, option in ipairs(config.PALETTE_SIZE_OPTIONS) do
      if option == string_value then
        return true
      end
    end

    return false
  end

  local function validate_inputs(sprite, prompt, api_key, output_frames, use_index_colors, palette_size)
    if not sprite then
      support.fail("There is no active sprite.")
    end

    if not app.frame then
      support.fail("There is no active frame.")
    end

    if not api_key or api_key == "" then
      support.fail("Enter a Pixel Engine API key.")
    end

    if not prompt or prompt == "" then
      support.fail("Enter a prompt.")
    end

    if sprite.width > 256 or sprite.height > 256 then
      support.fail("Pixel Engine only accepts images up to 256x256.")
    end

    local aspect = sprite.width / sprite.height
    if aspect > 2 or aspect < 0.5 then
      support.fail("Pixel Engine only accepts images up to a 2:1 aspect ratio.")
    end

    if output_frames < 2 or output_frames > 16 or output_frames % 2 ~= 0 then
      support.fail("Frames must be an even number from 2 to 16.")
    end

    if not use_index_colors and not is_valid_palette_size(palette_size) then
      support.fail("Palette size must be one of 8, 12, 16, 20, 24, 32, 48, or 60.")
    end
  end

  local function build_request_json(api_key, prompt, negative_prompt, output_frames, matte_color, use_index_colors, palette_value)
    local payload = {
      api_key = api_key,
      prompt = prompt,
      negative_prompt = negative_prompt,
      output_frames = output_frames,
      matte_color = matte_color
    }

    if use_index_colors then
      payload.palette = palette_value
    else
      payload.colors = tonumber(palette_value)
    end

    return json.encode(payload)
  end

  local function run_helper(helper_path, request_path, image_path, result_path, output_path)
    local command_line = table.concat({
      "powershell.exe",
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", support.quote_arg(helper_path),
      "-RequestPath", support.quote_arg(request_path),
      "-ImagePath", support.quote_arg(image_path),
      "-ResultPath", support.quote_arg(result_path),
      "-OutputImagePath", support.quote_arg(output_path)
    }, " ")

    os.execute(command_line)

    if not app.fs.isFile(result_path) then
      support.fail("The Pixel Engine helper did not return a result.")
    end

    local result = json.decode(support.read_text_file(result_path))
    if not result then
      support.fail("The Pixel Engine helper returned invalid JSON.")
    end

    if not result.ok then
      support.fail(result.error or "Pixel Engine request failed.")
    end

    if result.content_type ~= "image/png" then
      support.fail("Expected a spritesheet PNG from Pixel Engine.")
    end

    if not app.fs.isFile(output_path) then
      support.fail("Pixel Engine did not download the spritesheet.")
    end

    return result
  end

  local function build_temp_paths(temp_dir, plugin_path)
    return {
      helper = app.fs.joinPath(plugin_path, config.HELPER_SCRIPT_NAME),
      request = app.fs.joinPath(temp_dir, config.TEMP_FILES.request),
      input = app.fs.joinPath(temp_dir, config.TEMP_FILES.input),
      result = app.fs.joinPath(temp_dir, config.TEMP_FILES.result),
      output = app.fs.joinPath(temp_dir, config.TEMP_FILES.output)
    }
  end

  local function normalize_preferences(preferences, env_api_key)
    local use_index_colors = preferences.use_index_colors
    if use_index_colors == nil then
      use_index_colors = true
    end

    local palette_size = tostring(preferences.palette_size or config.DEFAULT_PALETTE_SIZE)
    if not is_valid_palette_size(palette_size) then
      palette_size = config.DEFAULT_PALETTE_SIZE
    end

    return {
      api_key = env_api_key or preferences.api_key or "",
      prompt = preferences.prompt or "",
      negative_prompt = preferences.negative_prompt or "",
      output_frames = tonumber(preferences.output_frames) or config.DEFAULT_FRAMES,
      matte_color = preferences.matte_color or config.DEFAULT_MATTE_COLOR,
      use_index_colors = use_index_colors,
      palette_size = palette_size
    }
  end

  local function mask_api_key(api_key)
    local trimmed = support.trim(api_key)
    if trimmed == "" then
      return ""
    end

    local visible_suffix_length = math.min(4, #trimmed)
    local visible_suffix = trimmed:sub(-visible_suffix_length)
    local masked_prefix_length = math.max(4, #trimmed - visible_suffix_length)

    return string.rep("*", masked_prefix_length) .. visible_suffix
  end

  local function persist_preferences(preferences, values)
    preferences.api_key = values.api_key
    preferences.prompt = values.prompt
    preferences.negative_prompt = values.negative_prompt
    preferences.output_frames = values.output_frames
    preferences.matte_color = values.matte_color
    preferences.use_index_colors = values.use_index_colors
    preferences.palette_size = values.palette_size
  end

  local function build_dialog(initial_values)
    local dialog = Dialog(config.COMMAND_TITLE)
    local masked_api_key = mask_api_key(initial_values.api_key)

    dialog:entry{
      id = "api_key",
      label = "API Key",
      text = masked_api_key,
      focus = (initial_values.api_key == "")
    }
    dialog:newrow()
    dialog:entry{
      id = "prompt",
      label = "Prompt",
      text = initial_values.prompt,
      focus = (initial_values.api_key ~= "")
    }
    dialog:newrow()
    dialog:entry{
      id = "negative_prompt",
      label = "Negative",
      text = initial_values.negative_prompt
    }
    dialog:newrow()
    dialog:color{
      id = "matte_color",
      label = "Matte",
      color = support.hex_to_color(initial_values.matte_color, config.DEFAULT_MATTE_COLOR)
    }
    dialog:newrow()
    dialog:number{
      id = "output_frames",
      label = "Frames",
      text = tostring(initial_values.output_frames),
      decimals = 0
    }
    dialog:newrow()
    dialog:check{
      id = "use_index_colors",
      label = "Colors",
      text = "Use index colors",
      selected = initial_values.use_index_colors,
      onclick = function()
        dialog:modify{
          id = "palette_size",
          enabled = not dialog.data.use_index_colors
        }
      end
    }
    dialog:newrow()
    dialog:combobox{
      id = "palette_size",
      label = "Palette Size",
      option = initial_values.palette_size,
      options = config.PALETTE_SIZE_OPTIONS,
      enabled = not initial_values.use_index_colors
    }
    dialog:newrow()
    dialog:button{ id = "ok", text = "Generate", focus = true }
    dialog:button{ id = "cancel", text = "Cancel" }

    return dialog
  end

  local function parse_dialog_values(data, initial_values, env_api_key)
    local masked_api_key = mask_api_key(initial_values.api_key)
    local values = {
      api_key = support.trim(data.api_key),
      prompt = support.trim(data.prompt),
      negative_prompt = support.trim(data.negative_prompt),
      output_frames = math.floor(tonumber(data.output_frames) or 0),
      matte_color = support.color_to_hex(
        data.matte_color or support.hex_to_color(initial_values.matte_color, config.DEFAULT_MATTE_COLOR)
      ),
      use_index_colors = data.use_index_colors and true or false,
      palette_size = tostring(data.palette_size or initial_values.palette_size)
    }

    if initial_values.api_key ~= "" and values.api_key == masked_api_key then
      values.api_key = initial_values.api_key
    end

    if values.api_key == "" and env_api_key then
      values.api_key = env_api_key
    end

    return values
  end

  local function run_generation(plugin)
    local sprite = app.sprite
    local current_frame = app.frame
    local preferences = plugin.preferences
    local env_api_key = support.read_env_key(plugin.path)
    local initial_values = normalize_preferences(preferences, env_api_key)
    local dialog = build_dialog(initial_values)
    local data = dialog:show().data

    if not data.ok then
      return
    end

    local values = parse_dialog_values(data, initial_values, env_api_key)
    validate_inputs(
      sprite,
      values.prompt,
      values.api_key,
      values.output_frames,
      values.use_index_colors,
      values.palette_size
    )
    persist_preferences(preferences, values)

    local temp_dir = support.make_temp_dir()
    local paths = build_temp_paths(temp_dir, plugin.path)
    local ok, result_or_error = pcall(function()
      if not app.fs.isFile(paths.helper) then
        support.fail("The bundled PowerShell helper is missing.")
      end

      app.tip("Rendering current frame...", 2)
      sprite_ops.render_active_frame(sprite, current_frame.frameNumber, paths.input)

      local palette_value = values.palette_size
      if values.use_index_colors then
        palette_value = sprite_ops.collect_palette_colors(sprite)
      end

      support.write_text_file(
        paths.request,
        build_request_json(
          values.api_key,
          values.prompt,
          values.negative_prompt,
          values.output_frames,
          values.matte_color,
          values.use_index_colors,
          palette_value
        )
      )

      app.tip("Waiting for Pixel Engine...", 3)
      local result = run_helper(paths.helper, paths.request, paths.input, paths.result, paths.output)
      local layer_name, imported_frames = sprite_ops.import_spritesheet(
        sprite,
        current_frame.frameNumber,
        paths.output,
        result.metadata
      )

      return {
        layer_name = layer_name,
        imported_frames = imported_frames,
        api_job_id = result.api_job_id
      }
    end)

    support.cleanup_temp_dir(temp_dir, { paths.request, paths.input, paths.result, paths.output })

    if not ok then
      support.log("Generation failed: " .. tostring(result_or_error))
      app.alert{
        title = config.COMMAND_TITLE,
        text = result_or_error
      }
      return
    end

    app.alert{
      title = config.COMMAND_TITLE,
      text = {
        "Imported " .. result_or_error.imported_frames .. " frames into layer '" .. result_or_error.layer_name .. "'.",
        "Job ID: " .. tostring(result_or_error.api_job_id)
      }
    }
  end

  function command.init(plugin)
    if plugin.preferences.output_frames == nil then
      plugin.preferences.output_frames = config.DEFAULT_FRAMES
    end

    if plugin.preferences.matte_color == nil then
      plugin.preferences.matte_color = config.DEFAULT_MATTE_COLOR
    end

    plugin:newCommand{
      id = config.COMMAND_ID,
      title = config.COMMAND_TITLE,
      group = "file_scripts",
      onclick = function()
        run_generation(plugin)
      end,
      onenabled = function()
        return app.sprite ~= nil and app.frame ~= nil
      end
    }
  end

  function command.exit(plugin)
  end

  return command
end
