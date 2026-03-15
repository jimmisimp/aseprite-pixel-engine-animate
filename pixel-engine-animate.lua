local COMMAND_ID = "PixelEngineAnimate"
local COMMAND_TITLE = "Pixel Engine Animate"
local LAYER_NAME = "Animation"
local DEFAULT_FRAMES = 8
local DEFAULT_FPS = 8
local DEFAULT_MATTE_COLOR = "#EE00FF"
local DEFAULT_PALETTE_SIZE = "24"
local PALETTE_SIZE_OPTIONS = { "8", "12", "16", "20", "24", "32", "48", "60" }

local function fail(message)
  error(message, 0)
end

local function log(message)
  print("[Pixel Engine] " .. tostring(message))
end

local function quote_arg(value)
  return '"' .. tostring(value) .. '"'
end

local function read_text_file(path)
  local file, open_error = io.open(path, "rb")
  if not file then
    fail(open_error or ("Unable to open file: " .. path))
  end

  local content = file:read("*a")
  file:close()
  return content or ""
end

local function write_text_file(path, content)
  local file, open_error = io.open(path, "wb")
  if not file then
    fail(open_error or ("Unable to write file: " .. path))
  end

  file:write(content)
  file:close()
end

local function trim(value)
  return (tostring(value or ""):match("^%s*(.-)%s*$"))
end

local function parse_env_value(value)
  value = trim(value)
  if value == "" then
    return ""
  end

  local quote = value:sub(1, 1)
  if (quote == '"' or quote == "'") and value:sub(-1) == quote then
    value = value:sub(2, -2)
  end

  return value
end

local function read_env_key(plugin_path)
  local env_path = app.fs.joinPath(plugin_path, ".env")
  if not app.fs.isFile(env_path) then
    return nil
  end

  local content = read_text_file(env_path)
  for line in content:gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if key == "ASEPRITE_KEY" then
      local parsed = parse_env_value(value)
      if parsed ~= "" then
        return parsed
      end
    end
  end

  return nil
end

local function remove_if_exists(path)
  if path and app.fs.isFile(path) then
    os.remove(path)
  end
end

local function make_temp_dir()
  local dir_name = string.format("pixel-engine-animate-%d-%06d", os.time(), math.random(0, 999999))
  local dir_path = app.fs.joinPath(app.fs.tempPath, dir_name)
  local ok = app.fs.makeAllDirectories(dir_path)
  if ok == false then
    fail("Unable to create temp directory: " .. dir_path)
  end
  return dir_path
end

local function cleanup_temp_dir(dir_path, file_paths)
  if file_paths then
    for _, path in ipairs(file_paths) do
      remove_if_exists(path)
    end
  end

  if dir_path and app.fs.isDirectory(dir_path) then
    app.fs.removeDirectory(dir_path)
  end
end

local function color_to_hex(color)
  return string.format("#%02X%02X%02X", color.red, color.green, color.blue)
end

local function collect_palette_colors(sprite)
  local palette = sprite.palettes[1] or app.defaultPalette
  if not palette or #palette == 0 then
    fail("The active sprite does not have a palette.")
  end

  local colors = {}
  local seen = {}

  for i = 0, #palette - 1 do
    local hex = color_to_hex(palette:getColor(i))
    if not seen[hex] then
      table.insert(colors, hex)
      seen[hex] = true
    end
  end

  return colors
end

local function is_valid_palette_size(value)
  local string_value = tostring(value)
  for _, option in ipairs(PALETTE_SIZE_OPTIONS) do
    if option == string_value then
      return true
    end
  end

  return false
end

local function validate_inputs(sprite, prompt, api_key, output_frames, use_index_colors, palette_size)
  if not sprite then
    fail("There is no active sprite.")
  end

  if not app.frame then
    fail("There is no active frame.")
  end

  if not api_key or api_key == "" then
    fail("Enter a Pixel Engine API key.")
  end

  if not prompt or prompt == "" then
    fail("Enter a prompt.")
  end

  if sprite.width > 256 or sprite.height > 256 then
    fail("Pixel Engine only accepts images up to 256x256.")
  end

  local aspect = sprite.width / sprite.height
  if aspect > 2 or aspect < 0.5 then
    fail("Pixel Engine only accepts images up to a 2:1 aspect ratio.")
  end

  if output_frames < 2 or output_frames > 16 or output_frames % 2 ~= 0 then
    fail("Frames must be an even number from 2 to 16.")
  end

  if not use_index_colors and not is_valid_palette_size(palette_size) then
    fail("Palette size must be one of 8, 12, 16, 20, 24, 32, 48, or 60.")
  end
end

local function render_active_frame(sprite, frame_number, output_path)
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  image:drawSprite(sprite, frame_number)
  image:saveAs(output_path)
end

