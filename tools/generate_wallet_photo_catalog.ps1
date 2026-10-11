param([switch]$PilotOnly)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$root=Split-Path $PSScriptRoot
$sourceDir=Join-Path $root 'source_assets/wallet_photoreal'
$assetDir=Join-Path $root 'assets/wallet_photoreal'
$logoDir=Join-Path $sourceDir 'bank_logos_raster'
New-Item -ItemType Directory -Force $assetDir | Out-Null
$utf8=[Text.UTF8Encoding]::new($false)

$banks=@(
  [pscustomobject]@{slug='sber';id='bank_sber';name='Сбер';logo='assets/icons/banks/bank_sber.svg'},
  [pscustomobject]@{slug='alfa';id='bank_alfa';name='Альфа-Банк';logo='assets/icons/banks/bank_alfa.svg'},
  [pscustomobject]@{slug='t';id='bank_t';name='Т-Банк / Тинькофф';logo='assets/icons/banks/bank_t.png'},
  [pscustomobject]@{slug='bakai';id='bank_bakai';name='Бакай Банк';logo='assets/icons/banks/bank_bakai.png'},
  [pscustomobject]@{slug='kaspi';id='bank_kaspi';name='Kaspi';logo='assets/icons/banks/bank_kaspi.svg'},
  [pscustomobject]@{slug='gpb';id='bank_gpb';name='Газпромбанк';logo='assets/icons/banks/bank_gpb.png'},
  [pscustomobject]@{slug='rshb';id='bank_rshb';name='Россельхозбанк';logo='assets/icons/banks/bank_rshb.png'},
  [pscustomobject]@{slug='halyk';id='bank_halyk';name='Halyk';logo='assets/icons/banks/bank_halyk.svg'},
  [pscustomobject]@{slug='bcc';id='bank_bcc';name='Банк ЦентрКредит';logo='assets/icons/banks/bank_bcc.png'}
)
$cardVariants=@(
  [pscustomobject]@{slug='green';label='фирменная карта';base='card_base_green.png'},
  [pscustomobject]@{slug='graphite';label='графитовая карта';base='card_base_graphite.png'},
  [pscustomobject]@{slug='silver';label='серебристая карта';base='card_base_silver.png'},
  [pscustomobject]@{slug='gold';label='золотистая карта';base='card_base_gold.png'}
)
$accountVariants=@(
  [pscustomobject]@{slug='checking';label='расчётный счёт';base='account_base_checking.png';cx=430;cy=625;w=150;h=110;angle=-8},
  [pscustomobject]@{slug='deposit';label='депозит';base='account_base_deposit.png';cx=795;cy=790;w=145;h=105;angle=0},
  [pscustomobject]@{slug='savings';label='накопительный счёт';base='account_base_savings.png';cx=690;cy=565;w=145;h=105;angle=0}
)
$walletColors=@(
  [pscustomobject]@{slug='black';label='чёрное';hex='#202124'},
  [pscustomobject]@{slug='cognac';label='коньячное';hex='#A35424'},
  [pscustomobject]@{slug='dark_brown';label='тёмно-коричневое';hex='#4B2D22'},
  [pscustomobject]@{slug='burgundy';label='бордовое';hex='#6E1F35'},
  [pscustomobject]@{slug='navy';label='тёмно-синее';hex='#17395E'},
  [pscustomobject]@{slug='emerald';label='изумрудное';hex='#075E4B'}
)

function Save-Composite([string]$basePath,[string]$logoPath,[string]$target,[int]$cx,[int]$cy,[int]$w,[int]$h,[single]$angle) {
  $base=[Drawing.Bitmap]::new($basePath);$logo=[Drawing.Bitmap]::new($logoPath)
  try{$out=[Drawing.Bitmap]::new($base.Width,$base.Height,[Drawing.Imaging.PixelFormat]::Format32bppArgb);$g=[Drawing.Graphics]::FromImage($out)
    try{$g.CompositingMode=[Drawing.Drawing2D.CompositingMode]::SourceCopy;$g.DrawImage($base,0,0);$g.CompositingMode=[Drawing.Drawing2D.CompositingMode]::SourceOver;$g.CompositingQuality='HighQuality';$g.InterpolationMode='HighQualityBicubic';$g.SmoothingMode='HighQuality';$state=$g.Save();$g.TranslateTransform($cx,$cy);$g.RotateTransform($angle);$g.DrawImage($logo,[Drawing.Rectangle]::new(-[int]($w/2),-[int]($h/2),$w,$h));$g.Restore($state)}finally{$g.Dispose()};$out.Save($target,[Drawing.Imaging.ImageFormat]::Png);$out.Dispose()
  }finally{$base.Dispose();$logo.Dispose()}
}

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Imaging;
public static class LeatherTint {
  public static void Apply(string source,string target,string hex) {
    using(var input=new Bitmap(source)) using(var output=new Bitmap(input.Width,input.Height,PixelFormat.Format32bppArgb)) {
      var c=ColorTranslator.FromHtml(hex);
      for(int y=0;y<input.Height;y++) for(int x=0;x<input.Width;x++){
        var p=input.GetPixel(x,y); if(p.A==0) continue;
        double lum=(p.R*.299+p.G*.587+p.B*.114)/255.0;double f=.35+lum*.85;double neutral=lum*70;double hi=Math.Max(0,(lum-.72)*1.5);
        int b=(int)Math.Min(255,c.B*f+neutral+(255-c.B)*hi),g=(int)Math.Min(255,c.G*f+neutral+(255-c.G)*hi),r=(int)Math.Min(255,c.R*f+neutral+(255-c.R)*hi);
        output.SetPixel(x,y,Color.FromArgb(p.A,r,g,b));
      }
      output.Save(target,ImageFormat.Png);
    }
  }
}
'@

