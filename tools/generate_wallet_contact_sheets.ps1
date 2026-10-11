param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot
$registry = Get-Content -LiteralPath (Join-Path $root 'assets/wallet_photoreal/registry.json') -Raw -Encoding utf8 | ConvertFrom-Json
$hqRegistry = Get-Content -LiteralPath (Join-Path $root 'assets/wallet_photoreal/bank_icons_hq_registry.json') -Raw -Encoding utf8 | ConvertFrom-Json
$qa = Join-Path $root 'build/qa'
New-Item -ItemType Directory -Force $qa | Out-Null

function Resolve-Image([object]$row) {
  if ($row.asset.EndsWith('.svg')) {
    return Join-Path $root "source_assets/wallet_photoreal/bank_logos_raster/$($row.icon_id).png"
  }
  # The application deliberately ships the native asset path. Contact sheets
  # must show that exact file rather than an older derived/master composition.
  return Join-Path $root $row.asset
}

function Write-Grid([object[]]$rows,[string]$target,[int]$columns,[int]$tileWidth,[int]$tileHeight,[int]$imageSize,[int]$fontSize) {
  $lineCount = [Math]::Ceiling($rows.Count / $columns)
  $canvas = [Drawing.Bitmap]::new($columns * $tileWidth, $lineCount * $tileHeight)
  $g = [Drawing.Graphics]::FromImage($canvas)
  $font = [Drawing.Font]::new('Segoe UI',$fontSize)
  $small = [Drawing.Font]::new('Segoe UI',[Math]::Max(9,$fontSize - 3))
  $format = [Drawing.StringFormat]::new()
  $format.Alignment = 'Center'; $format.LineAlignment = 'Near'; $format.Trimming = 'EllipsisCharacter'
  try {
    $g.Clear([Drawing.Color]::FromArgb(244,248,245)); $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'HighQuality'
    for ($i=0; $i -lt $rows.Count; $i++) {
      $row=$rows[$i]; $x=($i % $columns)*$tileWidth; $y=[Math]::Floor($i/$columns)*$tileHeight
      $g.FillRectangle([Drawing.Brushes]::White,$x+4,$y+4,$tileWidth-8,$tileHeight-8)
      $g.DrawRectangle([Drawing.Pens]::LightGray,$x+4,$y+4,$tileWidth-8,$tileHeight-8)
      $image=[Drawing.Image]::FromFile((Resolve-Image $row))
      try {
        $scale=[Math]::Min($imageSize/$image.Width,$imageSize/$image.Height); $w=[int]($image.Width*$scale); $h=[int]($image.Height*$scale)
        $ix=$x+[int](($tileWidth-$w)/2); $iy=$y+12+[int](($imageSize-$h)/2)
        $g.DrawImage($image,[Drawing.Rectangle]::new($ix,$iy,$w,$h))
      } finally {$image.Dispose()}
      $g.DrawString([string]$row.name,$font,[Drawing.Brushes]::Black,[Drawing.RectangleF]::new($x+8,$y+$imageSize+16,$tileWidth-16,$tileHeight-$imageSize-38),$format)
      $g.DrawString([string]$row.icon_id,$small,[Drawing.Brushes]::DimGray,[Drawing.RectangleF]::new($x+8,$y+$tileHeight-24,$tileWidth-16,20),$format)
    }
    $canvas.Save($target,[Drawing.Imaging.ImageFormat]::Png)
  } finally {$format.Dispose();$small.Dispose();$font.Dispose();$g.Dispose();$canvas.Dispose()}
}

Write-Grid @($registry) (Join-Path $qa 'wallet-catalog-contact-sheet.png') 10 220 190 122 12
Write-Grid @($registry | Where-Object {$_.kind -eq 'Карта'}) (Join-Path $qa 'wallet-bank-cards-contact-sheet.png') 6 320 245 175 14
Write-Grid @($registry | Where-Object {$_.kind -eq 'Портмоне'}) (Join-Path $qa 'wallet-portfolios-contact-sheet.png') 4 360 300 220 14
Write-Grid @($registry | Where-Object {$_.group -eq 'Счета и депозиты'}) (Join-Path $qa 'wallet-accounts-contact-sheet.png') 6 300 245 170 13
Write-Grid @($registry | Where-Object {$_.group -eq 'Сейфы и наличные'}) (Join-Path $qa 'wallet-cash-safes-contact-sheet.png') 3 380 330 245 15
Write-Grid @($registry | Where-Object {$_.icon_id -like 'card_sber_*'}) (Join-Path $qa 'wallet-sber-cards-large.png') 2 600 560 440 20
Write-Grid @($registry | Where-Object {$_.icon_id -like 'wallet_bifold_*'}) (Join-Path $qa 'wallet-bifold-colors-large.png') 3 430 410 315 17
Write-Grid @($registry | Where-Object {$_.icon_id -like 'wallet_zip_*'}) (Join-Path $qa 'wallet-zip-colors-large.png') 3 430 410 315 17
Write-Grid @($hqRegistry) (Join-Path $qa 'bank-icons-hq-contact-sheet.png') 3 520 390 280 16
Write-Grid @($hqRegistry | Where-Object {$_.kind -eq 'card'}) (Join-Path $qa 'bank-icons-hq-cards.png') 3 520 390 280 16
Write-Grid @($hqRegistry | Where-Object {$_.kind -eq 'savings'}) (Join-Path $qa 'bank-icons-hq-savings.png') 3 520 440 320 16

function Write-Comparison([string]$target) {
  $ids=@('card_sber_green','wallet_bifold_black','account_sber_checking')
  $sizes=@(32,48,80);$scale=2;$cellW=260;$cellH=230
  $canvas=[Drawing.Bitmap]::new($cellW*6,$cellH*$ids.Count)
  $g=[Drawing.Graphics]::FromImage($canvas);$font=[Drawing.Font]::new('Segoe UI',15);$small=[Drawing.Font]::new('Segoe UI',12)
  try{$g.Clear([Drawing.Color]::FromArgb(244,248,245));$g.InterpolationMode='NearestNeighbor'
    for($r=0;$r-lt$ids.Count;$r++){for($s=0;$s-lt$sizes.Count;$s++){foreach($after in @($false,$true)){$col=$s*2+$(if($after){1}else{0});$x=$col*$cellW;$y=$r*$cellH;$g.FillRectangle([Drawing.Brushes]::White,$x+4,$y+4,$cellW-8,$cellH-8);$g.DrawRectangle([Drawing.Pens]::LightGray,$x+4,$y+4,$cellW-8,$cellH-8);$id=$ids[$r];$file="$id.png";$path=if($after){Join-Path $root "assets/wallet_photoreal/$file"}else{Join-Path $root "build/qa/wallet-before/$file"};$im=[Drawing.Image]::FromFile($path);try{$draw=$sizes[$s]*$scale;$g.DrawImage($im,[Drawing.Rectangle]::new($x+[int](($cellW-$draw)/2),$y+26,$draw,$draw))}finally{$im.Dispose()};$title="$(if($after){'После'}else{'До'}) — $($sizes[$s]) px";$g.DrawString($title,$font,[Drawing.Brushes]::Black,$x+12,$y+6);$g.DrawString($id,$small,[Drawing.Brushes]::DimGray,$x+12,$y+$cellH-22)}}}
    $canvas.Save($target,[Drawing.Imaging.ImageFormat]::Png)
  }finally{$small.Dispose();$font.Dispose();$g.Dispose();$canvas.Dispose()}
}
Write-Comparison (Join-Path $qa 'wallet-before-after-32-48-80.png')
Write-Host 'Wallet contact sheets written to build/qa.'