local function build_request_json(api_key, prompt, negative_prompt, output_frames, use_index_colors, palette_value)
  local payload = {
    api_key = api_key,
    prompt = prompt,
    negative_prompt = negative_prompt,
    output_frames = output_frames,
    matte_color = DEFAULT_MATTE_COLOR
  }

  if use_index_colors then
    payload.palette = palette_value
  else
    payload.colors = tonumber(palette_value)
  end

  return json.encode(payload)
end

local function run_helper(helper_path, request_path, image_path, result_path, output_path)
  local command = table.concat({
    "powershell.exe",
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", quote_arg(helper_path),
    "-RequestPath", quote_arg(request_path),
    "-ImagePath", quote_arg(image_path),
    "-ResultPath", quote_arg(result_path),
    "-OutputImagePath", quote_arg(output_path)
  }, " ")

  local ok, how, code = os.execute(command)

  if not app.fs.isFile(result_path) then
    fail("The Pixel Engine helper did not return a result.")
  end

  local result = json.decode(read_text_file(result_path))
  if not result then
    fail("The Pixel Engine helper returned invalid JSON.")
  end

  if not result.ok then
    local message = result.error or "Pixel Engine request failed."
    fail(message)
  end

  if result.content_type ~= "image/png" then
    fail("Expected a spritesheet PNG from Pixel Engine.")
  end

  if not app.fs.isFile(output_path) then
    fail("Pixel Engine did not download the spritesheet.")
  end

  return result
end

