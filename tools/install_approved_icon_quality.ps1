param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path $PSScriptRoot
$approved = Join-Path $root 'design/approved_icon_quality'
$categorySource = Join-Path $root 'source_assets/category_photoreal'
$categoryAssets = Join-Path $root 'assets/category_photoreal'
$walletSource = Join-Path $root 'source_assets/wallet_photoreal'
$walletAssets = Join-Path $root 'assets/wallet_photoreal'

# Ship the native ImageGen sources. The previous 512 px exports discarded detail
# before Flutter decoded them, especially on DPR 2/3 screens.
Get-ChildItem -LiteralPath $categorySource -Filter '*.png' | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $categoryAssets $_.Name) -Force
}
Get-ChildItem -LiteralPath $walletAssets -Filter '*.png' | ForEach-Object {
  $source = Join-Path $walletSource $_.Name
  if (Test-Path -LiteralPath $source) {
    Copy-Item -LiteralPath $source -Destination $_.FullName -Force
  }
}

# The two first-run-only entries have no native root derivative. Keep their
# existing high-resolution compositions without claiming extra source detail.
foreach ($name in @('card_sber_business.png', 'reward_sber_spasibo.png')) {
  $master = Join-Path $walletSource "master/$name"
  if (Test-Path -LiteralPath $master) {
    Copy-Item -LiteralPath $master -Destination (Join-Path $walletAssets $name) -Force
  }
}

# Approved originals are authoritative and remain byte-identical in the app.
$approvedMap = @(
  @{ from = 'sber_emerald_approved.png'; source = (Join-Path $walletSource 'card_sber_green.png'); asset = (Join-Path $walletAssets 'card_sber_green.png') },
  @{ from = 'safe_approved.png'; source = (Join-Path $walletSource 'safe_steel_photo.png'); asset = (Join-Path $walletAssets 'safe_steel_photo.png') },
  @{ from = 'food_approved.png'; source = (Join-Path $categorySource 'cat_exp_food.png'); asset = (Join-Path $categoryAssets 'cat_exp_food.png') }
)
foreach ($item in $approvedMap) {
  $from = Join-Path $approved $item.from
  Copy-Item -LiteralPath $from -Destination $item.source -Force
  Copy-Item -LiteralPath $from -Destination $item.asset -Force
}

# Rebuild the first-run business card at native 1254 px from the clean card
# source. Its previous 2400 px composition placed the logo over the chip.
$businessTarget = Join-Path $walletSource 'card_sber_business.png'
$businessAsset = Join-Path $walletAssets 'card_sber_business.png'
$base = [Drawing.Bitmap]::new((Join-Path $walletSource 'card_base_green.png'))
$logo = [Drawing.Bitmap]::new((Join-Path $walletSource 'bank_logos_raster/bank_sber.png'))
$business = [Drawing.Bitmap]::new($base.Width, $base.Height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [Drawing.Graphics]::FromImage($business)
try {
  $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
  $graphics.DrawImage($base, 0, 0)
  $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceOver
  $graphics.CompositingQuality = 'HighQuality'
  $graphics.InterpolationMode = 'HighQualityBicubic'
  $graphics.SmoothingMode = 'HighQuality'
  # Both the brand mark and label stay on the right half. The single EMV chip
  # remains unobstructed on the left, centered vertically on the physical card.
  $graphics.DrawImage($logo, [Drawing.Rectangle]::new(650, 460, 245, 190))
  $font = [Drawing.Font]::new('Segoe UI', 40, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
  try {
    $graphics.DrawString('SBER BUSINESS', $font, [Drawing.Brushes]::White, [Drawing.RectangleF]::new(805, 530, 390, 70))
  } finally { $font.Dispose() }
  $business.Save($businessTarget, [Drawing.Imaging.ImageFormat]::Png)
  $business.Save($businessAsset, [Drawing.Imaging.ImageFormat]::Png)
} finally {
  $graphics.Dispose()
  $business.Dispose()
  $logo.Dispose()
  $base.Dispose()
}

function Update-Registry([string]$path) {
  $rows = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
  foreach ($row in $rows) {
    if (!$row.asset -or !(Test-Path -LiteralPath (Join-Path $root $row.asset))) { continue }
    $assetPath = Join-Path $root $row.asset
    if (!$assetPath.EndsWith('.png')) { continue }
    $image = [Drawing.Image]::FromFile($assetPath)
    try {
      if ($row.PSObject.Properties.Name -contains 'asset_width') {
        $row.asset_width = $image.Width
        $row.asset_height = $image.Height
        $row.asset_sha256 = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
      } else {
        $row.width = $image.Width
        $row.height = $image.Height
        $row.sha256 = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
      }
    } finally {
      $image.Dispose()
    }
  }
  $utf8 = [Text.UTF8Encoding]::new($false)
  [IO.File]::WriteAllText($path, ($rows | ConvertTo-Json -Depth 8), $utf8)
}

Update-Registry (Join-Path $categoryAssets 'registry.json')
Update-Registry (Join-Path $walletAssets 'registry.json')

Write-Host 'Installed native catalog sources and the three approved originals.'
