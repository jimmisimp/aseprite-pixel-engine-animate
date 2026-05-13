return function(config, support, sprite_ops, prompt_enhance)
  local command = {}
  local active_jobs = {}

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

      append_helper_log(log_path, "curl process startup failed with 0xC0000142; retrying.")
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

  local function has_active_job()
    for _, job in ipairs(active_jobs) do
      if job.timer and job.timer.isRunning then
        return true
      end
    end

    return false
  end

  local function remove_active_job(state)
    for i = #active_jobs, 1, -1 do
      if active_jobs[i] == state then
        table.remove(active_jobs, i)
      end
    end
  end

  local function truncate_status(value, max_length)
    local text = support.normalize_json_text(value or "")
    text = text:gsub("\n", " ")
    local limit = tonumber(max_length) or 72
    if #text <= limit then
      return text
    end

    return text:sub(1, limit - 3) .. "..."
  end

  local function set_progress_status(state, status, detail)
    state.status_text = status or state.status_text or ""
    state.detail_text = detail or state.detail_text or ""

    if not state.dialog then
      return
    end

    pcall(function()
      state.dialog:modify{ id = "status", text = truncate_status(state.status_text, 76) }
      state.dialog:modify{ id = "detail", text = truncate_status(state.detail_text, 76) }
    end)
  end

  local function close_progress_dialog(state)
    if state.dialog then
      pcall(function()
        state.dialog:close()
      end)
      state.dialog = nil
    end
  end

  local function stop_generation_timer(state)
    if state.timer and state.timer.isRunning then
      state.timer:stop()
    end
  end

  local function generation_cleanup_files(state)
    local paths = state.paths or {}
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

    if state.keyframe_paths then
      for i = 2, #state.keyframe_paths do
        table.insert(cleanup_files, state.keyframe_paths[i])
      end
    end

    return cleanup_files
  end

  local function show_generation_failure(state, message)
    support.log(state.failure_log_prefix .. ": " .. tostring(message))
    support.remove_sensitive_failure_files(state.paths)

    local paths = state.paths or {}
    local body_dump = paths.result and (paths.result .. ".body-sent.json") or nil
    local lines = { tostring(message) }
    if paths.result and app.fs.isFile(paths.result) then
      table.insert(lines, "")
      table.insert(lines, "Diagnostic result saved to:")
      table.insert(lines, paths.result)
    end
    if body_dump and app.fs.isFile(body_dump) then
      table.insert(lines, "")
      table.insert(lines, "Sent body saved to:")
      table.insert(lines, body_dump)
    end
    if paths.helper_log and app.fs.isFile(paths.helper_log) then
      table.insert(lines, "")
      table.insert(lines, "Helper log saved to:")
      table.insert(lines, paths.helper_log)
    end

    app.alert{ title = state.title, text = lines }
  end

  local function show_generation_success(state, summary)
    support.cleanup_temp_dir(state.temp_dir, generation_cleanup_files(state))

    local alert_text = {
      "Imported " .. summary.imported_frames .. " frames into layer '" .. summary.layer_name .. "'.",
      "Job ID: " .. tostring(summary.api_job_id)
    }

    if summary.enhanced_prompt and summary.enhanced_prompt ~= "" then
      table.insert(alert_text, "Enhanced prompt:")

      for _, line in ipairs(support.wrap_text(summary.enhanced_prompt, 64)) do
        table.insert(alert_text, line)
      end
    end

    app.alert{
      title = state.title,
      text = alert_text
    }
  end

  local function write_failure_result(state, payload)
    support.write_text_file(state.paths.result, json.encode(payload))
    support.fail(payload.error or "Pixel Engine request failed.")
  end

  local function prepare_curl_job(state)
    local request = read_json_file(state.paths.request, "Pixel Engine request")
    local mode = tostring(request.mode or "animate")
    local endpoint = "https://api.pixelengine.ai/functions/v1/animate"
    local body = nil

    state.request = request
    state.timeout_seconds = tonumber(request.request_timeout_seconds) or config.DEFAULT_REQUEST_TIMEOUT_SECONDS
    state.job_timeout_seconds = tonumber(request.job_timeout_seconds) or config.DEFAULT_JOB_TIMEOUT_SECONDS
    state.poll_interval_seconds = tonumber(request.poll_interval_seconds) or config.DEFAULT_POLL_INTERVAL_SECONDS

    support.write_text_file(state.paths.helper_log, "curl helper started\nmode=" .. mode .. "\n")
    if mode == "keyframes" then
      endpoint = "https://api.pixelengine.ai/functions/v1/keyframes"
      body = build_curl_keyframe_body(request)
    else
      body = build_curl_animate_body(request, state.paths.input)
    end

    write_body_dump(state.paths.result, body)
    state.curl_endpoint = endpoint
    state.curl_body = body
  end

  local function submit_curl_job(state)
    local submit_body_path = app.fs.joinPath(state.temp_dir, "curl-submit-body.json")
    local submit_response_path = app.fs.joinPath(state.temp_dir, "curl-submit-response.json")
    write_json_file(submit_body_path, state.curl_body)

    local ok, error_message = run_curl(state.temp_dir, {
      method = "POST",
      url = state.curl_endpoint,
      headers = make_auth_headers(state.request.api_key),
      body_path = submit_body_path,
      output_path = submit_response_path,
      timeout_seconds = state.timeout_seconds
    }, state.paths.helper_log)
    support.remove_if_exists(submit_body_path)

    local submit_response = nil
    if app.fs.isFile(submit_response_path) then
      submit_response = json.decode(support.read_text_file(submit_response_path))
    end
    support.remove_if_exists(submit_response_path)

    if not ok then
      write_failure_result(state, {
        ok = false,
        error = curl_api_error(submit_response, error_message) .. "\nLog: " .. tostring(state.paths.helper_log)
      })
    end

    if not submit_response or not submit_response.api_job_id then
      write_failure_result(state, {
        ok = false,
        error = "Pixel Engine did not return an api_job_id."
      })
    end

    state.api_job_id = tostring(submit_response.api_job_id)
    state.job_started_at = os.time()
    state.job = submit_response
    state.poll_count = 0
    state.next_poll_at = os.time() + state.poll_interval_seconds
  end

  local function poll_curl_job(state)
    local job = state.job or {}
    local status = tostring(job.status or "queued")

    if status == "success" then
      state.phase = "download"
      return
    end
    if status == "failure" then
      write_failure_result(state, {
        ok = false,
        error = curl_api_error(job, "Generation failed."),
        api_job_id = state.api_job_id,
        status = job.status
      })
    end
    if os.time() - state.job_started_at >= state.job_timeout_seconds then
      write_failure_result(state, {
        ok = false,
        error = "Timed out waiting for Pixel Engine after " .. state.job_timeout_seconds .. " seconds.",
        api_job_id = state.api_job_id,
        status = job.status
      })
    end

    if os.time() < state.next_poll_at then
      set_progress_status(
        state,
        "Waiting for Pixel Engine",
        "Job " .. state.api_job_id .. " is " .. status .. "."
      )
      return
    end

    state.poll_count = state.poll_count + 1
    set_progress_status(
      state,
      "Checking generation status",
      "Poll " .. state.poll_count .. " for job " .. state.api_job_id .. "."
    )

    local job_response_path = app.fs.joinPath(state.temp_dir, "curl-job-response.json")
    local ok, error_message = run_curl(state.temp_dir, {
      method = "GET",
      url = "https://api.pixelengine.ai/functions/v1/jobs?id=" .. state.api_job_id,
      headers = { "Authorization: Bearer " .. tostring(state.request.api_key or "") },
      output_path = job_response_path,
      timeout_seconds = state.timeout_seconds
    }, state.paths.helper_log)
    if app.fs.isFile(job_response_path) then
      state.job = json.decode(support.read_text_file(job_response_path)) or state.job
    end
    support.remove_if_exists(job_response_path)

    if not ok then
      write_failure_result(state, {
        ok = false,
        error = tostring(error_message) .. "\nLog: " .. tostring(state.paths.helper_log),
        api_job_id = state.api_job_id,
        status = state.job and state.job.status
      })
    end

    if state.poll_count >= 3 and state.poll_interval_seconds < config.MAX_POLL_INTERVAL_SECONDS then
      state.poll_interval_seconds = math.min(config.MAX_POLL_INTERVAL_SECONDS, state.poll_interval_seconds + 2)
    end
    state.next_poll_at = os.time() + state.poll_interval_seconds
  end

  local function download_curl_output(state)
    local job = state.job or {}
    if not job.output or not job.output.url then
      write_failure_result(state, {
        ok = false,
        error = "Pixel Engine job succeeded but no download URL was returned.",
        api_job_id = state.api_job_id,
        status = job.status
      })
    end

    local ok, error_message = run_curl(state.temp_dir, {
      method = "GET",
      url = tostring(job.output.url),
      output_path = state.paths.output,
      timeout_seconds = state.timeout_seconds
    }, state.paths.helper_log)

    if not ok then
      write_failure_result(state, {
        ok = false,
        error = tostring(error_message) .. "\nLog: " .. tostring(state.paths.helper_log),
        api_job_id = state.api_job_id,
        status = job.status
      })
    end

    support.write_text_file(state.paths.result, json.encode{
      ok = true,
      error = nil,
      api_job_id = state.api_job_id,
      status = job.status,
      content_type = job.output.content_type,
      output_image_path = state.paths.output,
      metadata = job.output.metadata or {
        frame_count = tonumber(state.request.output_frames) or tonumber(state.request.total_frames),
        fps = config.DEFAULT_FPS
      }
    })
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

  local function create_progress_dialog(state)
    local dialog = Dialog{
      title = state.title,
      onclose = function()
        state.cancelled = true
      end
    }

    dialog:newrow{ always=true }
    dialog:label{ id = "status", label = "Status", text = "Preparing" }
    dialog:label{ id = "detail", label = "Detail", text = " " }
    dialog:button{
      id = "cancel",
      text = "Cancel",
      onclick = function()
        state.cancelled = true
        set_progress_status(state, "Cancelling", "The remote Pixel Engine job may continue server-side.")
        pcall(function()
          dialog:modify{ id = "cancel", enabled = false }
        end)
      end
    }
    dialog:show{ wait=false }

    state.dialog = dialog
    set_progress_status(state, "Preparing", "Starting " .. state.mode .. " generation.")
  end

  local function finish_generation_job(state, ok, result_or_error)
    local was_cancelled = state.cancelled
    stop_generation_timer(state)
    remove_active_job(state)
    close_progress_dialog(state)

    if was_cancelled and not ok then
      support.remove_sensitive_failure_files(state.paths)
      app.alert{
        title = state.title,
        text = {
          "Generation cancelled.",
          "If a Pixel Engine job was already submitted, it may still complete server-side.",
          state.api_job_id and ("Job ID: " .. tostring(state.api_job_id)) or ""
        }
      }
      return
    end

    if not ok then
      show_generation_failure(state, result_or_error)
      return
    end

    show_generation_success(state, result_or_error)
  end

  local function prepare_generation_request(state)
    local pixel_engine_prompt = state.pixel_engine_prompt or state.values.prompt
    local palette_value = state.values.palette_size
    if state.values.use_index_colors then
      palette_value = sprite_ops.collect_palette_colors(state.sprite)
    end

    if state.mode == "animate" then
      support.write_text_file(
        state.paths.request,
        build_request_json(
          state.values.api_key,
          pixel_engine_prompt,
          state.values.negative_prompt,
          state.values.output_frames,
          state.values.matte_color,
          state.values.use_index_colors,
          palette_value,
          state.timeout_settings
        )
      )
    else
      local frames_payload = {}
      for i = 1, state.keyframe_count do
        table.insert(frames_payload, {
          index = state.indices[i],
          image_path = state.keyframe_paths[i]
        })
      end

      support.write_text_file(
        state.paths.request,
        build_keyframe_request_json(
          state.values.api_key,
          pixel_engine_prompt,
          state.values.negative_prompt,
          state.values.total_frames,
          state.values.matte_color,
          state.values.use_index_colors,
          palette_value,
          frames_payload,
          state.timeout_settings
        )
      )
    end
  end

  local function advance_generation_job(state)
    if state.cancelled then
      support.fail("cancelled")
    end

    if state.phase == "render" then
      if state.mode == "animate" then
        set_progress_status(state, "Rendering source frame", "Exporting the current sprite frame.")
        sprite_ops.render_active_frame(state.sprite, state.source_frame_number, state.paths.input)
      else
        set_progress_status(state, "Rendering keyframes", "Exporting " .. state.keyframe_count .. " source frames.")
        for i = 1, state.keyframe_count do
          local out_path
          if i == 1 then
            out_path = state.paths.input
          else
            out_path = app.fs.joinPath(state.temp_dir, "keyframe-" .. i .. ".png")
          end
          state.keyframe_paths[i] = out_path
          sprite_ops.render_active_frame(state.sprite, i, out_path)
        end
      end
      state.phase = "enhance"
      return
    end

    if state.phase == "enhance" then
      state.pixel_engine_prompt = state.values.prompt
      if state.values.enhance_prompt then
        set_progress_status(state, "Enhancing prompt", "Sending prompt enhancement request.")
        state.pixel_engine_prompt = prompt_enhance.enhance(state.plugin_path, {
          request = state.paths.enhance_request,
          result = state.paths.enhance_result,
          log = state.paths.enhance_helper_log,
          image = state.paths.input
        }, state.values.prompt, state.values.api_key)
      end
      state.phase = "request"
      return
    end

    if state.phase == "request" then
      set_progress_status(state, "Preparing request", "Building Pixel Engine request JSON.")
      prepare_generation_request(state)
      prepare_curl_job(state)
      state.phase = "submit"
      return
    end

    if state.phase == "submit" then
      set_progress_status(state, "Submitting generation", "Starting the Pixel Engine job.")
      submit_curl_job(state)
      set_progress_status(state, "Submitted", "Job " .. state.api_job_id .. " is " .. tostring(state.job.status or "queued") .. ".")
      state.phase = "poll"
      return
    end

    if state.phase == "poll" then
      poll_curl_job(state)
      return
    end

    if state.phase == "download" then
      set_progress_status(state, "Downloading result", "Saving generated image.")
      download_curl_output(state)
      state.result = read_json_file(state.paths.result, "Pixel Engine result")
      state.phase = "import"
      return
    end

    if state.phase == "import" then
      set_progress_status(state, "Importing spritesheet", "Creating frames in Aseprite.")
      local expected_frames = state.mode == "animate" and state.values.output_frames or state.values.total_frames
      local layer_name, imported_frames = sprite_ops.import_spritesheet(
        state.sprite,
        state.source_frame_number,
        state.paths.output,
        state.result.metadata or {
          frame_count = expected_frames,
          fps = config.DEFAULT_FPS
        }
      )

      state.summary = {
        layer_name = layer_name,
        imported_frames = imported_frames,
        api_job_id = state.result.api_job_id,
        enhanced_prompt = state.values.enhance_prompt and state.pixel_engine_prompt or nil
      }
      state.phase = "done"
      return
    end

    if state.phase == "done" then
      finish_generation_job(state, true, state.summary)
    end
  end

  local function start_generation_job(state)
    create_progress_dialog(state)
    table.insert(active_jobs, state)

    state.timer = Timer{
      interval = 0.25,
      ontick = function()
        if state.busy then
          return
        end

        state.busy = true
        local ok, result_or_error = pcall(function()
          advance_generation_job(state)
        end)
        state.busy = false

        if not ok then
          finish_generation_job(state, false, result_or_error)
        end
      end
    }
    state.timer:start()
  end

  local function run_animate_generation(plugin)
    if has_active_job() then
      app.alert{ title = config.COMMAND_TITLE, text = "A Pixel Engine generation is already running." }
      return
    end

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
    start_generation_job{
      title = config.COMMAND_TITLE,
      failure_log_prefix = "Generation failed",
      mode = "animate",
      phase = "render",
      plugin_path = plugin.path,
      sprite = sprite,
      source_frame_number = current_frame.frameNumber,
      values = values,
      timeout_settings = timeout_settings,
      temp_dir = temp_dir,
      paths = paths
    }
  end

  local function run_keyframe_generation(plugin)
    if has_active_job() then
      app.alert{ title = config.COMMAND_TITLE_KEYFRAMES, text = "A Pixel Engine generation is already running." }
      return
    end

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
    start_generation_job{
      title = config.COMMAND_TITLE_KEYFRAMES,
      failure_log_prefix = "Keyframe generation failed",
      mode = "keyframes",
      phase = "render",
      plugin_path = plugin.path,
      sprite = sprite,
      source_frame_number = current_frame.frameNumber,
      values = values,
      timeout_settings = timeout_settings,
      temp_dir = temp_dir,
      paths = paths,
      keyframe_count = keyframe_count,
      keyframe_paths = {},
      indices = indices
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
        return app.sprite ~= nil and app.frame ~= nil and not has_active_job()
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
        return app.sprite ~= nil and app.frame ~= nil and not has_active_job()
      end
    }
  end

  function command.exit(plugin)
    for _, job in ipairs(active_jobs) do
      stop_generation_timer(job)
      close_progress_dialog(job)
      support.remove_sensitive_failure_files(job.paths)
    end
    active_jobs = {}
  end

  return command
end
