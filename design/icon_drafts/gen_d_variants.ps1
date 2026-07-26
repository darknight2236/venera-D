$ErrorActionPreference = 'Stop'
$outDir = 'd:\CodingProjects\venera-D\design\icon_drafts'
$model = 'wan2.7-image-pro'
$size = '1024*1024'
$endpoint = 'https://token-plan.cn-beijing.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation'

$prompts = @{
  'D1_vd_neon_ligature' = 'Minimal mobile app icon. A white glowing monogram merging letters V and D: a letter V with rounded stroke ends whose right stroke curves outward into the semicircular bowl of a letter D, drawn as one continuous elegant line with a soft neon halo. Background is a smooth deep-blue to violet night gradient with a faint vignette. A single tiny bright star dot near the ligature. Modern clean icon aesthetic, centered, generous padding, square canvas, no other text.'
  'D2_crescent_d_arc' = 'Minimal mobile app icon. A white double-stroke letter V with rounded stroke ends glowing softly with a subtle neon halo, embraced on the right side by a thin luminous crescent arc shaped like the curved bowl of a letter D, resembling a crescent moon wrapping the V. Background is a smooth deep-blue to violet night gradient, a single tiny star dot in the dark area. Clean modern icon style, centered, generous padding, square canvas, no other text.'
  'D3_orbit_d_ring' = 'Minimal mobile app icon. A white double-stroke letter V with rounded stroke ends and a soft neon glow, surrounded by one thin elegant elliptical orbital ring whose visible curve traces the outline of a letter D on the right side. A single tiny bright star dot sits on the ring like a small planet. Background is a smooth deep-blue to violet night gradient with faint vignette. Modern clean icon aesthetic, centered, generous padding, square canvas, no other text.'
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
