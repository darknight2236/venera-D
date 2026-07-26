$ErrorActionPreference = 'Stop'
$outDir = 'd:\CodingProjects\venera-D\design\icon_drafts'
$model = 'wan2.7-image-pro'
$size = '1024*1024'
$endpoint = 'https://token-plan.cn-beijing.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation'

$prompts = @{
  'D2c_crescent_fullbleed' = 'Square digital illustration, full bleed edge-to-edge background with absolutely no frame, no card, no border, no rounded corner panel: the deep navy to dark violet night gradient fills the entire image completely to all four edges. In the center, a white double-stroke letter V with rounded stroke ends, filled with a subtle blue-violet gradient, glowing softly with a gentle neon halo, as the dominant main element. To its right, a slim solid white crescent moon of the same height as the V, clearly smaller in visual weight than the V, curving around it like the bowl of a letter D, with a soft luminous glow. One tiny bright four-pointed star in the upper left dark area. Faint vignette only, clean modern flat style, balanced composition, no text, no other elements.'
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
