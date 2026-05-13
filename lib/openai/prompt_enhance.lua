return function(config, support)
  local prompt_enhance = {}

  local ENHANCE_PROMPT = "Rewrite the input into a high-quality pixel-art animation prompt. Preserve the original idea, but expand it into a visually precise description of the subject, motion, surface/material changes, lighting, and looping secondary effects. Use animator-friendly language that describes exactly what moves, how it moves, and what remains still. Avoid camera language and technical jargon. Output a single polished sentence. Never include quotes, apostrphies, or other characters which may cause issues in JSON."

  local function curl_value(value)
    local text = tostring(value or ""):gsub("\\", "/")
    text = text:gsub('"', '\\"')
    return '"' .. text .. '"'
  end

  local function append_log(log_path, message)
    if not log_path or log_path == "" then
      return
    end

    local existing = support.read_text_file_if_exists(log_path) or ""
    support.write_text_file(log_path, existing .. tostring(message) .. "\n")
  end

  local function write_curl_config(config_path, options)
    local lines = {
      "silent",
      "show-error",
      "location",
      "fail-with-body",
      "connect-timeout = " .. curl_value(options.timeout_seconds),
      "max-time = " .. curl_value(options.timeout_seconds),
      "request = " .. curl_value("POST"),
      "url = " .. curl_value(options.url),
      "output = " .. curl_value(options.output_path),
      "stderr = " .. curl_value(options.stderr_path),
      "data-binary = " .. curl_value("@" .. options.body_path)
    }

    for _, header in ipairs(options.headers or {}) do
      table.insert(lines, "header = " .. curl_value(header))
    end

    support.write_text_file(config_path, table.concat(lines, "\n"))
  end

  local function run_curl(temp_dir, options, log_path)
    local curl_path = support.resolve_curl_path()
    local config_path = app.fs.joinPath(temp_dir, "curl-prompt-" .. tostring(math.random(0, 999999)) .. ".conf")
    local stderr_path = app.fs.joinPath(temp_dir, "curl-prompt-" .. tostring(math.random(0, 999999)) .. ".stderr.txt")
    options.stderr_path = stderr_path

    write_curl_config(config_path, options)
    append_log(log_path, "curl POST " .. tostring(options.url))

    local success, exit_code = support.run_shell_command(curl_path .. " --config " .. support.quote_arg(config_path))
    local stderr_text = support.read_text_file_if_exists(stderr_path)
    if stderr_text and stderr_text ~= "" then
      append_log(log_path, stderr_text)
    end

    support.remove_if_exists(config_path)
    support.remove_if_exists(stderr_path)

    if not success then
      local message = "curl failed with exit code " .. tostring(exit_code or "unknown") .. "."
      if stderr_text and stderr_text ~= "" then
        message = message .. "\n" .. stderr_text
      end
      return false, message
    end

    return true, nil
  end

  local function response_error(response, fallback)
    if response and response.error then
      if type(response.error) == "table" and response.error.message then
        return tostring(response.error.message)
      end
      return tostring(response.error)
    end
    return fallback
  end

  local function extract_openai_text(response)
    if response.output_text and support.trim(response.output_text) ~= "" then
      return tostring(response.output_text)
    end

    if response.output then
      for _, item in ipairs(response.output) do
        if item.type == "message" and item.content then
          for _, content in ipairs(item.content) do
            if content.type == "output_text" and content.text and support.trim(content.text) ~= "" then
              return tostring(content.text)
            end
          end
        end
      end
    end

    return nil
  end

  local function openai_reasoning_effort(model)
    local value = tostring(model or "")
    if value:match("^gpt%-5%.1") or value:match("^gpt%-5%.2") or value:match("^gpt%-5%.4") then
      return "none"
    end

    return "minimal"
  end

  local function run_prompt_curl(plugin_path, paths, body, api_key, url, source_name, response_to_prompt)
    local temp_dir = tostring(paths.result):match("^(.*)[/\\][^/\\]*$") or app.fs.tempPath
    local body_path = app.fs.joinPath(temp_dir, "curl-prompt-body.json")
    local response_path = app.fs.joinPath(temp_dir, "curl-prompt-response.json")
    local timeout = support.read_timeout_settings(plugin_path).request_timeout_seconds

    support.write_text_file(paths.log, "curl prompt helper started\nsource=" .. source_name .. "\n")
    support.write_text_file(body_path, json.encode(body))

    local ok, error_message = run_curl(temp_dir, {
      url = url,
      headers = {
        "Authorization: Bearer " .. tostring(api_key or ""),
        "Content-Type: application/json"
      },
      body_path = body_path,
      output_path = response_path,
      timeout_seconds = timeout
    }, paths.log)
    support.remove_if_exists(body_path)

    local response = nil
    if app.fs.isFile(response_path) then
      response = json.decode(support.read_text_file(response_path))
    end
    support.remove_if_exists(response_path)

    if not ok then
      support.fail(
        response_error(response, error_message or (source_name .. " prompt enhancement failed."))
          .. "\nLog: "
          .. tostring(paths.log)
      )
    end

    if not response then
      support.fail(source_name .. " prompt enhancement returned invalid JSON.")
    end

    local prompt = support.trim(support.normalize_json_text(response_to_prompt(response) or ""))
    if prompt == "" then
      support.fail(source_name .. " prompt enhancement returned an empty prompt.")
    end

    return prompt
  end

  local function read_settings(plugin_path)
    return {
      use_custom_enhance = support.read_env_bool(plugin_path, config.ENV_USE_CUSTOM_ENHANCE),
      openai_api_key = support.read_env_value(plugin_path, config.ENV_OPENAI_API_KEY) or "",
      openai_model = support.read_env_value(plugin_path, config.ENV_OPENAI_MODEL) or "",
      timeout_settings = support.read_timeout_settings(plugin_path)
    }
  end

  function prompt_enhance.assert_configured(plugin_path, api_key)
    local settings = read_settings(plugin_path)

    if settings.use_custom_enhance then
      if settings.openai_api_key == "" then
        support.fail("Custom prompt enhancement requires OPENAI_API_KEY in .env.")
      end

      if settings.openai_model == "" then
        support.fail("Custom prompt enhancement requires OPENAI_MODEL in .env.")
      end

      return settings
    end

    if support.trim(api_key) == "" then
      support.fail("Prompt enhancement requires a Pixel Engine API key.")
    end

    return settings
  end

  function prompt_enhance.enhance(plugin_path, paths, prompt, api_key)
    local settings = prompt_enhance.assert_configured(plugin_path, api_key)
    local image_base64 = nil
    if app.fs.isFile(paths.image) then
      image_base64 = support.base64_encode(support.read_text_file(paths.image))
    end

    if settings.use_custom_enhance then
      local content = {
        {
          type = "input_text",
          text = support.normalize_json_text(prompt)
        }
      }
      if image_base64 then
        table.insert(content, {
          type = "input_image",
          image_url = "data:image/png;base64," .. image_base64,
          detail = "low"
        })
      end

      local body = {
        model = settings.openai_model,
        instructions = support.normalize_json_text(ENHANCE_PROMPT),
        max_output_tokens = 400,
        reasoning = {
          effort = openai_reasoning_effort(settings.openai_model)
        },
        text = {
          verbosity = "low"
        },
        input = {
          {
            role = "user",
            content = content
          }
        }
      }

      return run_prompt_curl(
        plugin_path,
        paths,
        body,
        settings.openai_api_key,
        "https://api.openai.com/v1/responses",
        "OpenAI",
        extract_openai_text
      )
    end

    local body = {
      prompt = support.normalize_json_text(prompt)
    }
    if image_base64 then
      body.image = image_base64
    end

    return run_prompt_curl(
      plugin_path,
      paths,
      body,
      api_key,
      "https://api.pixelengine.ai/functions/v1/enhance-prompt",
      "Pixel Engine",
      function(response)
        return response.enhanced_prompt
      end
    )
  end

  return prompt_enhance
end