function Save-Optimized([string]$source,[string]$target){$input=[Drawing.Bitmap]::new($source);try{$output=[Drawing.Bitmap]::new(512,512,[Drawing.Imaging.PixelFormat]::Format32bppArgb);$g=[Drawing.Graphics]::FromImage($output);try{$g.Clear([Drawing.Color]::Transparent);$g.CompositingMode='SourceCopy';$g.CompositingQuality='HighQuality';$g.InterpolationMode='HighQualityBicubic';$g.SmoothingMode='HighQuality';$g.DrawImage($input,[Drawing.Rectangle]::new(0,0,512,512))}finally{$g.Dispose()};$output.Save($target,[Drawing.Imaging.ImageFormat]::Png);$output.Dispose()}finally{$input.Dispose()}}

$selectedBanks=if($PilotOnly){@($banks[0])}else{$banks}
foreach($bank in $selectedBanks){$logo=Join-Path $logoDir "$($bank.id).png";foreach($v in $cardVariants){$id="card_$($bank.slug)_$($v.slug)";Save-Composite (Join-Path $sourceDir $v.base) $logo (Join-Path $sourceDir "$id.png") 870 545 300 230 -4;Save-Optimized (Join-Path $sourceDir "$id.png") (Join-Path $assetDir "$id.png")};foreach($v in $accountVariants){$id="account_$($bank.slug)_$($v.slug)";Save-Composite (Join-Path $sourceDir $v.base) $logo (Join-Path $sourceDir "$id.png") $v.cx $v.cy $v.w $v.h $v.angle;Save-Optimized (Join-Path $sourceDir "$id.png") (Join-Path $assetDir "$id.png")}}

$walletModels=@([pscustomobject]@{slug='bifold';name='Классическое портмоне';base='wallet_bifold_black_base.png'},[pscustomobject]@{slug='zip';name='Длинное портмоне на молнии';base='wallet_zip_cognac_base.png'})
$selectedColors=if($PilotOnly){@($walletColors[0])}else{$walletColors}
foreach($model in $walletModels){foreach($color in $selectedColors){$id="wallet_$($model.slug)_$($color.slug)";[LeatherTint]::Apply((Join-Path $sourceDir $model.base),(Join-Path $sourceDir "$id.png"),$color.hex);Save-Optimized (Join-Path $sourceDir "$id.png") (Join-Path $assetDir "$id.png")}}

if($PilotOnly){Write-Host 'Generated pilot: 4 Sber cards, 2 black wallets, 3 Sber account images.';exit}

$extra=@(
  [pscustomobject]@{id='safe_steel_photo';name='Стальной сейф';kind='Сейф';file='extra_safe_steel.png';syn='металл хранение'},
  [pscustomobject]@{id='safe_black_photo';name='Чёрный сейф';kind='Сейф';file='extra_safe_black.png';syn='чёрный хранение'},
  [pscustomobject]@{id='cashbox_home_photo';name='Домашняя касса';kind='Наличные';file='extra_cashbox_home.png';syn='касса деньги дом'},
  [pscustomobject]@{id='banknotes_stack_photo';name='Стопка банкнот';kind='Наличные';file='extra_banknotes_stack.png';syn='купюры деньги'},
  [pscustomobject]@{id='coins_photo';name='Монеты';kind='Наличные';file='extra_coins.png';syn='мелочь деньги'},
  [pscustomobject]@{id='bank_cell_photo';name='Банковская ячейка';kind='Сейф';file='extra_bank_cell.png';syn='депозитарий хранение'}
)
foreach($x in $extra){$src=Join-Path $sourceDir $x.file;if(!(Test-Path $src)){throw "Missing generated extra: $($x.file)"};Copy-Item $src (Join-Path $sourceDir "$($x.id).png") -Force;Save-Optimized (Join-Path $sourceDir "$($x.id).png") (Join-Path $assetDir "$($x.id).png")}

