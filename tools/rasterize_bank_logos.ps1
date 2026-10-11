$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$out = Join-Path $root 'source_assets/wallet_photoreal/bank_logos_raster'
$profile = Join-Path $root 'build/chrome-logo-raster-profile'
$html = Join-Path $root 'build/bank-logo-raster.html'
New-Item -ItemType Directory -Force $out,$profile | Out-Null
$logos = [ordered]@{
  bank_sber='assets/icons/banks/bank_sber.svg'; bank_alfa='assets/icons/banks/bank_alfa.svg'
  bank_t='assets/icons/banks/bank_t.png'; bank_bakai='assets/icons/banks/bank_bakai.png'
  bank_kaspi='assets/icons/banks/bank_kaspi.svg'; bank_gpb='assets/icons/banks/bank_gpb.png'
  bank_rshb='assets/icons/banks/bank_rshb.png'; bank_halyk='assets/icons/banks/bank_halyk.svg'
  bank_bcc='assets/icons/banks/bank_bcc.png'
}
foreach($pair in $logos.GetEnumerator()) {
  $source = (Resolve-Path (Join-Path $root $pair.Value)).Path.Replace('\','/')
  $markup = @"
<!doctype html><html><head><style>
html,body{margin:0;width:512px;height:512px;background:transparent;overflow:hidden}
body{display:flex;align-items:center;justify-content:center}
img{width:400px;height:400px;object-fit:contain}
</style></head><body><img src="file:///$source"></body></html>
"@
  [IO.File]::WriteAllText($html,$markup,[Text.UTF8Encoding]::new($false))
  $target = Join-Path $out "$($pair.Key).png"
  & $chrome --headless=new --disable-gpu --allow-file-access-from-files --hide-scrollbars `
    --default-background-color=00000000 --window-size=512,512 --user-data-dir="$profile" `
    --screenshot="$target" "file:///$($html.Replace('\','/'))" | Out-Null
  if (!(Test-Path $target)) { throw "Chrome did not create $target" }
}
Write-Host "Rasterized $($logos.Count) accepted bank logos."
