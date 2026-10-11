$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http
$root = Split-Path $PSScriptRoot
$commit = '1ffb34c752ecf5d402f04cfb4b392c77f57c54bc'
if (!(Test-Path "$root/build/icon-sources/fluent-tree.json")) {
  New-Item -ItemType Directory -Force "$root/build/icon-sources" | Out-Null
  Invoke-WebRequest "https://api.github.com/repos/microsoft/fluentui-emoji/git/trees/${commit}?recursive=1" -UseBasicParsing -OutFile "$root/build/icon-sources/fluent-tree.json"
}
$tree = Get-Content "$root/build/icon-sources/fluent-tree.json" -Raw -Encoding UTF8 | ConvertFrom-Json
if ($tree.sha -ne $commit) { throw 'Unexpected source revision' }
$seeds = Import-Csv "$PSScriptRoot/icon-seeds.csv" -Delimiter '|' -Encoding UTF8
$client = [Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(40)
$jobs = @()
foreach ($seed in $seeds) {
  $prefix = "assets/$($seed.source)/"
  $paths = @($tree.tree | Where-Object { $_.path.StartsWith($prefix) -and $_.path -match '/Flat/[^/]+\.svg$' })
  if ($paths.Count -gt 1) { $paths = @($paths | Where-Object { $_.path -match '/Default/' }) }
  if ($paths.Count -ne 1) { throw "Ambiguous/missing source: $($seed.source): $($paths.Count)" }
  $url = "https://raw.githubusercontent.com/microsoft/fluentui-emoji/$($tree.sha)/" + (($paths[0].path.Split('/') | ForEach-Object {[Uri]::EscapeDataString($_)}) -join '/')
  $jobs += @{seed=$seed; url=$url; task=$client.GetByteArrayAsync($url)}
}
$manifest = foreach ($job in $jobs) {
  $bytes = $job.task.GetAwaiter().GetResult()
  $file = "assets/icons/$($job.seed.id).svg"
  [IO.File]::WriteAllBytes("$root/$file", $bytes)
  [ordered]@{id=$job.seed.id; label=$job.seed.label; group=$job.seed.group; synonyms=$job.seed.synonyms; asset=$file; source=$job.url; license='MIT'; sha256=(Get-FileHash "$root/$file" -Algorithm SHA256).Hash.ToLower()}
}
[IO.File]::WriteAllText("$root/assets/icons/catalog.json", ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
$license = $client.GetStringAsync("https://raw.githubusercontent.com/microsoft/fluentui-emoji/$($tree.sha)/LICENSE").GetAwaiter().GetResult()
[IO.File]::WriteAllText("$root/assets/licenses/Fluent-Emoji-LICENSE.txt",$license,[Text.UTF8Encoding]::new($false))
"Downloaded $($manifest.Count) distinct Fluent assets at $($tree.sha)"
