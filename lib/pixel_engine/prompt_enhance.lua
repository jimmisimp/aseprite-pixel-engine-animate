return function(config, support)
  local prompt_enhance = {}

  local ENHANCE_PROMPT = "Rewrite the input into a high-quality pixel-art animation prompt. Preserve the original idea, but expand it into a visually precise description of the subject, motion, surface/material changes, lighting, and looping secondary effects. Use animator-friendly language that describes exactly what moves, how it moves, and what remains still. Avoid camera language and technical jargon. Output a single polished sentence. Never include quotes, apostrphies, or other characters which may cause issues in JSON."

  local function build_request_json(api_key, model, prompt)
    return json.encode{
      api_key = api_key,
      model = model,
      instructions = support.normalize_json_text(ENHANCE_PROMPT),
      prompt = support.normalize_json_text(prompt)
    }
  end

  local function run_helper(helper_path, request_path, image_path, result_path)
    local command_line = table.concat({
      "powershell.exe",
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", support.quote_arg(helper_path),
      "-RequestPath", support.quote_arg(request_path),
      "-ImagePath", support.quote_arg(image_path),
      "-ResultPath", support.quote_arg(result_path)
    }, " ")

    os.execute(command_line)

    if not app.fs.isFile(result_path) then
      support.fail("The OpenAI prompt helper did not return a result.")
    end

    local result = json.decode(support.read_text_file(result_path))
    if not result then
      support.fail("The OpenAI prompt helper returned invalid JSON.")
    end

    if not result.ok then
      support.fail(result.error or "OpenAI prompt enhancement failed.")
    end

    local prompt = support.trim(support.normalize_json_text(result.prompt))
    if prompt == "" then
      support.fail("OpenAI prompt enhancement returned an empty prompt.")
    end

    return prompt
  end

  local function read_settings(plugin_path)
    return {
      api_key = support.read_env_value(plugin_path, config.ENV_OPENAI_API_KEY) or "",
      model = support.read_env_value(plugin_path, config.ENV_OPENAI_MODEL) or ""
    }
  end

  function prompt_enhance.assert_configured(plugin_path)
    local settings = read_settings(plugin_path)

    if settings.api_key == "" then
      support.fail("Prompt enhancement requires OPENAI_API_KEY in .env.")
    end

    if settings.model == "" then
      support.fail("Prompt enhancement requires OPENAI_MODEL in .env.")
    end

    return settings
  end

  function prompt_enhance.enhance(plugin_path, paths, prompt)
    local settings = prompt_enhance.assert_configured(plugin_path)

    if not app.fs.isFile(paths.helper) then
      support.fail("The bundled OpenAI prompt helper is missing.")
    end

    support.write_text_file(
      paths.request,
      build_request_json(settings.api_key, settings.model, prompt)
    )

    return run_helper(paths.helper, paths.request, paths.image, paths.result)
  end

  return prompt_enhance
end