$rows=[Collections.Generic.List[object]]::new()
foreach($bank in $banks){$rows.Add([ordered]@{icon_id=$bank.id;name=$bank.name;group='Банки';bank=$bank.name;kind='Логотип';asset=$bank.logo;source=$bank.logo;synonyms="$($bank.name) банк логотип";method='Принятый банковский логотип; источник и условия в assets/icons/banks/sources.json'})}
foreach($bank in $banks){foreach($v in $cardVariants){$id="card_$($bank.slug)_$($v.slug)";$rows.Add([ordered]@{icon_id=$id;name="$($bank.name) — $($v.label)";group='Карты';bank=$bank.name;kind='Карта';asset="assets/wallet_photoreal/$id.png";source="source_assets/wallet_photoreal/$id.png";synonyms="$($bank.name) дебетовая банковская карта $($v.slug)";method='OpenAI generated blank physical card base + accepted official logo composited locally'})}}
foreach($model in $walletModels){foreach($color in $walletColors){$id="wallet_$($model.slug)_$($color.slug)";$rows.Add([ordered]@{icon_id=$id;name="$($model.name) — $($color.label)";group='Портмоне';bank='';kind='Портмоне';asset="assets/wallet_photoreal/$id.png";source="source_assets/wallet_photoreal/$id.png";synonyms="кошелёк бумажник кожа $($color.label)";method='OpenAI generated premium unbranded leather model + deterministic color adaptation preserving texture'})}}
foreach($bank in $banks){foreach($v in $accountVariants){$id="account_$($bank.slug)_$($v.slug)";$rows.Add([ordered]@{icon_id=$id;name="$($bank.name) — $($v.label)";group='Счета и депозиты';bank=$bank.name;kind=(@{checking='Расчётный счёт';deposit='Депозит';savings='Накопительный счёт'}[$v.slug]);asset="assets/wallet_photoreal/$id.png";source="source_assets/wallet_photoreal/$id.png";synonyms="$($bank.name) $($v.label) вклад накопления";method='OpenAI generated finance composition + accepted official logo composited locally'})}}
foreach($x in $extra){$rows.Add([ordered]@{icon_id=$x.id;name=$x.name;group='Сейфы и наличные';bank='';kind=$x.kind;asset="assets/wallet_photoreal/$($x.id).png";source="source_assets/wallet_photoreal/$($x.id).png";synonyms=$x.syn;method='OpenAI generated standalone finance product photograph'})}
if($rows.Count-ne90){throw "Expected 90 catalog entries, got $($rows.Count)"}
foreach($row in $rows){if($row.asset.StartsWith('assets/wallet_photoreal')){$im=[Drawing.Image]::FromFile((Join-Path $root $row.source));$ai=[Drawing.Image]::FromFile((Join-Path $root $row.asset));try{$row.source_width=$im.Width;$row.source_height=$im.Height;$row.width=$ai.Width;$row.height=$ai.Height}finally{$im.Dispose();$ai.Dispose()};$row.sha256=(Get-FileHash (Join-Path $root $row.asset) -Algorithm SHA256).Hash.ToLowerInvariant()}else{$row.source_width=$null;$row.source_height=$null;$row.width=$null;$row.height=$null;$row.sha256=(Get-FileHash (Join-Path $root $row.asset) -Algorithm SHA256).Hash.ToLowerInvariant()}}
[IO.File]::WriteAllText((Join-Path $assetDir 'registry.json'),($rows|ConvertTo-Json -Depth 5),$utf8)

function DQ([string]$s){$s.Replace("'","\'")}
$dart=[Text.StringBuilder]::new();[void]$dart.AppendLine("import 'icon_catalog.dart';");[void]$dart.AppendLine();[void]$dart.AppendLine('// Generated by tools/generate_wallet_photo_catalog.ps1.');[void]$dart.AppendLine('const walletPhotoGeneratedCatalog = <WalletIconChoice>[')
foreach($row in @($rows|Where-Object {$_.kind-ne'Логотип'})){[void]$dart.AppendLine('  WalletIconChoice(');[void]$dart.AppendLine("    '$(DQ $row.icon_id)',");[void]$dart.AppendLine("    '$(DQ $row.name)',");[void]$dart.AppendLine("    '$(DQ $row.group)',");[void]$dart.AppendLine("    '$(DQ $row.asset)',");[void]$dart.AppendLine("    '$(DQ $row.synonyms)',");[void]$dart.AppendLine("    bank: '$(DQ $row.bank)',");[void]$dart.AppendLine("    kind: '$(DQ $row.kind)',");[void]$dart.AppendLine('  ),')};[void]$dart.AppendLine('];')
[IO.File]::WriteAllText((Join-Path $root 'lib/wallet_photo_catalog.dart'),$dart.ToString(),$utf8)
Write-Host 'Generated 90-entry wallet catalog: 9 logos, 36 cards, 12 wallets, 27 accounts, 6 cash/safe assets.'