local function ensure_sprite_has_frames(sprite, frame_number)
  while #sprite.frames < frame_number do
    sprite:newEmptyFrame(#sprite.frames + 1)
  end
end

local function make_unique_layer_name(sprite, base_name)
  local used = {}

  for _, layer in ipairs(sprite.layers) do
    used[layer.name] = true
  end

  if not used[base_name] then
    return base_name
  end

  local index = 2
  while used[base_name .. " " .. index] do
    index = index + 1
  end

  return base_name .. " " .. index
end

local function convert_frame_for_sprite(sprite, source_image)
  local target_spec = ImageSpec(sprite.spec)
  target_spec.width = source_image.width
  target_spec.height = source_image.height

  if source_image.colorMode == target_spec.colorMode then
    return source_image
  end

  local converted = Image(target_spec)
  converted:clear()
  converted:drawImage(source_image)
  return converted
end

local function import_spritesheet(sprite, start_frame_number, spritesheet_path, metadata)
  if not metadata then
    fail("Pixel Engine did not return spritesheet metadata.")
  end

  local frame_count = tonumber(metadata.frame_count)
  local frame_width = tonumber(metadata.frame_w)
  local frame_height = tonumber(metadata.frame_h)
  local fps = tonumber(metadata.fps) or DEFAULT_FPS

  if not frame_count or frame_count < 1 then
    fail("Invalid frame count returned by Pixel Engine.")
  end

  local sheet = Image{ fromFile = spritesheet_path }
  if not sheet then
    fail("Unable to load the returned spritesheet.")
  end

  if not frame_width or frame_width < 1 then
    frame_width = math.floor(sheet.width / frame_count)
  end

  if not frame_height or frame_height < 1 then
    frame_height = sheet.height
  end

  if sheet.width ~= frame_width * frame_count or sheet.height ~= frame_height then
    fail("Returned spritesheet dimensions do not match the reported metadata.")
  end

  local imported_layer_name = nil
  local target_last_frame = start_frame_number + frame_count - 1

  app.transaction("Pixel Engine Animate", function()
    ensure_sprite_has_frames(sprite, target_last_frame)

    local layer = sprite:newLayer()
    layer.name = make_unique_layer_name(sprite, LAYER_NAME)
    imported_layer_name = layer.name

    for i = 1, frame_count do
      local rect = Rectangle((i - 1) * frame_width, 0, frame_width, frame_height)
      local cel_image = Image(sheet, rect)
      if not cel_image then
        fail("Unable to slice frame " .. i .. " from the spritesheet.")
      end

      cel_image = convert_frame_for_sprite(sprite, cel_image)

      local frame_number = start_frame_number + i - 1
      sprite:newCel(layer, frame_number, cel_image, Point(0, 0))
      sprite.frames[frame_number].duration = 1 / fps
    end
  end)

  app.refresh()
  return imported_layer_name, frame_count
end

local function run_generation(plugin)
  local sprite = app.sprite
  local current_frame = app.frame
  local preferences = plugin.preferences
  local env_api_key = read_env_key(plugin.path)
  local initial_api_key = env_api_key or preferences.api_key or ""
  local initial_use_index_colors = preferences.use_index_colors
  if initial_use_index_colors == nil then
    initial_use_index_colors = true
  end
  local initial_palette_size = tostring(preferences.palette_size or DEFAULT_PALETTE_SIZE)
  if not is_valid_palette_size(initial_palette_size) then
    initial_palette_size = DEFAULT_PALETTE_SIZE
  end

  local dialog = Dialog(COMMAND_TITLE)
  dialog:entry{
    id = "api_key",
    label = "API Key",
    text = initial_api_key,
    focus = (initial_api_key == "")
  }
  dialog:newrow()
  dialog:entry{
    id = "prompt",
    label = "Prompt",
    text = preferences.prompt or "",
    focus = (initial_api_key ~= "")
  }
  dialog:newrow()
  dialog:entry{
    id = "negative_prompt",
    label = "Negative",
    text = preferences.negative_prompt or ""
  }
  dialog:newrow()
  dialog:number{
    id = "output_frames",
    label = "Frames",
    text = tostring(preferences.output_frames or DEFAULT_FRAMES),
    decimals = 0
  }
  dialog:newrow()
  dialog:check{
    id = "use_index_colors",
    label = "Colors",
    text = "Use index colors",
    selected = initial_use_index_colors,
    onclick = function()
      local data = dialog.data
      dialog:modify{
        id = "palette_size",
        enabled = not data.use_index_colors
      }
    end
  }
  dialog:newrow()
  dialog:combobox{
    id = "palette_size",
    label = "Palette Size",
    option = initial_palette_size,
    options = PALETTE_SIZE_OPTIONS,
    enabled = not initial_use_index_colors
  }
  dialog:newrow()
  dialog:button{ id = "ok", text = "Generate", focus = true }
  dialog:button{ id = "cancel", text = "Cancel" }

  local data = dialog:show().data
  if not data.ok then
    return
  end

  local output_frames = math.floor(tonumber(data.output_frames) or 0)
  local prompt = trim(data.prompt)
  local negative_prompt = trim(data.negative_prompt)
  local api_key = trim(data.api_key)
  local use_index_colors = data.use_index_colors and true or false
  local palette_size = tostring(data.palette_size or initial_palette_size)

  if api_key == "" and env_api_key then
    api_key = env_api_key
  end

  validate_inputs(sprite, prompt, api_key, output_frames, use_index_colors, palette_size)

  preferences.api_key = api_key
  preferences.prompt = prompt
  preferences.negative_prompt = negative_prompt
  preferences.output_frames = output_frames
  preferences.use_index_colors = use_index_colors
  preferences.palette_size = palette_size

  local temp_dir = make_temp_dir()
  local request_path = app.fs.joinPath(temp_dir, "request.json")
  local input_path = app.fs.joinPath(temp_dir, "input.png")
  local result_path = app.fs.joinPath(temp_dir, "result.json")
  local output_path = app.fs.joinPath(temp_dir, "output.png")
  local helper_path = app.fs.joinPath(plugin.path, "pixel-engine-http.ps1")

  local ok, result_or_error = pcall(function()
    if not app.fs.isFile(helper_path) then
      fail("The bundled PowerShell helper is missing.")
    end

    app.tip("Rendering current frame...", 2)
    render_active_frame(sprite, current_frame.frameNumber, input_path)

    local palette_value = palette_size
    if use_index_colors then
      palette_value = collect_palette_colors(sprite)
    end

    write_text_file(
      request_path,
      build_request_json(
        api_key,
        prompt,
        negative_prompt,
        output_frames,
        use_index_colors,
        palette_value
      )
    )
    app.tip("Waiting for Pixel Engine...", 3)
    local result = run_helper(helper_path, request_path, input_path, result_path, output_path)

    local layer_name, imported_frames = import_spritesheet(
      sprite,
      current_frame.frameNumber,
      output_path,
      result.metadata
    )

    return {
      layer_name = layer_name,
      imported_frames = imported_frames,
      api_job_id = result.api_job_id
    }
  end)

  cleanup_temp_dir(temp_dir, { request_path, input_path, result_path, output_path })

  if not ok then
    log("Generation failed: " .. tostring(result_or_error))
    app.alert{
      title = COMMAND_TITLE,
      text = result_or_error
    }
    return
  end

  app.alert{
    title = COMMAND_TITLE,
    text = {
      "Imported " .. result_or_error.imported_frames .. " frames into layer '" .. result_or_error.layer_name .. "'.",
      "Job ID: " .. tostring(result_or_error.api_job_id)
    }
  }
end

function init(plugin)
  math.randomseed(os.time())

  if plugin.preferences.output_frames == nil then
    plugin.preferences.output_frames = DEFAULT_FRAMES
  end

  plugin:newCommand{
    id = COMMAND_ID,
    title = COMMAND_TITLE,
    group = "file_scripts",
    onclick = function()
      run_generation(plugin)
    end,
    onenabled = function()
      return app.sprite ~= nil and app.frame ~= nil
    end
  }
end

function exit(plugin)
end
