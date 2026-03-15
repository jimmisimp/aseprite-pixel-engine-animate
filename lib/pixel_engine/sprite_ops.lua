return function(config, support)
  local sprite_ops = {}

  local function color_to_hex(color)
    return string.format("#%02X%02X%02X", color.red, color.green, color.blue)
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

  function sprite_ops.collect_palette_colors(sprite)
    local palette = sprite.palettes[1] or app.defaultPalette
    if not palette or #palette == 0 then
      support.fail("The active sprite does not have a palette.")
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

  function sprite_ops.render_active_frame(sprite, frame_number, output_path)
    local image = Image(sprite.width, sprite.height, ColorMode.RGB)
    image:drawSprite(sprite, frame_number)
    image:saveAs(output_path)
  end

  function sprite_ops.import_spritesheet(sprite, start_frame_number, spritesheet_path, metadata)
    if not metadata then
      support.fail("Pixel Engine did not return spritesheet metadata.")
    end

    local frame_count = tonumber(metadata.frame_count)
    local frame_width = tonumber(metadata.frame_w)
    local frame_height = tonumber(metadata.frame_h)
    local fps = tonumber(metadata.fps) or config.DEFAULT_FPS

    if not frame_count or frame_count < 1 then
      support.fail("Invalid frame count returned by Pixel Engine.")
    end

    local sheet = Image{ fromFile = spritesheet_path }
    if not sheet then
      support.fail("Unable to load the returned spritesheet.")
    end

    if not frame_width or frame_width < 1 then
      frame_width = math.floor(sheet.width / frame_count)
    end

    if not frame_height or frame_height < 1 then
      frame_height = sheet.height
    end

    if sheet.width ~= frame_width * frame_count or sheet.height ~= frame_height then
      support.fail("Returned spritesheet dimensions do not match the reported metadata.")
    end

    local imported_layer_name = nil
    local target_last_frame = start_frame_number + frame_count - 1

    app.transaction(config.COMMAND_TITLE, function()
      ensure_sprite_has_frames(sprite, target_last_frame)

      local layer = sprite:newLayer()
      layer.name = make_unique_layer_name(sprite, config.LAYER_NAME)
      imported_layer_name = layer.name

      for i = 1, frame_count do
        local rect = Rectangle((i - 1) * frame_width, 0, frame_width, frame_height)
        local cel_image = Image(sheet, rect)
        if not cel_image then
          support.fail("Unable to slice frame " .. i .. " from the spritesheet.")
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

  return sprite_ops
end
