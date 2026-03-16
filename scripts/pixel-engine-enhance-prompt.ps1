param(
  [Parameter(Mandatory = $true)]
  [string]$RequestPath,

  [Parameter(Mandatory = $true)]
  [string]$ImagePath,

  [Parameter(Mandatory = $true)]
  [string]$ResultPath
)

$ErrorActionPreference = "Stop"

function Write-Info {
  param(
    [string]$Message
  )

  Write-Host "[Pixel Engine] $Message"
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
  Write-Info "Loaded prompt enhancement request."
  return $request
}

function Get-ImageBase64 {
  if (-not (Test-Path -LiteralPath $ImagePath)) {
    Write-Info "No input image found for prompt enhancement."
    return $null
  }

  $imageBytes = [System.IO.File]::ReadAllBytes($ImagePath)
  Write-Info ("Loaded input PNG (" + $imageBytes.Length + " bytes).")
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
    $Body
  )

  return Invoke-RestMethod `
    -Method Post `
    -Uri "https://api.pixelengine.ai/functions/v1/enhance-prompt" `
    -Headers $Headers `
    -Body ($Body | ConvertTo-Json -Depth 10)
}

try {
  $request = Get-RequestData
  $imageBase64 = Get-ImageBase64
  $headers = New-PixelEngineHeaders -ApiKey $request.api_key
  $body = New-RequestBody -Request $request -ImageBase64 $imageBase64
  $response = Invoke-EnhancePrompt -Headers $headers -Body $body
  $prompt = [string]$response.enhanced_prompt

  if (-not $prompt -or $prompt.Trim().Length -eq 0) {
    throw "Pixel Engine did not return an enhanced prompt."
  }

  Write-Info "Received enhanced prompt."
  Write-Result -Ok $true -Prompt $prompt.Trim()
}
catch {
  $message = $_.Exception.Message
  if (-not $message) {
    $message = "Unknown Pixel Engine prompt enhancement error."
  }

  Write-Info ("Error: " + $message)
  Write-Result -Ok $false -ErrorMessage $message
  exit 1
}
