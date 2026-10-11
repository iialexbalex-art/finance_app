param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot
$assets = Join-Path $root 'assets/wallet_photoreal'
$source = Join-Path $root 'source_assets/wallet_photoreal'
$masters = Join-Path $source 'master'
$compact = Join-Path $assets 'compact'
$preview = Join-Path $assets 'preview'
$before = Join-Path $root 'build/qa/wallet-before'
foreach ($dir in @($masters,$compact,$preview,$before)) { New-Item -ItemType Directory -Force $dir | Out-Null }

Get-ChildItem -LiteralPath $assets -Filter '*.png' | ForEach-Object {
  $target = Join-Path $before $_.Name
  if (!(Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $_.FullName -Destination $target }
}

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Drawing2D; using System.Drawing.Imaging; using System.IO;
public static class WalletHd {
  static GraphicsPath Round(RectangleF r,float radius){var p=new GraphicsPath();float d=radius*2;p.AddArc(r.X,r.Y,d,d,180,90);p.AddArc(r.Right-d,r.Y,d,d,270,90);p.AddArc(r.Right-d,r.Bottom-d,d,d,0,90);p.AddArc(r.X,r.Bottom-d,d,d,90,90);p.CloseFigure();return p;}
  static Color Hex(string s){return ColorTranslator.FromHtml(s);}
  static Color Mix(Color a,Color b,double t){return Color.FromArgb((int)(a.R+(b.R-a.R)*t),(int)(a.G+(b.G-a.G)*t),(int)(a.B+(b.B-a.B)*t));}
  static void ImageContain(Graphics g,Image image,RectangleF box){double scale=Math.Min(box.Width/image.Width,box.Height/image.Height);float w=(float)(image.Width*scale),h=(float)(image.Height*scale);g.DrawImage(image,new RectangleF(box.X+(box.Width-w)/2,box.Y+(box.Height-h)/2,w,h));}
  static Font FitFont(Graphics g,string text,string family,float max,FontStyle style,float width){float size=max;while(size>34){var f=new Font(family,size,style,GraphicsUnit.Pixel);if(g.MeasureString(text,f).Width<=width)return f;f.Dispose();size-=4;}return new Font(family,34,style,GraphicsUnit.Pixel);}
  static void BrandLayer(Graphics target,Bitmap logo,string bank,Color text,PointF[] destination){
    using(var brand=new Bitmap(1800,560,PixelFormat.Format32bppArgb)) using(var bg=Graphics.FromImage(brand)){
      bg.Clear(Color.Transparent);bg.SmoothingMode=SmoothingMode.AntiAlias;bg.InterpolationMode=InterpolationMode.HighQualityBicubic;bg.CompositingQuality=CompositingQuality.HighQuality;
      ImageContain(bg,logo,new RectangleF(0,25,515,510));
      using(var font=FitFont(bg,bank,"Segoe UI",132,FontStyle.Bold,1190))using(var shadow=new SolidBrush(Color.FromArgb(105,text.R<100?255:0,text.G<100?255:0,text.B<100?255:0)))using(var brush=new SolidBrush(text))using(var sf=new StringFormat(){Alignment=StringAlignment.Center,LineAlignment=StringAlignment.Center}){
        bg.DrawString(bank,font,shadow,new RectangleF(588,28,1192,514),sf);
        bg.DrawString(bank,font,brush,new RectangleF(580,20,1192,514),sf);
      }
      target.DrawImage(brand,destination,new RectangleF(0,0,brand.Width,brand.Height),GraphicsUnit.Pixel);
    }
  }
  public static void Card(string basePath,string logoPath,string bank,string baseHex,string material,string masterPath,string compactPath){
    using(var input=new Bitmap(basePath)) using(var colored=new Bitmap(input.Width,input.Height,PixelFormat.Format32bppArgb)) using(var logo=new Bitmap(logoPath)) using(var canvas=new Bitmap(2400,2400,PixelFormat.Format32bppArgb)) using(var g=Graphics.FromImage(canvas)){
      if(material=="firm"){
        Color c=Hex(baseHex);for(int y=0;y<input.Height;y++)for(int x=0;x<input.Width;x++){var p=input.GetPixel(x,y);if(p.A==0)continue;double lum=(p.R*.299+p.G*.587+p.B*.114)/255.0;double f=.38+lum*.92,neutral=lum*42;int r=(int)Math.Min(255,c.R*f+neutral),gg=(int)Math.Min(255,c.G*f+neutral),b=(int)Math.Min(255,c.B*f+neutral);colored.SetPixel(x,y,Color.FromArgb(p.A,r,gg,b));}
      }else{using(var cg=Graphics.FromImage(colored)){cg.CompositingMode=CompositingMode.SourceCopy;cg.DrawImage(input,0,0,input.Width,input.Height);}}
      g.SmoothingMode=SmoothingMode.AntiAlias;g.InterpolationMode=InterpolationMode.HighQualityBicubic;g.CompositingQuality=CompositingQuality.HighQuality;g.Clear(Color.Transparent);
      var crop=AlphaBounds(colored);double scale=Math.Min(2280.0/crop.Width,1780.0/crop.Height);int w=(int)(crop.Width*scale),h=(int)(crop.Height*scale);g.DrawImage(colored,new Rectangle((2400-w)/2,(2400-h)/2,w,h),crop,GraphicsUnit.Pixel);
      var text=(material=="graphite" || (material=="firm" && baseHex!="#F7D629"))?Color.White:Color.FromArgb(242,20,25,29);
      BrandLayer(g,logo,bank,text,new[]{new PointF(390,760),new PointF(2070,842),new PointF(370,1320)});
      canvas.Save(masterPath,ImageFormat.Png);
    }
    Resize(masterPath,compactPath,256);
  }
  static Rectangle AlphaBounds(Bitmap b){int left=b.Width,top=b.Height,right=-1,bottom=-1;for(int y=0;y<b.Height;y+=2)for(int x=0;x<b.Width;x+=2)if(b.GetPixel(x,y).A>8){if(x<left)left=x;if(x>right)right=x;if(y<top)top=y;if(y>bottom)bottom=y;}if(right<left)return new Rectangle(0,0,b.Width,b.Height);left=Math.Max(0,left-8);top=Math.Max(0,top-8);right=Math.Min(b.Width-1,right+8);bottom=Math.Min(b.Height-1,bottom+8);return Rectangle.FromLTRB(left,top,right+1,bottom+1);}
  public static void ObjectMaster(string sourcePath,string masterPath){using(var input=new Bitmap(sourcePath))using(var canvas=new Bitmap(2400,2400,PixelFormat.Format32bppArgb))using(var g=Graphics.FromImage(canvas)){g.Clear(Color.Transparent);g.InterpolationMode=InterpolationMode.HighQualityBicubic;g.CompositingQuality=CompositingQuality.HighQuality;g.SmoothingMode=SmoothingMode.AntiAlias;var crop=AlphaBounds(input);double scale=Math.Min(2200.0/crop.Width,2200.0/crop.Height);int w=(int)(crop.Width*scale),h=(int)(crop.Height*scale);g.DrawImage(input,new Rectangle((2400-w)/2,(2400-h)/2,w,h),crop,GraphicsUnit.Pixel);canvas.Save(masterPath,ImageFormat.Png);}}
  public static void Account(string baseMaster,string logoPath,string bank,string kind,string masterPath,string compactPath){using(var input=new Bitmap(baseMaster))using(var logo=new Bitmap(logoPath))using(var canvas=new Bitmap(input))using(var g=Graphics.FromImage(canvas)){g.SmoothingMode=SmoothingMode.AntiAlias;g.InterpolationMode=InterpolationMode.HighQualityBicubic;g.CompositingQuality=CompositingQuality.HighQuality;
      PointF[] target=kind=="checking"?new[]{new PointF(260,930),new PointF(1370,880),new PointF(300,1420)}:kind=="deposit"?new[]{new PointF(870,640),new PointF(2070,690),new PointF(890,1160)}:new[]{new PointF(900,730),new PointF(2070,765),new PointF(920,1245)};
      var text=kind=="checking"?Color.White:Color.FromArgb(242,20,25,29);
      BrandLayer(g,logo,bank,text,target);canvas.Save(masterPath,ImageFormat.Png);}
    Resize(masterPath,compactPath,256);
  }
  public static void Resize(string source,string target,int size){using(var input=new Bitmap(source))using(var output=new Bitmap(size,size,PixelFormat.Format32bppArgb))using(var g=Graphics.FromImage(output)){g.Clear(Color.Transparent);g.InterpolationMode=InterpolationMode.HighQualityBicubic;g.CompositingMode=CompositingMode.SourceCopy;g.CompositingQuality=CompositingQuality.HighQuality;g.SmoothingMode=SmoothingMode.AntiAlias;g.DrawImage(input,new Rectangle(0,0,size,size));output.Save(target,ImageFormat.Png);}}
}
'@

$banks = @(
  @{slug='sber';id='bank_sber';name='Сбер';color='#086B50'},
  @{slug='alfa';id='bank_alfa';name='Альфа-Банк';color='#C71F2B'},
  @{slug='t';id='bank_t';name='Т-Банк / Тинькофф';color='#F7D629'},
  @{slug='bakai';id='bank_bakai';name='Бакай Банк';color='#68264D'},
  @{slug='kaspi';id='bank_kaspi';name='Kaspi';color='#D83A35'},
  @{slug='gpb';id='bank_gpb';name='Газпромбанк';color='#2354B8'},
  @{slug='rshb';id='bank_rshb';name='Россельхозбанк';color='#286B39'},
  @{slug='halyk';id='bank_halyk';name='Halyk';color='#00896F'},
  @{slug='bcc';id='bank_bcc';name='Банк ЦентрКредит';color='#16A25B'}
)
$variants = @(
  @{slug='green';name='firm';hex=$null},
  @{slug='graphite';name='graphite';hex='#2C3138'},
  @{slug='silver';name='silver';hex='#AEB7BE'},
  @{slug='gold';name='gold';hex='#B78A3C'}
)
foreach($bank in $banks){$logo=Join-Path $source "bank_logos_raster/$($bank.id).png";foreach($v in $variants){$id="card_$($bank.slug)_$($v.slug)";$hex=if($v.hex){$v.hex}else{$bank.color};$base=Join-Path $source "card_base_$($v.slug).png";[WalletHd]::Card($base,$logo,$bank.name,$hex,$v.name,(Join-Path $masters "$id.png"),(Join-Path $compact "$id.png"));[WalletHd]::Resize((Join-Path $masters "$id.png"),(Join-Path $assets "$id.png"),512);[WalletHd]::Resize((Join-Path $masters "$id.png"),(Join-Path $preview "$id.png"),640)}}

$walletIds=@('wallet_bifold_black','wallet_bifold_cognac','wallet_bifold_dark_brown','wallet_bifold_burgundy','wallet_bifold_navy','wallet_bifold_emerald','wallet_zip_black','wallet_zip_cognac','wallet_zip_dark_brown','wallet_zip_burgundy','wallet_zip_navy','wallet_zip_emerald')
foreach($id in $walletIds){[WalletHd]::ObjectMaster((Join-Path $source "$id.png"),(Join-Path $masters "$id.png"));[WalletHd]::Resize((Join-Path $masters "$id.png"),(Join-Path $compact "$id.png"),256);[WalletHd]::Resize((Join-Path $masters "$id.png"),(Join-Path $assets "$id.png"),512);[WalletHd]::Resize((Join-Path $masters "$id.png"),(Join-Path $preview "$id.png"),640)}

foreach($kind in @('checking','deposit','savings')){[WalletHd]::ObjectMaster((Join-Path $source "account_base_$kind.png"),(Join-Path $masters "account_base_$kind.png"))}
foreach($bank in $banks){$logo=Join-Path $source "bank_logos_raster/$($bank.id).png";foreach($kind in @('checking','deposit','savings')){$id="account_$($bank.slug)_$kind";[WalletHd]::Account((Join-Path $masters "account_base_$kind.png"),$logo,$bank.name,$kind,(Join-Path $masters "$id.png"),(Join-Path $compact "$id.png"));[WalletHd]::Resize((Join-Path $masters "$id.png"),(Join-Path $assets "$id.png"),512);[WalletHd]::Resize((Join-Path $masters "$id.png"),(Join-Path $preview "$id.png"),640)}}

# Personal first-run assets. These IDs are new; existing catalog IDs stay unchanged.
$cashIds=@('cash_kzt_photo','cash_usd_photo','cash_thb_photo','cash_egp_photo','cash_try_photo')
foreach($id in $cashIds){[WalletHd]::ObjectMaster((Join-Path $source "$id.png"),(Join-Path $masters "$id.png"));[WalletHd]::Resize((Join-Path $masters "$id.png"),(Join-Path $compact "$id.png"),256);[WalletHd]::Resize((Join-Path $masters "$id.png"),(Join-Path $assets "$id.png"),512);[WalletHd]::Resize((Join-Path $masters "$id.png"),(Join-Path $preview "$id.png"),640)}

$sberLogo=Join-Path $source 'bank_logos_raster/bank_sber.png'
[WalletHd]::Card((Join-Path $source 'card_base_green.png'),$sberLogo,'Сбер Бизнес','#123E66','firm',(Join-Path $masters 'card_sber_business.png'),(Join-Path $compact 'card_sber_business.png'))
[WalletHd]::Resize((Join-Path $masters 'card_sber_business.png'),(Join-Path $assets 'card_sber_business.png'),512)
[WalletHd]::Resize((Join-Path $masters 'card_sber_business.png'),(Join-Path $preview 'card_sber_business.png'),640)
[WalletHd]::Account((Join-Path $masters 'account_base_savings.png'),$sberLogo,'Сбер Спасибо','savings',(Join-Path $masters 'reward_sber_spasibo.png'),(Join-Path $compact 'reward_sber_spasibo.png'))
[WalletHd]::Resize((Join-Path $masters 'reward_sber_spasibo.png'),(Join-Path $assets 'reward_sber_spasibo.png'),512)
[WalletHd]::Resize((Join-Path $masters 'reward_sber_spasibo.png'),(Join-Path $preview 'reward_sber_spasibo.png'),640)
[WalletHd]::ObjectMaster((Join-Path $source 'cashbox_office_photo.png'),(Join-Path $masters 'cashbox_office_photo.png'))
[WalletHd]::Resize((Join-Path $masters 'cashbox_office_photo.png'),(Join-Path $compact 'cashbox_office_photo.png'),256)
[WalletHd]::Resize((Join-Path $masters 'cashbox_office_photo.png'),(Join-Path $assets 'cashbox_office_photo.png'),512)
[WalletHd]::Resize((Join-Path $masters 'cashbox_office_photo.png'),(Join-Path $preview 'cashbox_office_photo.png'),640)

$extraIds=@('safe_steel_photo','safe_black_photo','cashbox_home_photo','banknotes_stack_photo','coins_photo','bank_cell_photo')
foreach($id in $extraIds){[WalletHd]::ObjectMaster((Join-Path $source "$id.png"),(Join-Path $masters "$id.png"));[WalletHd]::Resize((Join-Path $masters "$id.png"),(Join-Path $compact "$id.png"),256);[WalletHd]::Resize((Join-Path $masters "$id.png"),(Join-Path $assets "$id.png"),512);[WalletHd]::Resize((Join-Path $masters "$id.png"),(Join-Path $preview "$id.png"),640)}

$registryPath=Join-Path $assets 'registry.json';$rows=Get-Content -LiteralPath $registryPath -Raw -Encoding utf8|ConvertFrom-Json
$newRows=@(
  @{icon_id='cash_kzt_photo';name='Наличные тенге';group='Сейфы и наличные';bank='';kind='Наличные';synonyms='KZT тенге Казахстан наличные купюры'},
  @{icon_id='cash_usd_photo';name='Наличные доллары';group='Сейфы и наличные';bank='';kind='Наличные';synonyms='USD доллары США наличные купюры'},
  @{icon_id='cash_thb_photo';name='Наличные тайские баты';group='Сейфы и наличные';bank='';kind='Наличные';synonyms='THB тайский бат Таиланд наличные'},
  @{icon_id='cash_egp_photo';name='Наличные египетские фунты';group='Сейфы и наличные';bank='';kind='Наличные';synonyms='EGP египетский фунт Египет наличные'},
  @{icon_id='cash_try_photo';name='Наличные турецкие лиры';group='Сейфы и наличные';bank='';kind='Наличные';synonyms='TRY турецкая лира Турция наличные'},
  @{icon_id='card_sber_business';name='Сбер — бизнес-карта';group='Карты';bank='Сбер';kind='Карта';synonyms='Сбер бизнес карта ИП корпоративная'},
  @{icon_id='reward_sber_spasibo';name='Сбер Спасибо';group='Счета и депозиты';bank='Сбер';kind='Накопительный счёт';synonyms='Сбер Спасибо бонусы вознаграждения'},
  @{icon_id='cashbox_office_photo';name='Офисная касса';group='Сейфы и наличные';bank='';kind='Наличные';synonyms='офис касса деньги бизнес'}
)
foreach($item in $newRows){if(!($rows|Where-Object icon_id -eq $item.icon_id)){$rows+= [pscustomobject]@{icon_id=$item.icon_id;name=$item.name;group=$item.group;bank=$item.bank;kind=$item.kind;asset="assets/wallet_photoreal/$($item.icon_id).png";source="source_assets/wallet_photoreal/master/$($item.icon_id).png";synonyms=$item.synonyms;method='';source_width=2400;source_height=2400;width=512;height=512;sha256=''}}}
foreach($row in $rows){if($row.asset -like 'assets/wallet_photoreal/*'){$id=$row.icon_id;$row.source="source_assets/wallet_photoreal/master/$id.png";$row.source_width=2400;$row.source_height=2400;$row.width=512;$row.height=512;$row.sha256=(Get-FileHash (Join-Path $assets "$id.png") -Algorithm SHA256).Hash.ToLowerInvariant();$row|Add-Member compact_asset "assets/wallet_photoreal/compact/$id.png" -Force;$row|Add-Member compact_width 256 -Force;$row|Add-Member compact_height 256 -Force;$row|Add-Member preview_asset "assets/wallet_photoreal/preview/$id.png" -Force;$row|Add-Member preview_width 640 -Force;$row|Add-Member preview_height 640 -Force;if($id -like 'card_*'){$row.method='2400px rebuilt composition from approved 1254px photoreal material base + accepted exact bank logo; size-specific outputs';if($id -like 'card_*_green'){$row.name=$row.name -replace 'зелёная карта','фирменная карта'}}elseif($id -like 'account_*'){$row.method='2400px rebuilt finance composition + large accepted exact bank logo; trimmed and size-specific outputs'}else{$row.method='2400px rebuilt master from generated source with alpha-bound trimming, scale normalization and size-specific outputs'}}}
$utf8=[Text.UTF8Encoding]::new($false);[IO.File]::WriteAllText($registryPath,($rows|ConvertTo-Json -Depth 6),$utf8)
Write-Host 'Rebuilt wallet assets: 2400 masters, 256 compact, 512 catalog, 640 preview; transparent branding without white plaques.'
