param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$package = Join-Path $root 'design/bank_icons_hq'
$manifestPath = Join-Path $package 'asset_manifest.json'
$target = Join-Path $root 'assets/wallet_photoreal'
$registryPath = Join-Path $target 'bank_icons_hq_registry.json'

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
if ($manifest.asset_count -ne 15) {
  throw "Expected 15 HQ bank assets, got $($manifest.asset_count)."
}

$rows = foreach ($item in $manifest.assets) {
  $source = Join-Path $package $item.relative_path
  $fileName = "$($item.suggested_icon_id).png"
  $destination = Join-Path $target $fileName
  $actualHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $item.sha256) {
    throw "Source hash mismatch: $($item.relative_path)"
  }
  Copy-Item -LiteralPath $source -Destination $destination -Force
  $copiedHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($copiedHash -ne $item.sha256) {
    throw "Copied asset hash mismatch: $fileName"
  }
  [ordered]@{
    icon_id = $item.suggested_icon_id
    label_ru = $item.label_ru
    bank_key = $item.bank_key
    kind = $item.kind
    asset = "assets/wallet_photoreal/$fileName"
    width_px = $item.width_px
    height_px = $item.height_px
    sha256 = $item.sha256
    source = "design/bank_icons_hq/$($item.relative_path)"
    original_bytes_preserved = $true
  }
}

$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText(
  $registryPath,
  ($rows | ConvertTo-Json -Depth 6),
  $utf8
)
Write-Host "Installed $($rows.Count) byte-identical HQ bank assets."
