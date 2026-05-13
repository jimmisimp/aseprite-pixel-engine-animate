param(
  [Parameter(Mandatory = $true)]
  [string]$RequestPath,

  [Parameter(Mandatory = $true)]
  [string]$ImagePath,

  [Parameter(Mandatory = $true)]
  [string]$ResultPath,

  [string]$LogPath = ""
)

$ErrorActionPreference = "Stop"
$script:PeLogPath = $LogPath

function Write-HelperLog {
  param(
    [string]$Message
  )

  if (-not $script:PeLogPath) {
    return
  }

  try {
    $parent = Split-Path -Parent -Path $script:PeLogPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $line = (Get-Date).ToString("o") + " " + $Message
    Add-Content -LiteralPath $script:PeLogPath -Encoding UTF8 -Value $line
  }
  catch {
  }
}

function Start-HelperLog {
  if (-not $script:PeLogPath) {
    return
  }

  try {
    $parent = Split-Path -Parent -Path $script:PeLogPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Set-Content -LiteralPath $script:PeLogPath -Encoding UTF8 -Value ((Get-Date).ToString("o") + " Pixel Engine prompt helper started.")
    Write-HelperLog ("PowerShell " + $PSVersionTable.PSVersion.ToString())
    Write-HelperLog ("RequestPath=" + $RequestPath)
    Write-HelperLog ("ImagePath=" + $ImagePath)
    Write-HelperLog ("ResultPath=" + $ResultPath)
  }
  catch {
  }
}

Start-HelperLog

function Write-Info {
  param(
    [string]$Message,
    [ValidateSet("Default", "Dim", "Ok", "Warn", "Err")]
    [string]$Tone = "Default"
  )

  Write-HelperLog $Message
  $label = "Pixel Engine"
  switch ($Tone) {
    "Dim" {
      Write-Host "  " -NoNewline
      Write-Host $label -ForegroundColor DarkGray -NoNewline
      Write-Host "  $Message" -ForegroundColor DarkGray
    }
    "Ok" {
      Write-Host "  " -NoNewline
      Write-Host $label -ForegroundColor Cyan -NoNewline
      Write-Host "  " -NoNewline
      Write-Host "+ " -ForegroundColor Green -NoNewline
      Write-Host $Message
    }
    "Warn" {
      Write-Host "  " -NoNewline
      Write-Host $label -ForegroundColor Cyan -NoNewline
      Write-Host "  " -NoNewline
      Write-Host "! " -ForegroundColor Yellow -NoNewline
      Write-Host $Message
    }
    "Err" {
      Write-Host "  " -NoNewline
      Write-Host $label -ForegroundColor Cyan -NoNewline
      Write-Host "  " -NoNewline
      Write-Host "x " -ForegroundColor Red -NoNewline
      Write-Host $Message -ForegroundColor Red
    }
    default {
      Write-Host "  " -NoNewline
      Write-Host $label -ForegroundColor Cyan -NoNewline
      Write-Host "  $Message"
    }
  }
}

function Write-Result {
  param(
    [bool]$Ok,
    [string]$Prompt = $null,
    [string]$ErrorMessage = $null
  )

  $result = [ordered]@{
    ok = $Ok
    prompt = $Prompt
    error = $ErrorMessage
  }

  $json = $result | ConvertTo-Json -Depth 10
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($ResultPath, $json, $utf8NoBom)
}

function Get-RequestData {
  $request = Get-Content -Raw -Path $RequestPath | ConvertFrom-Json
  Write-Info "Loaded prompt enhancement request." -Tone Ok
  return $request
}

function Get-PositiveIntOrDefault {
  param(
    $Value,
    [int]$Default,
    [int]$Min,
    [int]$Max
  )

  $parsed = $Default
  if ($null -ne $Value) {
    try {
      $parsed = [int]$Value
    }
    catch {
      $parsed = $Default
    }
  }

  if ($parsed -lt $Min) {
    return $Min
  }

  if ($parsed -gt $Max) {
    return $Max
  }

  return $parsed
}

function Get-ImageBase64 {
  if (-not (Test-Path -LiteralPath $ImagePath)) {
    Write-Info "No input image found for prompt enhancement." -Tone Warn
    return $null
  }

  $imageBytes = [System.IO.File]::ReadAllBytes($ImagePath)
  Write-Info ("Loaded input PNG (" + $imageBytes.Length + " bytes).") -Tone Ok
  return [System.Convert]::ToBase64String($imageBytes)
}

function New-PixelEngineHeaders {
  param(
    [string]$ApiKey
  )

  return @{
    Authorization = "Bearer $ApiKey"
    "Content-Type" = "application/json"
  }
}

function New-RequestBody {
  param(
    $Request,
    [string]$ImageBase64
  )

  $body = [ordered]@{
    prompt = $Request.prompt
  }

  if ($ImageBase64) {
    $body.image = $ImageBase64
  }

  if ($Request.model -and $Request.model.Trim().Length -gt 0) {
    $body.model = $Request.model
  }

  return $body
}

function Invoke-EnhancePrompt {
  param(
    $Headers,
    $Body,
    [int]$RequestTimeoutSeconds
  )

  return Invoke-RestMethod `
    -Method Post `
    -Uri "https://api.pixelengine.ai/functions/v1/enhance-prompt" `
    -Headers $Headers `
    -Body ($Body | ConvertTo-Json -Depth 10) `
    -TimeoutSec $RequestTimeoutSeconds
}

try {
  $request = Get-RequestData
  $requestTimeoutSeconds = Get-PositiveIntOrDefault `
    -Value $request.request_timeout_seconds `
    -Default 30 `
    -Min 1 `
    -Max 3600
  $imageBase64 = Get-ImageBase64
  $headers = New-PixelEngineHeaders -ApiKey $request.api_key
  $body = New-RequestBody -Request $request -ImageBase64 $imageBase64
  $response = Invoke-EnhancePrompt `
    -Headers $headers `
    -Body $body `
    -RequestTimeoutSeconds $requestTimeoutSeconds
  $prompt = [string]$response.enhanced_prompt

  if (-not $prompt -or $prompt.Trim().Length -eq 0) {
    throw "Pixel Engine did not return an enhanced prompt."
  }

  Write-Info "Received enhanced prompt." -Tone Ok
  Write-Result -Ok $true -Prompt $prompt.Trim()
}
catch {
  $message = $_.Exception.Message
  if (-not $message) {
    $message = "Unknown Pixel Engine prompt enhancement error."
  }

  Write-Info $message -Tone Err
  Write-Result -Ok $false -ErrorMessage $message
  exit 1
}
