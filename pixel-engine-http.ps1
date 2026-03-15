param(
  [Parameter(Mandatory = $true)]
  [string]$RequestPath,

  [Parameter(Mandatory = $true)]
  [string]$ImagePath,

  [Parameter(Mandatory = $true)]
  [string]$ResultPath,

  [Parameter(Mandatory = $true)]
  [string]$OutputImagePath
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
    [string]$ErrorMessage = $null,
    $Metadata = $null,
    [string]$JobId = $null,
    [string]$Status = $null,
    [string]$ContentType = $null
  )

  $result = [ordered]@{
    ok = $Ok
    error = $ErrorMessage
    api_job_id = $JobId
    status = $Status
    content_type = $ContentType
    output_image_path = $(if ($Ok) { $OutputImagePath } else { $null })
    metadata = $Metadata
  }

  $json = $result | ConvertTo-Json -Depth 10
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($ResultPath, $json, $utf8NoBom)
}

try {
  $request = Get-Content -Raw -Path $RequestPath | ConvertFrom-Json
  Write-Info "Loaded request file."

  if (-not (Test-Path -LiteralPath $ImagePath)) {
    throw "Input image not found: $ImagePath"
  }

  $imageBytes = [System.IO.File]::ReadAllBytes($ImagePath)
  $imageBase64 = [System.Convert]::ToBase64String($imageBytes)
  Write-Info ("Loaded input PNG (" + $imageBytes.Length + " bytes).")

  $headers = @{
    Authorization = "Bearer $($request.api_key)"
    "Content-Type" = "application/json"
  }

  $body = [ordered]@{
    image = $imageBase64
    prompt = $request.prompt
    output_frames = [int]$request.output_frames
    output_format = "spritesheet"
    pixel_config = [ordered]@{}
  }

  if ($null -ne $request.palette) {
    $body.pixel_config.palette = @($request.palette)
    Write-Info ("Using sprite palette with " + $body.pixel_config.palette.Count + " colors.")
  }
  elseif ($null -ne $request.colors) {
    $body.pixel_config.colors = [int]$request.colors
    Write-Info ("Using generated palette size " + $body.pixel_config.colors + ".")
  }
  else {
    throw "Request must include either palette colors or a palette size."
  }

  if ($request.negative_prompt -and $request.negative_prompt.Trim().Length -gt 0) {
    $body.negative_prompt = $request.negative_prompt
  }

  if ($request.matte_color -and $request.matte_color.Trim().Length -gt 0) {
    $body.matte_color = $request.matte_color
  }

  $submitResponse = Invoke-RestMethod `
    -Method Post `
    -Uri "https://api.pixelengine.ai/functions/v1/animate" `
    -Headers $headers `
    -Body ($body | ConvertTo-Json -Depth 10)

  if (-not $submitResponse.api_job_id) {
    throw "Pixel Engine did not return an api_job_id."
  }

  $jobId = [string]$submitResponse.api_job_id
  $status = [string]$submitResponse.status
  $job = $null
  Write-Info ("Submitted animate job: " + $jobId + " (" + $status + ")")

  while ($true) {
    Start-Sleep -Seconds 3

    $job = Invoke-RestMethod `
      -Method Get `
      -Uri ("https://api.pixelengine.ai/functions/v1/jobs?id=" + [uri]::EscapeDataString($jobId)) `
      -Headers @{ Authorization = $headers.Authorization }

    $status = [string]$job.status
    $progress = 0
    if ($null -ne $job.progress) {
      $progress = [math]::Round(([double]$job.progress) * 100, 1)
    }
    Write-Info ("Poll status: " + $status + " (" + $progress + "%)")

    if ($status -eq "success") {
      break
    }

    if ($status -eq "failure") {
      $message = $job.error.message
      if (-not $message) {
        $message = "Generation failed."
      }
      throw $message
    }
  }

  if (-not $job.output.url) {
    throw "Pixel Engine job succeeded but no download URL was returned."
  }

  Invoke-WebRequest -Uri $job.output.url -OutFile $OutputImagePath
  Write-Info ("Downloaded spritesheet to " + $OutputImagePath)
  if ($null -ne $job.output.metadata) {
    Write-Info ("Metadata: " + ($job.output.metadata | ConvertTo-Json -Compress))
  }

  Write-Result `
    -Ok $true `
    -Metadata $job.output.metadata `
    -JobId $jobId `
    -Status $status `
    -ContentType $job.output.content_type
}
catch {
  $message = $_.Exception.Message
  if (-not $message) {
    $message = "Unknown Pixel Engine error."
  }

  Write-Info ("Error: " + $message)
  Write-Result -Ok $false -ErrorMessage $message
  exit 1
}
