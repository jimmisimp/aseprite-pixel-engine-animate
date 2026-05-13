# Pixel Engine Animate

An Aseprite extension that sends the active frame to the [Pixel Engine](https://pixelengine.ai/) Animate API and imports the returned spritesheet as a new animation layer.

![UI Example](assets/ui-example.gif)


## Requirements

- [Aseprite](https://www.aseprite.org/) with extensions enabled
- Windows with `curl.exe` available. Current Windows builds include `curl.exe` in `C:\Windows\System32`.
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

Optional timeout settings can be added to `.env`:

```env
PIXEL_ENGINE_REQUEST_TIMEOUT_SECONDS=30
PIXEL_ENGINE_JOB_TIMEOUT_SECONDS=300
PIXEL_ENGINE_POLL_INTERVAL_SECONDS=8
```

`PIXEL_ENGINE_REQUEST_TIMEOUT_SECONDS` applies to API requests and downloads. `PIXEL_ENGINE_JOB_TIMEOUT_SECONDS` is the maximum time to wait for a Pixel Engine generation job. `PIXEL_ENGINE_POLL_INTERVAL_SECONDS` controls how often the job status is checked; it defaults to 8 seconds and backs off during longer jobs to reduce console-window flashes.

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
> Aseprite may ask for permission to run external commands on the first run. The active request path uses Windows `curl.exe`.

Both commands export frames to temporary PNGs, open a modeless progress dialog, wait for Pixel Engine to finish, download the spritesheet, and import each frame into a new layer named `Animation`.

While a job is running, each status check launches Windows `curl.exe`, so a console window may briefly appear. The progress dialog shows the current phase, job ID/status, and includes a cancel button for local polling/import.

## Troubleshooting

If Windows shows `cmd.exe` or PowerShell startup error `0xc0000142`, the shell or PowerShell failed before the old helper script could run. The active Animate, Keyframes, and prompt-enhancement paths now avoid PowerShell and call Windows `curl.exe` directly from Lua.

Aseprite's documented `app.os` API provides OS metadata, not a direct HTTPS client. Its documented no-shell IPC option is `WebSocket`, which would require a separate local process.

On request failures, API-key request files are deleted from the temp directory. Redacted diagnostics such as `result.json` and `result.json.body-sent.json` may be kept so you can inspect the API status and request shape without exposing keys.

## Notes

- Pixel Engine currently accepts images up to `256x256`.
- The aspect ratio must stay between `1:2` and `2:1`.
- Animate frame count must be an even number between `2` and `16`.
- Keyframes total frames must be between `3` and `20`.
- `Use index colors` sends the sprite palette directly and validates that it contains at most 256 unique colors.
- Matte color defaults to `#EE00FF`, but you can change it from the color picker in the dialog.
- Temporary files are cleaned up automatically after a successful run. On failure, secret-bearing request files are removed and redacted diagnostics are preserved for debugging.

## Repo layout

- `pixel-engine-animate.lua`: extension entrypoint
- `lib/pixel_engine/`: Lua modules for config, sprite handling, and command flow
- `lib/openai/`: Lua modules for prompt enhancement config and helper
- `lib/utils/`: Lua modules for shared helpers
- `scripts/`: legacy PowerShell helpers retained for reference; the active plugin path uses Lua plus `curl.exe`
