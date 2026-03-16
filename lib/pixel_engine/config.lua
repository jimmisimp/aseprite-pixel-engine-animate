return {
  COMMAND_ID = "PixelEngineAnimate",
  COMMAND_TITLE = "Pixel Engine Animate",
  LAYER_NAME = "Animation",
  LOG_PREFIX = "Pixel Engine",
  TEMP_DIR_PREFIX = "pixel-engine-animate",
  ENV_FILE_NAME = ".env",
  ENV_API_KEY = "ASEPRITE_KEY",
  ENV_OPENAI_API_KEY = "OPENAI_API_KEY",
  ENV_OPENAI_MODEL = "OPENAI_MODEL",
  HELPER_SCRIPT_NAME = "scripts/pixel-engine-http.ps1",
  OPENAI_HELPER_SCRIPT_NAME = "scripts/openai-prompt-enhance.ps1",
  DEFAULT_FRAMES = 8,
  DEFAULT_FPS = 8,
  DEFAULT_MATTE_COLOR = "#EE00FF",
  DEFAULT_PALETTE_SIZE = "24",
  PALETTE_SIZE_OPTIONS = { "8", "12", "16", "20", "24", "32", "48", "60" },
  TEMP_FILES = {
    request = "request.json",
    input = "input.png",
    openai_request = "openai-request.json",
    openai_result = "openai-result.json",
    result = "result.json",
    output = "output.png"
  }
}
