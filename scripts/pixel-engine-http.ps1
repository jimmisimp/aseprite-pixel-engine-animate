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

function Get-RequestData {
  $request = Get-Content -Raw -Path $RequestPath | ConvertFrom-Json
  Write-Info "Loaded request file."
  return $request
}

function Get-ImageBase64 {
  if (-not (Test-Path -LiteralPath $ImagePath)) {
    throw "Input image not found: $ImagePath"
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
    image = $ImageBase64
    prompt = $Request.prompt
    output_frames = [int]$Request.output_frames
    output_format = "spritesheet"
    pixel_config = [ordered]@{}
  }

  if ($null -ne $Request.palette) {
    $body.pixel_config.palette = @($Request.palette)
    Write-Info ("Using sprite palette with " + $body.pixel_config.palette.Count + " colors.")
  }
  elseif ($null -ne $Request.colors) {
    $body.pixel_config.colors = [int]$Request.colors
    Write-Info ("Using generated palette size " + $body.pixel_config.colors + ".")
  }
  else {
    throw "Request must include either palette colors or a palette size."
  }

  if ($Request.negative_prompt -and $Request.negative_prompt.Trim().Length -gt 0) {
    $body.negative_prompt = $Request.negative_prompt
  }

  if ($Request.matte_color -and $Request.matte_color.Trim().Length -gt 0) {
    $body.matte_color = $Request.matte_color
  }

  return $body
}

function Submit-AnimateJob {
  param(
    $Headers,
    $Body
  )

  $response = Invoke-RestMethod `
    -Method Post `
    -Uri "https://api.pixelengine.ai/functions/v1/animate" `
    -Headers $Headers `
    -Body ($Body | ConvertTo-Json -Depth 10)

  if (-not $response.api_job_id) {
    throw "Pixel Engine did not return an api_job_id."
  }

  return $response
}

function Get-JobFailureMessage {
  param(
    $Job
  )

  $message = $Job.error.message
  if (-not $message) {
    $message = "Generation failed."
  }

  return $message
}

function Get-ProgressPercent {
  param(
    $Job
  )

  if ($null -eq $Job.progress) {
    return 0
  }

  return [math]::Round(([double]$Job.progress) * 100, 1)
}

function Get-JobUpdate {
  param(
    [string]$AuthorizationHeader,
    [string]$JobId
  )

  return Invoke-RestMethod `
    -Method Get `
    -Uri ("https://api.pixelengine.ai/functions/v1/jobs?id=" + [uri]::EscapeDataString($JobId)) `
    -Headers @{ Authorization = $AuthorizationHeader }
}

function Wait-ForJobCompletion {
  param(
    [string]$AuthorizationHeader,
    [string]$JobId,
    [string]$InitialStatus
  )

  $status = $InitialStatus
  Write-Info ("Submitted animate job: " + $JobId + " (" + $status + ")")

  while ($true) {
    Start-Sleep -Seconds 3

    $job = Get-JobUpdate -AuthorizationHeader $AuthorizationHeader -JobId $JobId
    $status = [string]$job.status
    $progress = Get-ProgressPercent -Job $job
    Write-Info ("Poll status: " + $status + " (" + $progress + "%)")

    if ($status -eq "success") {
      return $job
    }

    if ($status -eq "failure") {
      throw (Get-JobFailureMessage -Job $job)
    }
  }
}

function Save-OutputImage {
  param(
    $Job
  )

  if (-not $Job.output.url) {
    throw "Pixel Engine job succeeded but no download URL was returned."
  }

  Invoke-WebRequest -Uri $Job.output.url -OutFile $OutputImagePath
  Write-Info ("Downloaded spritesheet to " + $OutputImagePath)

  if ($null -ne $Job.output.metadata) {
    Write-Info ("Metadata: " + ($Job.output.metadata | ConvertTo-Json -Compress))
  }
}

try {
  $request = Get-RequestData
  $imageBase64 = Get-ImageBase64
  $headers = New-PixelEngineHeaders -ApiKey $request.api_key
  $body = New-RequestBody -Request $request -ImageBase64 $imageBase64
  $submitResponse = Submit-AnimateJob -Headers $headers -Body $body
  $jobId = [string]$submitResponse.api_job_id
  $job = Wait-ForJobCompletion `
    -AuthorizationHeader $headers.Authorization `
    -JobId $jobId `
    -InitialStatus ([string]$submitResponse.status)

  Save-OutputImage -Job $job

  Write-Result `
    -Ok $true `
    -Metadata $job.output.metadata `
    -JobId $jobId `
    -Status ([string]$job.status) `
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
