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

  Write-Host "[Prompt Enhancement] $Message"
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
  return Get-Content -Raw -Path $RequestPath | ConvertFrom-Json
}

function Get-ImageDataUrl {
  if (-not (Test-Path -LiteralPath $ImagePath)) {
    throw "Input image not found: $ImagePath"
  }

  $imageBytes = [System.IO.File]::ReadAllBytes($ImagePath)
  $imageBase64 = [System.Convert]::ToBase64String($imageBytes)
  Write-Info ("Loaded input PNG (" + $imageBytes.Length + " bytes).")
  return "data:image/png;base64,$imageBase64"
}

function New-Headers {
  param(
    [string]$ApiKey
  )

  return @{
    Authorization = "Bearer $ApiKey"
    "Content-Type" = "application/json"
  }
}

function Get-ReasoningEffort {
  param(
    [string]$Model
  )

  if ($Model -like "gpt-5.1*" -or $Model -like "gpt-5.2*" -or $Model -like "gpt-5.4*") {
    return "none"
  }

  return "minimal"
}

function New-Body {
  param(
    $Request,
    [string]$ImageDataUrl
  )

  return [ordered]@{
    model = $Request.model
    instructions = $Request.instructions
    max_output_tokens = 400
    reasoning = [ordered]@{
      effort = Get-ReasoningEffort -Model ([string]$Request.model)
    }
    text = [ordered]@{
      verbosity = "low"
    }
    input = @(
      [ordered]@{
        role = "user"
        content = @(
          [ordered]@{
            type = "input_text"
            text = $Request.prompt
          },
          [ordered]@{
            type = "input_image"
            image_url = $ImageDataUrl
            detail = "low"
          }
        )
      }
    )
  }
}

function Get-ResponseText {
  param(
    $Response
  )

  if ($Response.output_text -and $Response.output_text.Trim().Length -gt 0) {
    return [string]$Response.output_text
  }

  if ($null -ne $Response.output) {
    foreach ($item in $Response.output) {
      if ($item.type -ne "message" -or $null -eq $item.content) {
        continue
      }

      foreach ($content in $item.content) {
        if ($content.type -eq "output_text" -and $content.text -and $content.text.Trim().Length -gt 0) {
          return [string]$content.text
        }
      }
    }
  }

  if ($Response.status -eq "incomplete") {
    $reason = $null
    if ($null -ne $Response.incomplete_details) {
      $reason = [string]$Response.incomplete_details.reason
    }

    if ($reason) {
      throw ("OpenAI response was incomplete: " + $reason)
    }

    throw "OpenAI response was incomplete."
  }

  throw "OpenAI did not return any prompt text."
}

try {
  $request = Get-RequestData
  $imageDataUrl = Get-ImageDataUrl
  $headers = New-Headers -ApiKey $request.api_key
  $body = New-Body -Request $request -ImageDataUrl $imageDataUrl
  $response = Invoke-RestMethod `
    -Method Post `
    -Uri "https://api.openai.com/v1/responses" `
    -Headers $headers `
    -Body ($body | ConvertTo-Json -Depth 10)

  $prompt = Get-ResponseText -Response $response
  Write-Result -Ok $true -Prompt $prompt
}
catch {
  $message = $_.Exception.Message
  if (-not $message) {
    $message = "Unknown OpenAI prompt enhancement error."
  }

  Write-Info ("Error: " + $message)
  Write-Result -Ok $false -ErrorMessage $message
  exit 1
}
