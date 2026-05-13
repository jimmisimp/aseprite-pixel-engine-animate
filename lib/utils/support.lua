return function(config)
  local support = {}

  function support.fail(message)
    error(message, 0)
  end

  function support.log(message)
    print("[" .. config.LOG_PREFIX .. "] " .. tostring(message))
  end

  function support.quote_arg(value)
    local text = tostring(value or "")
    text = text:gsub('"', '\\"')
    return '"' .. text .. '"'
  end

  local function normalize_execute_result(ok, reason, code)
    if ok == true then
      return true, 0
    end

    if type(ok) == "number" then
      return ok == 0, ok
    end

    if type(code) == "number" then
      return false, code
    end

    if type(reason) == "number" then
      return false, reason
    end

    return false, nil
  end

  function support.run_shell_command(command_line)
    local success, exit_code = normalize_execute_result(os.execute(command_line))
    return success, exit_code
  end

  local function windows_system_root()
    return os.getenv("SystemRoot") or os.getenv("WINDIR") or "C:\\Windows"
  end

  function support.resolve_curl_path()
    if app.os and app.os.windows then
      local candidate = windows_system_root() .. "\\System32\\curl.exe"
      if app.fs.isFile(candidate) then
        return candidate, true
      end
    end

    return "curl.exe", false
  end

  function support.sleep_seconds(seconds)
    local duration = math.max(1, math.floor(tonumber(seconds) or 1))
    local start_time = os.time()
    while os.time() - start_time < duration do
    end
  end

  function support.read_text_file_if_exists(path)
    if not path or not app.fs.isFile(path) then
      return nil
    end

    local file = io.open(path, "rb")
    if not file then
      return nil
    end

    local content = file:read("*a")
    file:close()
    return content or ""
  end

  function support.read_text_file(path)
    local file, open_error = io.open(path, "rb")
    if not file then
      support.fail(open_error or ("Unable to open file: " .. path))
    end

    local content = file:read("*a")
    file:close()
    return content or ""
  end

  local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

  function support.base64_encode(data)
    local bytes = { string.byte(data or "", 1, #(data or "")) }
    local encoded = {}

    for i = 1, #bytes, 3 do
      local b1 = bytes[i] or 0
      local b2 = bytes[i + 1] or 0
      local b3 = bytes[i + 2] or 0
      local n = b1 * 65536 + b2 * 256 + b3

      local c1 = math.floor(n / 262144) % 64
      local c2 = math.floor(n / 4096) % 64
      local c3 = math.floor(n / 64) % 64
      local c4 = n % 64

      table.insert(encoded, base64_chars:sub(c1 + 1, c1 + 1))
      table.insert(encoded, base64_chars:sub(c2 + 1, c2 + 1))

      if i + 1 <= #bytes then
        table.insert(encoded, base64_chars:sub(c3 + 1, c3 + 1))
      else
        table.insert(encoded, "=")
      end

      if i + 2 <= #bytes then
        table.insert(encoded, base64_chars:sub(c4 + 1, c4 + 1))
      else
        table.insert(encoded, "=")
      end
    end

    return table.concat(encoded)
  end

  function support.write_text_file(path, content)
    local file, open_error = io.open(path, "wb")
    if not file then
      support.fail(open_error or ("Unable to write file: " .. path))
    end

    file:write(content)
    file:close()
  end

  function support.trim(value)
    return (tostring(value or ""):match("^%s*(.-)%s*$"))
  end

  function support.normalize_json_text(value)
    local text = tostring(value or "")
    text = text:gsub("\r\n", "\n")
    text = text:gsub("\r", "\n")
    text = text:gsub("[%z\1-\8\11\12\14-\31]", "")
    return text
  end

  function support.wrap_text(value, max_length)
    local text = support.normalize_json_text(value)
    local limit = math.max(1, tonumber(max_length) or 1)
    local lines = {}

    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
      if paragraph == "" then
        if #lines == 0 or lines[#lines] ~= "" then
          table.insert(lines, "")
        end
      else
        local current = ""

        for word in paragraph:gmatch("%S+") do
          if current == "" then
            current = word
          elseif #current + 1 + #word <= limit then
            current = current .. " " .. word
          else
            table.insert(lines, current)
            current = word
          end

          while #current > limit do
            table.insert(lines, current:sub(1, limit))
            current = current:sub(limit + 1)
          end
        end

        if current ~= "" then
          table.insert(lines, current)
        end
      end
    end

    if #lines > 0 and lines[#lines] == "" then
      table.remove(lines, #lines)
    end

    if #lines == 0 then
      return { "" }
    end

    return lines
  end

  function support.parse_env_value(value)
    value = support.trim(value)
    if value == "" then
      return ""
    end

    local quote = value:sub(1, 1)
    if (quote == '"' or quote == "'") and value:sub(-1) == quote then
      value = value:sub(2, -2)
    end

    return value
  end

  function support.parse_env_bool(value)
    local normalized = support.parse_env_value(value):lower()
    return normalized == "1" or normalized == "true" or normalized == "yes" or normalized == "on"
  end

  function support.color_to_hex(color)
    return string.format("#%02X%02X%02X", color.red, color.green, color.blue)
  end

  function support.hex_to_color(value, fallback_hex)
    local hex = support.trim(value)
    if hex:sub(1, 1) == "#" then
      hex = hex:sub(2)
    end

    local red, green, blue = hex:match("^(%x%x)(%x%x)(%x%x)$")
    if red and green and blue then
      return Color{
        r = tonumber(red, 16),
        g = tonumber(green, 16),
        b = tonumber(blue, 16)
      }
    end

    if fallback_hex and fallback_hex ~= value then
      return support.hex_to_color(fallback_hex)
    end

    return Color{ r = 238, g = 0, b = 255 }
  end

  function support.read_env_value(plugin_path, env_key)
    local env_path = app.fs.joinPath(plugin_path, config.ENV_FILE_NAME)
    if not app.fs.isFile(env_path) then
      return nil
    end

    local content = support.read_text_file(env_path)
    for line in content:gmatch("[^\r\n]+") do
      local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if key == env_key then
        local parsed = support.parse_env_value(value)
        if parsed ~= "" then
          return parsed
        end
      end
    end

    return nil
  end

  function support.read_env_bool(plugin_path, env_key)
    local env_path = app.fs.joinPath(plugin_path, config.ENV_FILE_NAME)
    if not app.fs.isFile(env_path) then
      return false
    end

    local content = support.read_text_file(env_path)
    for line in content:gmatch("[^\r\n]+") do
      local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if key == env_key then
        return support.parse_env_bool(value)
      end
    end

    return false
  end

  function support.read_env_key(plugin_path)
    return support.read_env_value(plugin_path, config.ENV_API_KEY)
  end

  function support.read_env_int(plugin_path, env_key, default_value, min_value, max_value)
    local raw = support.read_env_value(plugin_path, env_key)
    local value = math.floor(tonumber(raw) or tonumber(default_value) or 0)
    if min_value and value < min_value then
      value = min_value
    end
    if max_value and value > max_value then
      value = max_value
    end
    return value
  end

  function support.read_timeout_settings(plugin_path)
    return {
      request_timeout_seconds = support.read_env_int(
        plugin_path,
        config.ENV_REQUEST_TIMEOUT_SECONDS,
        config.DEFAULT_REQUEST_TIMEOUT_SECONDS,
        1,
        3600
      ),
      job_timeout_seconds = support.read_env_int(
        plugin_path,
        config.ENV_JOB_TIMEOUT_SECONDS,
        config.DEFAULT_JOB_TIMEOUT_SECONDS,
        1,
        86400
      ),
      poll_interval_seconds = support.read_env_int(
        plugin_path,
        config.ENV_POLL_INTERVAL_SECONDS,
        config.DEFAULT_POLL_INTERVAL_SECONDS,
        1,
        60
      )
    }
  end

  function support.add_timeout_settings(payload, timeout_settings)
    local settings = timeout_settings or {}
    payload.request_timeout_seconds = settings.request_timeout_seconds or config.DEFAULT_REQUEST_TIMEOUT_SECONDS
    payload.job_timeout_seconds = settings.job_timeout_seconds or config.DEFAULT_JOB_TIMEOUT_SECONDS
    payload.poll_interval_seconds = settings.poll_interval_seconds or config.DEFAULT_POLL_INTERVAL_SECONDS
  end

  function support.remove_if_exists(path)
    if path and app.fs.isFile(path) then
      os.remove(path)
    end
  end

  function support.remove_sensitive_failure_files(paths)
    if not paths then
      return
    end

    support.remove_if_exists(paths.request)
    support.remove_if_exists(paths.enhance_request)
  end

  function support.make_temp_dir()
    local dir_name = string.format("%s-%d-%06d", config.TEMP_DIR_PREFIX, os.time(), math.random(0, 999999))
    local dir_path = app.fs.joinPath(app.fs.tempPath, dir_name)
    local ok = app.fs.makeAllDirectories(dir_path)
    if ok == false then
      support.fail("Unable to create temp directory: " .. dir_path)
    end

    local probe_path = app.fs.joinPath(dir_path, ".write-test")
    local probe, open_error = io.open(probe_path, "wb")
    if not probe then
      support.fail(open_error or ("Unable to write to temp directory: " .. dir_path))
    end
    probe:write("ok")
    probe:close()
    os.remove(probe_path)

    return dir_path
  end

  function support.cleanup_temp_dir(dir_path, file_paths)
    if file_paths then
      for _, path in ipairs(file_paths) do
        support.remove_if_exists(path)
      end
    end

    if dir_path and app.fs.isDirectory(dir_path) then
      app.fs.removeDirectory(dir_path)
    end
  end

  return support
end
