return function(config, support, sprite_ops, prompt_enhance)
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

  local function validate_common(sprite, prompt, api_key)
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

    local aspect = sprite.width / sprite.height
    if aspect > 2 or aspect < 0.5 then
      support.fail("Pixel Engine only accepts images up to a 2:1 aspect ratio.")
    end
  end

  local function validate_animate_inputs(sprite, output_frames, use_index_colors, palette_size)
    if sprite.width > 256 or sprite.height > 256 then
      support.fail("Pixel Engine only accepts images up to 256x256.")
    end

    if output_frames < 2 or output_frames > 16 or output_frames % 2 ~= 0 then
      support.fail("Frames must be an even number from 2 to 16.")
    end

    if not use_index_colors and not is_valid_palette_size(palette_size) then
      support.fail("Palette size must be one of 8, 12, 16, 20, 24, 32, 48, or 60.")
    end
  end

  local function validate_keyframe_inputs(sprite, total_frames, use_index_colors, palette_size)
    if total_frames < config.KEYFRAME_TOTAL_MIN or total_frames > config.KEYFRAME_TOTAL_MAX then
      support.fail(
        "Output frames must be from "
          .. config.KEYFRAME_TOTAL_MIN
          .. " to "
          .. config.KEYFRAME_TOTAL_MAX
          .. "."
      )
    end

    if sprite.width > 256 or sprite.height > 256 then
      support.fail("Keyframe mode requires images up to 256x256.")
    end

    if not use_index_colors and not is_valid_palette_size(palette_size) then
      support.fail("Palette size must be one of 8, 12, 16, 20, 24, 32, 48, or 60.")
    end
  end

  local function keyframe_output_indices(total_frames, keyframe_count)
    local indices = {}
    if keyframe_count == 1 then
      indices[1] = 0
      return indices
    end

    for j = 0, keyframe_count - 1 do
      indices[j + 1] = math.floor(j * (total_frames - 1) / (keyframe_count - 1) + 0.5)
    end

    return indices
  end

  local function build_request_json(
    api_key,
    prompt,
    negative_prompt,
    output_frames,
    matte_color,
    use_index_colors,
    palette_value,
    timeout_settings
  )
    local payload = {
      mode = "animate",
      api_key = api_key,
      prompt = support.normalize_json_text(prompt),
      negative_prompt = support.normalize_json_text(negative_prompt),
      output_frames = output_frames,
      matte_color = matte_color
    }
    support.add_timeout_settings(payload, timeout_settings)

    if use_index_colors then
      payload.palette = palette_value
    else
      payload.colors = tonumber(palette_value)
    end

    return json.encode(payload)
  end

  local function build_keyframe_request_json(
    api_key,
    prompt,
    negative_prompt,
    total_frames,
    matte_color,
    use_index_colors,
    palette_value,
    frames,
    timeout_settings
  )
    local payload = {
      mode = "keyframes",
      api_key = api_key,
      prompt = support.normalize_json_text(prompt),
      total_frames = total_frames,
      render_mode = "pixel",
      matte_color = matte_color,
      frames = frames
    }
    support.add_timeout_settings(payload, timeout_settings)

    local neg = support.normalize_json_text(negative_prompt)
    if neg ~= "" then
      payload.negative_prompt = neg
    end

    if use_index_colors then
      payload.palette = palette_value
    else
      payload.colors = tonumber(palette_value)
    end

    return json.encode(payload)
  end

  local function curl_value(value)
    local text = tostring(value or ""):gsub("\\", "/")
    text = text:gsub('"', '\\"')
    return '"' .. text .. '"'
  end

  local function append_helper_log(log_path, message)
    if not log_path or log_path == "" then
      return
    end

    local existing = support.read_text_file_if_exists(log_path) or ""
    support.write_text_file(log_path, existing .. tostring(message) .. "\n")
  end

  local function write_json_file(path, value)
    support.write_text_file(path, json.encode(value))
  end

  local function read_json_file(path, description)
    if not app.fs.isFile(path) then
      support.fail(description .. " was not created: " .. path)
    end

    local decoded = json.decode(support.read_text_file(path))
    if not decoded then
      support.fail(description .. " returned invalid JSON: " .. path)
    end

    return decoded
  end

  local function write_curl_config(config_path, options)
    local lines = {
      "silent",
      "show-error",
      "location",
      "fail-with-body",
      "connect-timeout = " .. curl_value(options.timeout_seconds),
      "max-time = " .. curl_value(options.timeout_seconds),
      "request = " .. curl_value(options.method or "GET"),
      "url = " .. curl_value(options.url),
      "output = " .. curl_value(options.output_path),
      "stderr = " .. curl_value(options.stderr_path)
    }

    if options.headers then
      for _, header in ipairs(options.headers) do
        table.insert(lines, "header = " .. curl_value(header))
      end
    end

    if options.body_path then
      table.insert(lines, "data-binary = " .. curl_value("@" .. options.body_path))
    end

    support.write_text_file(config_path, table.concat(lines, "\n"))
  end

  local function run_curl(temp_dir, options, log_path)
    local curl_path = support.resolve_curl_path()
    local max_attempts = 4
    local last_error = nil

    for attempt = 1, max_attempts do
      local config_path = app.fs.joinPath(temp_dir, "curl-" .. tostring(math.random(0, 999999)) .. ".conf")
      local stderr_path = app.fs.joinPath(temp_dir, "curl-" .. tostring(math.random(0, 999999)) .. ".stderr.txt")
      options.stderr_path = stderr_path

      write_curl_config(config_path, options)
      append_helper_log(
        log_path,
        "curl "
          .. tostring(options.method or "GET")
          .. " "
          .. tostring(options.url)
          .. " attempt "
          .. attempt
          .. "/"
          .. max_attempts
      )

      local success, exit_code = support.run_shell_command(curl_path .. " --config " .. support.quote_arg(config_path))
      local stderr_text = support.read_text_file_if_exists(stderr_path)
      if stderr_text and stderr_text ~= "" then
        append_helper_log(log_path, stderr_text)
      end

      support.remove_if_exists(config_path)
      support.remove_if_exists(stderr_path)

      if success then
        return true, nil
      end

      last_error = "curl failed with exit code " .. tostring(exit_code or "unknown") .. "."
      if stderr_text and stderr_text ~= "" then
        last_error = last_error .. "\n" .. stderr_text
      end

      if tonumber(exit_code) ~= -1073741502 then
        return false, last_error
      end

      append_helper_log(log_path, "curl process startup failed with 0xC0000142; retrying without launching a sleep helper.")
      support.sleep_seconds(attempt * 2)
    end

    return false, last_error or "curl failed to start."
  end

  local function write_body_dump(result_path, body)
    local body_json = json.encode(body)
    body_json = body_json:gsub('("image"%s*:%s*")([^"]+)', function(prefix, image)
      return prefix .. image:sub(1, 80) .. "...<" .. #image .. " chars total>"
    end)
    support.write_text_file(result_path .. ".body-sent.json", body_json)
  end

  local function make_auth_headers(api_key)
    return {
      "Authorization: Bearer " .. tostring(api_key or ""),
      "Content-Type: application/json"
    }
  end

  local function build_curl_animate_body(request, image_path)
    if not app.fs.isFile(image_path) then
      support.fail("Input image not found: " .. image_path)
    end

    local body = {
      image = support.base64_encode(support.read_text_file(image_path)),
      prompt = request.prompt,
      output_frames = tonumber(request.output_frames),
      output_format = "spritesheet",
      pixel_config = {}
    }

    if request.palette ~= nil then
      body.pixel_config.palette = {}
      for i, color in ipairs(request.palette) do
        body.pixel_config.palette[i] = tostring(color)
      end
    elseif request.colors ~= nil then
      body.pixel_config.colors = tonumber(request.colors)
    else
      support.fail("Request must include either palette colors or a palette size.")
    end

    if request.negative_prompt and tostring(request.negative_prompt) ~= "" then
      body.negative_prompt = request.negative_prompt
    end

    if request.matte_color and tostring(request.matte_color) ~= "" then
      body.matte_color = request.matte_color
    end

    return body
  end

  local function build_curl_keyframe_body(request)
    local frames = {}
    for _, frame in ipairs(request.frames or {}) do
      local path = tostring(frame.image_path or "")
      if path == "" or not app.fs.isFile(path) then
        support.fail("Keyframe image not found: " .. path)
      end

      local frame_body = {
        index = tonumber(frame.index),
        image = support.base64_encode(support.read_text_file(path))
      }
      if frame.strength ~= nil then
        frame_body.strength = tonumber(frame.strength)
      end
      table.insert(frames, frame_body)
    end

    if #frames < 1 then
      support.fail("Keyframe request must include at least one frame.")
    end

    local body = {
      prompt = request.prompt,
      render_mode = "pixel",
      total_frames = tonumber(request.total_frames),
      frames = frames,
      output_format = "spritesheet",
      pixel_config = {}
    }

    if request.negative_prompt and tostring(request.negative_prompt) ~= "" then
      body.negative_prompt = request.negative_prompt
    end

    if request.matte_color and tostring(request.matte_color) ~= "" then
      body.matte_color = request.matte_color
    end

    if request.seed ~= nil then
      body.seed = tonumber(request.seed)
    end

    if request.palette ~= nil then
      body.pixel_config.palette = {}
      for i, color in ipairs(request.palette) do
        body.pixel_config.palette[i] = tostring(color)
      end
    elseif request.colors ~= nil then
      body.pixel_config.colors = tonumber(request.colors)
    else
      support.fail("Keyframe request requires palette colors or a palette size.")
    end

    return body
  end

  local function curl_api_error(response, fallback)
    if response and response.error then
      if type(response.error) == "table" and response.error.message then
        return tostring(response.error.message)
      end
      return tostring(response.error)
    end
    return fallback or "Pixel Engine request failed."
  end

  local function run_curl_helper(temp_dir, request_path, image_path, result_path, output_path, log_path)
    local request = read_json_file(request_path, "Pixel Engine request")
    local timeout = tonumber(request.request_timeout_seconds) or config.DEFAULT_REQUEST_TIMEOUT_SECONDS
    local job_timeout = tonumber(request.job_timeout_seconds) or config.DEFAULT_JOB_TIMEOUT_SECONDS
    local poll_interval = tonumber(request.poll_interval_seconds) or config.DEFAULT_POLL_INTERVAL_SECONDS
    local mode = tostring(request.mode or "animate")
    local endpoint = "https://api.pixelengine.ai/functions/v1/animate"
    local body = nil

    support.write_text_file(log_path, "curl helper started\nmode=" .. mode .. "\n")
    if mode == "keyframes" then
      endpoint = "https://api.pixelengine.ai/functions/v1/keyframes"
      body = build_curl_keyframe_body(request)
    else
      body = build_curl_animate_body(request, image_path)
    end

    write_body_dump(result_path, body)

    local submit_body_path = app.fs.joinPath(temp_dir, "curl-submit-body.json")
    local submit_response_path = app.fs.joinPath(temp_dir, "curl-submit-response.json")
    write_json_file(submit_body_path, body)

    local ok, error_message = run_curl(temp_dir, {
      method = "POST",
      url = endpoint,
      headers = make_auth_headers(request.api_key),
      body_path = submit_body_path,
      output_path = submit_response_path,
      timeout_seconds = timeout
    }, log_path)
    support.remove_if_exists(submit_body_path)

    local submit_response = nil
    if app.fs.isFile(submit_response_path) then
      submit_response = json.decode(support.read_text_file(submit_response_path))
    end
    support.remove_if_exists(submit_response_path)

    if not ok then
      support.write_text_file(result_path, json.encode{
        ok = false,
        error = curl_api_error(submit_response, error_message) .. "\nLog: " .. tostring(log_path)
      })
      return read_json_file(result_path, "Pixel Engine result")
    end

    if not submit_response or not submit_response.api_job_id then
      support.write_text_file(result_path, json.encode{
        ok = false,
        error = "Pixel Engine did not return an api_job_id."
      })
      return read_json_file(result_path, "Pixel Engine result")
    end

    local job_id = tostring(submit_response.api_job_id)
    local start_time = os.time()
    local job = submit_response
    local poll_count = 0
    while true do
      if tostring(job.status or "") == "success" then
        break
      end
      if tostring(job.status or "") == "failure" then
        support.write_text_file(result_path, json.encode{
          ok = false,
          error = curl_api_error(job, "Generation failed."),
          api_job_id = job_id,
          status = job.status
        })
        return read_json_file(result_path, "Pixel Engine result")
      end
      if os.time() - start_time >= job_timeout then
        support.write_text_file(result_path, json.encode{
          ok = false,
          error = "Timed out waiting for Pixel Engine after " .. job_timeout .. " seconds.",
          api_job_id = job_id,
          status = job.status
        })
        return read_json_file(result_path, "Pixel Engine result")
      end

      poll_count = poll_count + 1
      support.sleep_seconds(poll_interval)
      if poll_count >= 3 and poll_interval < config.MAX_POLL_INTERVAL_SECONDS then
        poll_interval = math.min(config.MAX_POLL_INTERVAL_SECONDS, poll_interval + 2)
      end

      local job_response_path = app.fs.joinPath(temp_dir, "curl-job-response.json")
      ok, error_message = run_curl(temp_dir, {
        method = "GET",
        url = "https://api.pixelengine.ai/functions/v1/jobs?id=" .. job_id,
        headers = { "Authorization: Bearer " .. tostring(request.api_key or "") },
        output_path = job_response_path,
        timeout_seconds = timeout
      }, log_path)
      if app.fs.isFile(job_response_path) then
        job = json.decode(support.read_text_file(job_response_path)) or job
      end
      support.remove_if_exists(job_response_path)

      if not ok then
        support.write_text_file(result_path, json.encode{
          ok = false,
          error = tostring(error_message) .. "\nLog: " .. tostring(log_path),
          api_job_id = job_id,
          status = job.status
        })
        return read_json_file(result_path, "Pixel Engine result")
      end
    end

    if not job.output or not job.output.url then
      support.write_text_file(result_path, json.encode{
        ok = false,
        error = "Pixel Engine job succeeded but no download URL was returned.",
        api_job_id = job_id,
        status = job.status
      })
      return read_json_file(result_path, "Pixel Engine result")
    end

    ok, error_message = run_curl(temp_dir, {
      method = "GET",
      url = tostring(job.output.url),
      output_path = output_path,
      timeout_seconds = timeout
    }, log_path)

    if not ok then
      support.write_text_file(result_path, json.encode{
        ok = false,
        error = tostring(error_message) .. "\nLog: " .. tostring(log_path),
        api_job_id = job_id,
        status = job.status
      })
      return read_json_file(result_path, "Pixel Engine result")
    end

    support.write_text_file(result_path, json.encode{
      ok = true,
      error = nil,
      api_job_id = job_id,
      status = job.status,
      content_type = job.output.content_type,
      output_image_path = output_path,
      metadata = job.output.metadata or {
        frame_count = tonumber(request.output_frames) or tonumber(request.total_frames),
        fps = config.DEFAULT_FPS
      }
    })

    return read_json_file(result_path, "Pixel Engine result")
  end

  local function build_temp_paths(temp_dir, plugin_path)
    return {
      request = app.fs.joinPath(temp_dir, config.TEMP_FILES.request),
      input = app.fs.joinPath(temp_dir, config.TEMP_FILES.input),
      enhance_request = app.fs.joinPath(temp_dir, config.TEMP_FILES.enhance_request),
      enhance_result = app.fs.joinPath(temp_dir, config.TEMP_FILES.enhance_result),
      result = app.fs.joinPath(temp_dir, config.TEMP_FILES.result),
      output = app.fs.joinPath(temp_dir, config.TEMP_FILES.output),
      helper_log = app.fs.joinPath(temp_dir, config.TEMP_FILES.helper_log),
      enhance_helper_log = app.fs.joinPath(temp_dir, config.TEMP_FILES.enhance_helper_log)
    }
  end

  local function normalize_animate_preferences(preferences, env_api_key)
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
      enhance_prompt = preferences.enhance_prompt and true or false,
      use_index_colors = use_index_colors,
      palette_size = palette_size
    }
  end

  local function normalize_keyframe_preferences(preferences, env_api_key)
    local use_index_colors = preferences.keyframes_use_index_colors
    if use_index_colors == nil then
      use_index_colors = true
    end

    local palette_size = tostring(preferences.keyframes_palette_size or config.DEFAULT_PALETTE_SIZE)
    if not is_valid_palette_size(palette_size) then
      palette_size = config.DEFAULT_PALETTE_SIZE
    end

    return {
      api_key = env_api_key or preferences.api_key or "",
      prompt = preferences.keyframes_prompt or "",
      negative_prompt = preferences.keyframes_negative_prompt or "",
      total_frames = tonumber(preferences.keyframes_total_frames) or config.DEFAULT_FRAMES,
      matte_color = preferences.keyframes_matte_color or config.DEFAULT_MATTE_COLOR,
      enhance_prompt = preferences.keyframes_enhance_prompt and true or false,
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

  local function persist_animate_preferences(preferences, values)
    preferences.api_key = values.api_key
    preferences.prompt = values.prompt
    preferences.negative_prompt = values.negative_prompt
    preferences.output_frames = values.output_frames
    preferences.matte_color = values.matte_color
    preferences.enhance_prompt = values.enhance_prompt
    preferences.use_index_colors = values.use_index_colors
    preferences.palette_size = values.palette_size
  end

  local function persist_keyframe_preferences(preferences, values)
    preferences.api_key = values.api_key
    preferences.keyframes_prompt = values.prompt
    preferences.keyframes_negative_prompt = values.negative_prompt
    preferences.keyframes_total_frames = values.total_frames
    preferences.keyframes_matte_color = values.matte_color
    preferences.keyframes_enhance_prompt = values.enhance_prompt
    preferences.keyframes_use_index_colors = values.use_index_colors
    preferences.keyframes_palette_size = values.palette_size
  end

  local function build_animate_dialog(initial_values)
    local dialog = Dialog(config.COMMAND_TITLE)
    local masked_api_key = mask_api_key(initial_values.api_key)

    dialog:newrow{ always=true }
    dialog:entry{
      id = "api_key",
      label = "API Key",
      text = masked_api_key,
      focus = (initial_values.api_key == "")
    }
    dialog:entry{
      id = "prompt",
      label = "Prompt",
      text = initial_values.prompt,
      focus = (initial_values.api_key ~= "")
    }
    dialog:entry{
      id = "negative_prompt",
      label = "Negative",
      text = initial_values.negative_prompt
    }
    dialog:check{
      id = "enhance_prompt",
      text = "Enhance prompt",
      selected = initial_values.enhance_prompt
    }
    dialog:number{
      id = "output_frames",
      label = "Frames",
      text = tostring(initial_values.output_frames),
      decimals = 0
    }
    dialog:separator()
    dialog:color{
      id = "matte_color",
      label = "Matte",
      color = support.hex_to_color(initial_values.matte_color, config.DEFAULT_MATTE_COLOR)
    }
    dialog:combobox{
      id = "palette_size",
      label = "Palette Size",
      option = initial_values.palette_size,
      options = config.PALETTE_SIZE_OPTIONS,
      enabled = not initial_values.use_index_colors
    }
    dialog:check{
      id = "use_index_colors",
      text = "Use index colors",
      selected = initial_values.use_index_colors,
      onclick = function()
        dialog:modify{
          id = "palette_size",
          enabled = not dialog.data.use_index_colors
        }
      end
    }
    dialog:newrow{ always=false }
    dialog:button{ id = "ok", text = "Generate", focus = true }
    dialog:button{ id = "cancel", text = "Cancel" }

    return dialog
  end

  local function build_keyframe_dialog(initial_values)
    local dialog = Dialog(config.COMMAND_TITLE_KEYFRAMES)
    local masked_api_key = mask_api_key(initial_values.api_key)

    dialog:newrow{ always=true }
    dialog:entry{
      id = "api_key",
      label = "API Key",
      text = masked_api_key,
      focus = (initial_values.api_key == "")
    }
    dialog:entry{
      id = "prompt",
      label = "Prompt",
      text = initial_values.prompt,
      focus = (initial_values.api_key ~= "")
    }
    dialog:entry{
      id = "negative_prompt",
      label = "Negative",
      text = initial_values.negative_prompt
    }
    dialog:check{
      id = "enhance_prompt",
      text = "Enhance prompt",
      selected = initial_values.enhance_prompt
    }
    dialog:number{
      id = "total_frames",
      label = "Output frames",
      text = tostring(initial_values.total_frames),
      decimals = 0
    }
    dialog:separator{ text = "First 1-8 cels sent as keyframes (evenly spaced)." }
    dialog:separator()
    dialog:color{
      id = "matte_color",
      label = "Matte",
      color = support.hex_to_color(initial_values.matte_color, config.DEFAULT_MATTE_COLOR)
    }
    dialog:combobox{
      id = "palette_size",
      label = "Palette Size",
      option = initial_values.palette_size,
      options = config.PALETTE_SIZE_OPTIONS,
      enabled = not initial_values.use_index_colors
    }
    dialog:check{
      id = "use_index_colors",
      text = "Use index colors",
      selected = initial_values.use_index_colors,
      onclick = function()
        dialog:modify{
          id = "palette_size",
          enabled = not dialog.data.use_index_colors
        }
      end
    }
    dialog:newrow{ always=false }
    dialog:button{ id = "ok", text = "Generate", focus = true }
    dialog:button{ id = "cancel", text = "Cancel" }

    return dialog
  end

  local function parse_animate_dialog_values(data, initial_values, env_api_key)
    local masked_api_key = mask_api_key(initial_values.api_key)
    local values = {
      api_key = support.trim(data.api_key),
      prompt = support.trim(data.prompt),
      negative_prompt = support.trim(data.negative_prompt),
      output_frames = math.floor(tonumber(data.output_frames) or 0),
      matte_color = support.color_to_hex(
        data.matte_color or support.hex_to_color(initial_values.matte_color, config.DEFAULT_MATTE_COLOR)
      ),
      enhance_prompt = data.enhance_prompt and true or false,
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

  local function parse_keyframe_dialog_values(data, initial_values, env_api_key)
    local masked_api_key = mask_api_key(initial_values.api_key)

    local values = {
      api_key = support.trim(data.api_key),
      prompt = support.trim(data.prompt),
      negative_prompt = support.trim(data.negative_prompt),
      total_frames = math.floor(tonumber(data.total_frames) or 0),
      matte_color = support.color_to_hex(
        data.matte_color or support.hex_to_color(initial_values.matte_color, config.DEFAULT_MATTE_COLOR)
      ),
      enhance_prompt = data.enhance_prompt and true or false,
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

  local function run_animate_generation(plugin)
    local sprite = app.sprite
    local current_frame = app.frame
    local preferences = plugin.preferences
    local env_api_key = support.read_env_key(plugin.path)
    local timeout_settings = support.read_timeout_settings(plugin.path)
    local initial_values = normalize_animate_preferences(preferences, env_api_key)
    local dialog = build_animate_dialog(initial_values)
    local data = dialog:show().data

    if not data.ok then
      return
    end

    local values = parse_animate_dialog_values(data, initial_values, env_api_key)
    validate_common(sprite, values.prompt, values.api_key)
    validate_animate_inputs(
      sprite,
      values.output_frames,
      values.use_index_colors,
      values.palette_size
    )
    persist_animate_preferences(preferences, values)

    local temp_dir = support.make_temp_dir()
    local paths = build_temp_paths(temp_dir, plugin.path)
    local ok, result_or_error = pcall(function()
      sprite_ops.render_active_frame(sprite, current_frame.frameNumber, paths.input)

      local pixel_engine_prompt = values.prompt
      if values.enhance_prompt then
        pixel_engine_prompt = prompt_enhance.enhance(plugin.path, {
          request = paths.enhance_request,
          result = paths.enhance_result,
          log = paths.enhance_helper_log,
          image = paths.input
        }, values.prompt, values.api_key)
      end

      local palette_value = values.palette_size
      if values.use_index_colors then
        palette_value = sprite_ops.collect_palette_colors(sprite)
      end

      support.write_text_file(
        paths.request,
        build_request_json(
          values.api_key,
          pixel_engine_prompt,
          values.negative_prompt,
          values.output_frames,
          values.matte_color,
          values.use_index_colors,
          palette_value,
          timeout_settings
        )
      )

      local result = run_curl_helper(temp_dir, paths.request, paths.input, paths.result, paths.output, paths.helper_log)
      local layer_name, imported_frames = sprite_ops.import_spritesheet(
        sprite,
        current_frame.frameNumber,
        paths.output,
        result.metadata or {
          frame_count = values.output_frames,
          fps = config.DEFAULT_FPS
        }
      )

      return {
        layer_name = layer_name,
        imported_frames = imported_frames,
        api_job_id = result.api_job_id,
        enhanced_prompt = values.enhance_prompt and pixel_engine_prompt or nil
      }
    end)

    if not ok then
      support.log("Generation failed: " .. tostring(result_or_error))
      support.remove_sensitive_failure_files(paths)
      local body_dump = paths.result .. ".body-sent.json"
      local lines = { tostring(result_or_error) }
      if app.fs.isFile(paths.result) then
        table.insert(lines, "")
        table.insert(lines, "Diagnostic result saved to:")
        table.insert(lines, paths.result)
      end
      if app.fs.isFile(body_dump) then
        table.insert(lines, "")
        table.insert(lines, "Sent body saved to:")
        table.insert(lines, body_dump)
      end
      app.alert{ title = config.COMMAND_TITLE, text = lines }
      return
    end

    support.cleanup_temp_dir(temp_dir, {
      paths.request,
      paths.input,
      paths.enhance_request,
      paths.enhance_result,
      paths.result,
      paths.output,
      paths.helper_log,
      paths.enhance_helper_log
    })

    local alert_text = {
      "Imported " .. result_or_error.imported_frames .. " frames into layer '" .. result_or_error.layer_name .. "'.",
      "Job ID: " .. tostring(result_or_error.api_job_id)
    }

    if result_or_error.enhanced_prompt and result_or_error.enhanced_prompt ~= "" then
      table.insert(alert_text, "Enhanced prompt:")

      for _, line in ipairs(support.wrap_text(result_or_error.enhanced_prompt, 64)) do
        table.insert(alert_text, line)
      end
    end

    app.alert{
      title = config.COMMAND_TITLE,
      text = alert_text
    }
  end

  local function run_keyframe_generation(plugin)
    local sprite = app.sprite
    local current_frame = app.frame
    local preferences = plugin.preferences
    local env_api_key = support.read_env_key(plugin.path)
    local timeout_settings = support.read_timeout_settings(plugin.path)
    local initial_values = normalize_keyframe_preferences(preferences, env_api_key)
    local dialog = build_keyframe_dialog(initial_values)
    local data = dialog:show().data

    if not data.ok then
      return
    end

    local values = parse_keyframe_dialog_values(data, initial_values, env_api_key)
    validate_common(sprite, values.prompt, values.api_key)
    validate_keyframe_inputs(
      sprite,
      values.total_frames,
      values.use_index_colors,
      values.palette_size
    )
    persist_keyframe_preferences(preferences, values)

    local sprite_frame_count = #sprite.frames
    local keyframe_count = math.min(config.KEYFRAME_MAX_SOURCES, sprite_frame_count)

    local indices = keyframe_output_indices(values.total_frames, keyframe_count)

    local temp_dir = support.make_temp_dir()
    local paths = build_temp_paths(temp_dir, plugin.path)
    local keyframe_paths = {}
    local ok, result_or_error = pcall(function()
      for i = 1, keyframe_count do
        local out_path
        if i == 1 then
          out_path = paths.input
        else
          out_path = app.fs.joinPath(temp_dir, "keyframe-" .. i .. ".png")
        end
        keyframe_paths[i] = out_path
        sprite_ops.render_active_frame(sprite, i, out_path)
      end

      local pixel_engine_prompt = values.prompt
      if values.enhance_prompt then
        pixel_engine_prompt = prompt_enhance.enhance(plugin.path, {
          request = paths.enhance_request,
          result = paths.enhance_result,
          log = paths.enhance_helper_log,
          image = paths.input
        }, values.prompt, values.api_key)
      end

      local palette_value = values.palette_size
      if values.use_index_colors then
        palette_value = sprite_ops.collect_palette_colors(sprite)
      end

      local frames_payload = {}
      for i = 1, keyframe_count do
        table.insert(frames_payload, {
          index = indices[i],
          image_path = keyframe_paths[i]
        })
      end

      support.write_text_file(
        paths.request,
        build_keyframe_request_json(
          values.api_key,
          pixel_engine_prompt,
          values.negative_prompt,
          values.total_frames,
          values.matte_color,
          values.use_index_colors,
          palette_value,
          frames_payload,
          timeout_settings
        )
      )

      local result = run_curl_helper(temp_dir, paths.request, paths.input, paths.result, paths.output, paths.helper_log)
      local layer_name, imported_frames = sprite_ops.import_spritesheet(
        sprite,
        current_frame.frameNumber,
        paths.output,
        result.metadata or {
          frame_count = values.total_frames,
          fps = config.DEFAULT_FPS
        }
      )

      return {
        layer_name = layer_name,
        imported_frames = imported_frames,
        api_job_id = result.api_job_id,
        enhanced_prompt = values.enhance_prompt and pixel_engine_prompt or nil
      }
    end)

    if not ok then
      support.log("Keyframe generation failed: " .. tostring(result_or_error))
      support.remove_sensitive_failure_files(paths)
      local body_dump = paths.result .. ".body-sent.json"
      local lines = { tostring(result_or_error) }
      if app.fs.isFile(paths.result) then
        table.insert(lines, "")
        table.insert(lines, "Diagnostic result saved to:")
        table.insert(lines, paths.result)
      end
      if app.fs.isFile(body_dump) then
        table.insert(lines, "")
        table.insert(lines, "Sent body saved to:")
        table.insert(lines, body_dump)
      end
      app.alert{ title = config.COMMAND_TITLE_KEYFRAMES, text = lines }
      return
    end

    local cleanup_files = {
      paths.request,
      paths.input,
      paths.enhance_request,
      paths.enhance_result,
      paths.result,
      paths.output,
      paths.helper_log,
      paths.enhance_helper_log
    }
    for i = 2, keyframe_count do
      table.insert(cleanup_files, keyframe_paths[i])
    end

    support.cleanup_temp_dir(temp_dir, cleanup_files)

    local alert_text = {
      "Imported " .. result_or_error.imported_frames .. " frames into layer '" .. result_or_error.layer_name .. "'.",
      "Job ID: " .. tostring(result_or_error.api_job_id)
    }

    if result_or_error.enhanced_prompt and result_or_error.enhanced_prompt ~= "" then
      table.insert(alert_text, "Enhanced prompt:")

      for _, line in ipairs(support.wrap_text(result_or_error.enhanced_prompt, 64)) do
        table.insert(alert_text, line)
      end
    end

    app.alert{
      title = config.COMMAND_TITLE_KEYFRAMES,
      text = alert_text
    }
  end

  function command.init(plugin)
    if plugin.preferences.output_frames == nil then
      plugin.preferences.output_frames = config.DEFAULT_FRAMES
    end

    if plugin.preferences.matte_color == nil then
      plugin.preferences.matte_color = config.DEFAULT_MATTE_COLOR
    end

    if plugin.preferences.enhance_prompt == nil then
      plugin.preferences.enhance_prompt = false
    end

    if plugin.preferences.keyframes_total_frames == nil then
      plugin.preferences.keyframes_total_frames = config.DEFAULT_FRAMES
    end

    if plugin.preferences.keyframes_matte_color == nil then
      plugin.preferences.keyframes_matte_color = config.DEFAULT_MATTE_COLOR
    end

    if plugin.preferences.keyframes_enhance_prompt == nil then
      plugin.preferences.keyframes_enhance_prompt = false
    end

    plugin:newCommand{
      id = config.COMMAND_ID,
      title = config.COMMAND_TITLE,
      group = "file_scripts",
      onclick = function()
        run_animate_generation(plugin)
      end,
      onenabled = function()
        return app.sprite ~= nil and app.frame ~= nil
      end
    }

    plugin:newCommand{
      id = config.COMMAND_ID_KEYFRAMES,
      title = config.COMMAND_TITLE_KEYFRAMES,
      group = "file_scripts",
      onclick = function()
        run_keyframe_generation(plugin)
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
