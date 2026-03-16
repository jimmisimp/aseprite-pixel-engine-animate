return function(config)
  local support = {}

  function support.fail(message)
    error(message, 0)
  end

  function support.log(message)
    print("[" .. config.LOG_PREFIX .. "] " .. tostring(message))
  end

  function support.quote_arg(value)
    return '"' .. tostring(value) .. '"'
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

  function support.read_env_key(plugin_path)
    return support.read_env_value(plugin_path, config.ENV_API_KEY)
  end

  function support.remove_if_exists(path)
    if path and app.fs.isFile(path) then
      os.remove(path)
    end
  end

  function support.make_temp_dir()
    local dir_name = string.format("%s-%d-%06d", config.TEMP_DIR_PREFIX, os.time(), math.random(0, 999999))
    local dir_path = app.fs.joinPath(app.fs.tempPath, dir_name)
    local ok = app.fs.makeAllDirectories(dir_path)
    if ok == false then
      support.fail("Unable to create temp directory: " .. dir_path)
    end
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
