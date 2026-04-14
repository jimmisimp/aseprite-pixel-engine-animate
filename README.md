# Pixel Engine Animate

An Aseprite extension that sends the active frame to the [Pixel Engine](https://pixelengine.ai/) Animate API and imports the returned spritesheet as a new animation layer.

![UI Example](assets/ui-example.gif)


## Requirements

- [Aseprite](https://www.aseprite.org/) with extensions enabled
- Windows with `powershell.exe` available
- A [Pixel Engine API key](https://pixelengine.ai/account?tab=api)

## Install

1. Copy this repo into your Aseprite extensions directory, or package it as an Aseprite extension.
2. Restart Aseprite if it is already open.
3. Create a `.env` file next to `package.json` and `pixel-engine-animate.lua`.
4. Add your API key:

```env
ASEPRITE_KEY=pe_sk_your_key_here
```

You can also paste the API key into the dialog. The extension remembers the last values you used in Aseprite's local preferences.


## Prompt Enhancement

Prompt enhancement uses Pixel Engine's `/enhance-prompt` endpoint by default.
You can also use a custom prompt enhancement flow by adding:

```env
USE_CUSTOM_ENHANCE=true
```

If you enabled, you will also need to add your OpenAI API key:

```env
OPENAI_API_KEY=sk-your-key-here
OPENAI_MODEL=gpt-5-mini-2025-08-07
```

> **Note** 
> You can modify the custom rewrite prompt in `lib/openai/prompt_enhance.lua`.

## Use

### Animate (single frame)

1. Open a sprite and select the frame you want to animate.
2. Run `File > Pixel Engine Animate`.
3. Enter a prompt, optional negative prompt, matte color, and the number of output frames.
4. Optional: enable `Enhance prompt` to send your prompt plus the active frame to Pixel Engine's prompt enhancement endpoint before the animate request.
5. Choose either:
   - `Use index colors` to send the sprite palette directly
   - `Palette Size` to let Pixel Engine generate a palette
6. Click `Generate`.

### Keyframes (multi-frame)

1. Open a sprite with one or more cels that represent keyframe poses.
2. Run `File > Pixel Engine Keyframes`.
3. Enter a prompt, optional negative prompt, matte color, and the total number of output frames (3–20).
4. The first 1–8 cels are sent as keyframes, evenly spaced across the output sequence. The API interpolates between them.
5. Palette options work the same as the Animate command.
6. Click `Generate`.

> **Note** 
> You will be asked to allow the extension to run PowerShell scripts on the first run.

Both commands export frames to temporary PNGs, wait for Pixel Engine to finish, download the spritesheet, and import each frame into a new layer named `Animation`.

## Notes

- Pixel Engine currently accepts images up to `256x256`.
- The aspect ratio must stay between `1:2` and `2:1`.
- Animate frame count must be an even number between `2` and `16`.
- Keyframes total frames must be between `3` and `20`.
- Matte color defaults to `#EE00FF`, but you can change it from the color picker in the dialog.
- Temporary files are cleaned up automatically after a successful run. On failure, the temp directory is preserved for debugging.

## Repo layout

- `pixel-engine-animate.lua`: extension entrypoint
- `lib/pixel_engine/`: Lua modules for config, sprite handling, and command flow
- `lib/openai/`: Lua modules for prompt enhancement config and helper
- `lib/utils/`: Lua modules for shared helpers
- `scripts/pixel-engine-http.ps1`: PowerShell helper that calls the Pixel Engine API
- `scripts/pixel-engine-enhance-prompt.ps1`: PowerShell helper that calls Pixel Engine's `/enhance-prompt` endpoint
- `scripts/openai-prompt-enhance.ps1`: PowerShell helper for the optional OpenAI prompt enhancement flow
