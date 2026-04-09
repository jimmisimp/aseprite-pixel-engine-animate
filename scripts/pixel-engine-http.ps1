param(
  [Parameter(Mandatory = $true)]
  [string]$RequestPath,

  [string]$ImagePath = "",

  [Parameter(Mandatory = $true)]
  [string]$ResultPath,

  [Parameter(Mandatory = $true)]
  [string]$OutputImagePath
)

$ErrorActionPreference = "Stop"

$script:PeProgressId = 0
$script:PePollTick = 0

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
catch {
}

function Stop-PeProgress {
  Write-Progress -Id $script:PeProgressId -Activity " " -Completed
}

function Write-Info {
  param(
    [string]$Message,
    [ValidateSet("Default", "Dim", "Ok", "Warn", "Err")]
    [string]$Tone = "Default"
  )

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

function Write-PeProgress {
  param(
    [string]$Status,
    [string]$CurrentOperation = "",
    $PercentComplete = $null
  )

  $params = @{
    Id               = $script:PeProgressId
    Activity         = "Pixel Engine - Animate"
    Status           = $Status
    CurrentOperation = $CurrentOperation
  }
  if ($null -ne $PercentComplete) {
    $params.PercentComplete = [math]::Max(0, [math]::Min(100, [int]$PercentComplete))
  }
  Write-Progress @params
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

function Write-BodyDump {
  param(
    [string]$Json
  )

  $sanitized = [regex]::Replace($Json, '"image"\s*:\s*"([^"]{80})[^"]*"', {
    param($m)
    $full = $m.Value
    $total = ($full -split '"image"')[1].Length - 5
    '"image":"' + $m.Groups[1].Value + '...<' + $total + ' chars total>"'
  })

  $dumpPath = $ResultPath + ".body-sent.json"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($dumpPath, $sanitized, $utf8NoBom)
}

function Get-RequestData {
  $request = Get-Content -Raw -Path $RequestPath | ConvertFrom-Json
  Write-Info "Loaded request file." -Tone Ok
  return $request
}

function Get-ImageBase64 {
  if (-not (Test-Path -LiteralPath $ImagePath)) {
    throw "Input image not found: $ImagePath"
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

function New-AnimateRequestBody {
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

function New-KeyframeRequestBody {
  param(
    $Request
  )

  $frameList = @($Request.frames)
  if ($frameList.Count -lt 1) {
    throw "Keyframe request must include at least one frame."
  }

  $frames = @()
  foreach ($kf in $frameList) {
    $path = [string]$kf.image_path
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
      throw ("Keyframe image not found: " + $path)
    }

    $imageBytes = [System.IO.File]::ReadAllBytes($path)
    $b64 = [System.Convert]::ToBase64String($imageBytes)
    Write-Info ("Loaded keyframe index " + $kf.index + " (" + $imageBytes.Length + " bytes).") -Tone Ok

    $frameObj = [ordered]@{
      index = [int]$kf.index
      image = $b64
    }

    if ($null -ne $kf.strength) {
      $frameObj.strength = [double]$kf.strength
    }

    $frames += $frameObj
  }

  $body = [ordered]@{
    prompt = $Request.prompt
    render_mode = "pixel"
    total_frames = [int]$Request.total_frames
    frames = $frames
    output_format = "spritesheet"
  }

  if ($Request.negative_prompt -and $Request.negative_prompt.Trim().Length -gt 0) {
    $body.negative_prompt = $Request.negative_prompt
  }

  if ($Request.matte_color -and $Request.matte_color.Trim().Length -gt 0) {
    $body.matte_color = $Request.matte_color
  }

  if ($null -ne $Request.seed) {
    $body.seed = [long]$Request.seed
  }

  $body.pixel_config = [ordered]@{}
  if ($null -ne $Request.palette) {
    $body.pixel_config.palette = @($Request.palette)
    Write-Info ("Using sprite palette with " + $body.pixel_config.palette.Count + " colors.")
  }
  elseif ($null -ne $Request.colors) {
    $body.pixel_config.colors = [int]$Request.colors
    Write-Info ("Using generated palette size " + $body.pixel_config.colors + ".")
  }
  else {
    throw "Keyframe request requires palette colors or a palette size."
  }

  return $body
}

function Submit-Job {
  param(
    $Headers,
    $Body,
    [string]$Endpoint
  )

  Write-PeProgress `
    -Status "Submitting job..." `
    -CurrentOperation ("POST " + $Endpoint) `
    -PercentComplete 0

  $jsonBody = $Body | ConvertTo-Json -Depth 10
  Write-BodyDump -Json $jsonBody

  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
  $req = [System.Net.HttpWebRequest]::Create($Endpoint)
  $req.Method = "POST"
  $req.ContentType = "application/json; charset=utf-8"
  $req.ContentLength = $bodyBytes.Length
  foreach ($key in $Headers.Keys) {
    $req.Headers.Add($key, $Headers[$key])
  }

  $reqStream = $req.GetRequestStream()
  $reqStream.Write($bodyBytes, 0, $bodyBytes.Length)
  $reqStream.Close()

  $responseBody = $null
  try {
    $webResponse = $req.GetResponse()
    $reader = New-Object System.IO.StreamReader($webResponse.GetResponseStream())
    $responseBody = $reader.ReadToEnd()
    $reader.Close()
    $webResponse.Close()
  }
  catch [System.Net.WebException] {
    $errorResponse = $_.Exception.Response
    if ($errorResponse) {
      $reader = New-Object System.IO.StreamReader($errorResponse.GetResponseStream())
      $errorBody = $reader.ReadToEnd()
      $reader.Close()
      $errorResponse.Close()
      $statusCode = [int]$errorResponse.StatusCode
      throw "API returned HTTP $statusCode : $errorBody"
    }
    throw
  }

  $response = $responseBody | ConvertFrom-Json
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

function Get-DisplayJobStatus {
  param(
    [string]$Status,
    [double]$ProgressPercent
  )

  if ($Status -eq "pending" -and $ProgressPercent -eq 0) {
    return "waiting"
  } elseif ($Status -eq "pending") {
    return "processing"
  }

  return $Status
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
  $progress = 0
  $shortId = $JobId.Substring(0, [Math]::Min(8, $JobId.Length))
  Write-Info ("Job submitted - id " + $shortId + "... - " + (Get-DisplayJobStatus -Status $status -ProgressPercent $progress)) -Tone Ok

  $spin = @("|", "/", "-", "\")
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  while ($true) {
    $ch = $spin[$script:PePollTick % $spin.Length]
    $script:PePollTick++
    $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 0)
    $pct = [int][math]::Round($progress)
    $displayStatus = Get-DisplayJobStatus -Status $status -ProgressPercent $progress

    Write-PeProgress `
      -Status ($displayStatus + " - " + $progress + "% - " + $elapsed + "s elapsed") `
      -CurrentOperation ($ch + " Waiting for Pixel Engine (job " + $shortId + "...)") `
      -PercentComplete $pct

    Start-Sleep -Seconds 3

    $job = Get-JobUpdate -AuthorizationHeader $AuthorizationHeader -JobId $JobId
    $status = [string]$job.status
    $progress = Get-ProgressPercent -Job $job

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

  Write-PeProgress `
    -Status "Downloading spritesheet..." `
    -CurrentOperation $OutputImagePath `
    -PercentComplete 95

  Invoke-WebRequest -Uri $Job.output.url -OutFile $OutputImagePath
  Write-Info ("Saved spritesheet to " + $OutputImagePath) -Tone Ok

  if ($null -ne $Job.output.metadata) {
    Write-Info ("Metadata: " + ($Job.output.metadata | ConvertTo-Json -Compress)) -Tone Dim
  }
}

try {
  $request = Get-RequestData
  $headers = New-PixelEngineHeaders -ApiKey $request.api_key

  $mode = "animate"
  if ($request.mode) {
    $mode = [string]$request.mode
  }

  if ($mode -eq "keyframes") {
    $body = New-KeyframeRequestBody -Request $request
    $submitResponse = Submit-Job `
      -Headers $headers `
      -Body $body `
      -Endpoint "https://api.pixelengine.ai/functions/v1/keyframes"
  }
  else {
    if (-not $ImagePath -or -not (Test-Path -LiteralPath $ImagePath)) {
      throw "Input image not found: $ImagePath"
    }
    $imageBase64 = Get-ImageBase64
    $body = New-AnimateRequestBody -Request $request -ImageBase64 $imageBase64
    $submitResponse = Submit-Job `
      -Headers $headers `
      -Body $body `
      -Endpoint "https://api.pixelengine.ai/functions/v1/animate"
  }

  $jobId = [string]$submitResponse.api_job_id
  $job = Wait-ForJobCompletion `
    -AuthorizationHeader $headers.Authorization `
    -JobId $jobId `
    -InitialStatus ([string]$submitResponse.status)

  Save-OutputImage -Job $job

  Write-PeProgress -Status "Done" -CurrentOperation "Animation saved" -PercentComplete 100
  Write-Info "Animation complete." -Tone Ok

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

  Write-Info $message -Tone Err
  Write-Result -Ok $false -ErrorMessage $message
  exit 1
}
finally {
  Stop-PeProgress
}
