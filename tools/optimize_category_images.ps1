param([string[]]$Names)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot
$sourceDir = Join-Path $root 'source_assets/category_photoreal'
$assetDir = Join-Path $root 'assets/category_photoreal'
New-Item -ItemType Directory -Force $sourceDir,$assetDir | Out-Null
if (!$Names -or $Names.Count -eq 0) {
  $Names = Get-ChildItem -LiteralPath $sourceDir -Filter '*.png' | ForEach-Object BaseName
}
foreach ($name in $Names) {
  $source = Join-Path $sourceDir "$name.png"
  $target = Join-Path $assetDir "$name.png"
  if (!(Test-Path $source)) { throw "Missing source: $source" }
  $input = [Drawing.Bitmap]::new($source)
  try {
    if ($input.Width -lt 512 -or $input.Height -lt 512) { throw "Source below 512px: $name" }
    $output = [Drawing.Bitmap]::new(512,512,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
      $output.SetResolution(96,96)
      $graphics = [Drawing.Graphics]::FromImage($output)
      try {
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($input,[Drawing.Rectangle]::new(0,0,512,512))
      } finally { $graphics.Dispose() }
      $temp = "$target.optimized.png"
      $output.Save($temp,[Drawing.Imaging.ImageFormat]::Png)
      Move-Item -Force -LiteralPath $temp -Destination $target
    } finally { $output.Dispose() }
  } finally { $input.Dispose() }
}
