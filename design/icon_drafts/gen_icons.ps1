$ErrorActionPreference = 'Stop'
$outDir = 'd:\CodingProjects\venera-D\design\icon_drafts'
$model = 'wan2.7-image-pro'
$size = '1024*1024'
$endpoint = 'https://token-plan.cn-beijing.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation'

$prompts = @{
  'A_vd_monogram' = 'Flat minimal mobile app icon. A white geometric line monogram merging the letters V and D into one mark: a letter V drawn with clean rounded strokes, whose right stroke curves outward into the semicircular bowl of a letter D. Thick uniform line weight, rounded stroke ends, negative space design. Centered on a solid cobalt blue background, pure flat vector, no gradient, no shadow, no texture, generous padding around the mark, square canvas, no text other than the monogram.'
  'B_night_venus' = 'Modern mobile app icon. A small glowing planet Venus shining in a deep midnight-blue night sky, with one thin elegant orbital ring sweeping around it whose curve forms a subtle letter V shape. A few tiny scattered stars. Soft luminous glow on the planet, dark navy to black background, minimal flat vector style with gentle gradients, centered composition, premium quiet mood, square canvas, no text.'
  'C_comic_book' = 'Flat vector mobile app icon. An open comic book viewed from the front, its two rising pages forming a bold letter V shape, with a small rounded speech bubble floating above the pages as an accent. Bold cobalt blue and white palette with a single warm yellow accent, clean geometric shapes, thick rounded outlines, flat design, no texture, centered, square canvas, no text.'
  'D_gradient_v' = 'Minimal mobile app icon. A white double-stroke letter V with rounded stroke ends, glowing softly with a subtle neon halo, and a single tiny bright star dot at the tail of the second stroke. Background is a smooth deep-blue to violet night gradient with a faint vignette. Modern clean icon aesthetic, centered, generous padding, square canvas, no text other than the V.'
}

foreach ($name in ($prompts.Keys | Sort-Object)) {
  Write-Host "=== Generating $name ..."
  $body = @{
    model = $model
    input = @{ messages = @(@{ role = 'user'; content = @(@{ text = $prompts[$name] }) }) }
    parameters = @{ size = $size }
  } | ConvertTo-Json -Depth 10
  try {
    $resp = Invoke-RestMethod -Method Post -Uri $endpoint `
      -Headers @{ Authorization = "Bearer $env:ANTHROPIC_AUTH_TOKEN" } `
      -ContentType 'application/json' -Body $body
    $url = $null
    foreach ($choice in $resp.output.choices) {
      foreach ($c in $choice.message.content) {
        if ($c.image) { $url = $c.image; break }
      }
      if ($url) { break }
    }
    if (-not $url) {
      Write-Host "FAILED ${name}: no image url in response"
      Write-Host ($resp | ConvertTo-Json -Depth 10)
      continue
    }
    $outFile = Join-Path $outDir "$name.png"
    Invoke-WebRequest -Uri $url -OutFile $outFile
    Write-Host "SAVED: $outFile"
  } catch {
    Write-Host "ERROR ${name}: $($_.Exception.Message)"
    if ($_.ErrorDetails) { Write-Host $_.ErrorDetails.Message }
  }
}
Write-Host '=== Done'
