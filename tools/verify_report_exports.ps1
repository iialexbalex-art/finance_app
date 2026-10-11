param([string]$ArtifactDirectory = 'build/reports_qa')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$artifactPath = (Resolve-Path -LiteralPath $ArtifactDirectory).Path
$zip = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $artifactPath 'controlled_report.xlsx'))
try {
  $documents = @{}
  foreach ($entry in $zip.Entries) {
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try { $documents[$entry.FullName] = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
  }
  $ns = [System.Xml.XmlNamespaceManager]::new($documents['xl/workbook.xml'].NameTable)
  $ns.AddNamespace('s', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
  $sheetNames = @($documents['xl/workbook.xml'].SelectNodes('//s:sheet', $ns) | ForEach-Object { $_.name })
  if (($sheetNames -join ',') -ne 'Сводка,Операции,Параметры') { throw 'Unexpected workbook sheets' }
  foreach ($doc in $documents.Values) {
    if ($doc.SelectNodes('//s:f', $ns).Count -ne 0) { throw 'Unexpected executable formula' }
  }
  $operations = $documents['xl/worksheets/sheet2.xml']
  $rows = @($operations.SelectNodes('//s:row', $ns) | Select-Object -Skip 1)
  if ($rows.Count -ne 7) { throw 'Export lost operations' }
  $xlsxSums = @{}
  foreach ($row in $rows) {
    $n = $row.r
    $date = $row.SelectSingleNode("s:c[@r='A$n']", $ns)
    $amount = $row.SelectSingleNode("s:c[@r='F$n']", $ns)
    if ($date.s -ne '1' -or $date.t -eq 'inlineStr') { throw 'Date is not an Excel date cell' }
    if ($amount.t -eq 'inlineStr') { throw 'Amount is not numeric' }
    $currency = $row.SelectSingleNode("s:c[@r='G$n']/s:is/s:t", $ns).InnerText
    $period = $row.SelectSingleNode("s:c[@r='J$n']/s:is/s:t", $ns).InnerText
    $key = "$period/$currency"
    $xlsxSums[$key] += [decimal]::Parse($amount.SelectSingleNode('s:v', $ns).InnerText, [cultureinfo]::InvariantCulture)
  }
  if ($xlsxSums['A/RUB'] -ne [decimal]5.20 -or $xlsxSums['B/RUB'] -ne [decimal]1 -or $xlsxSums['A/USD'] -ne [decimal]1.23) { throw 'Operation sums do not match controlled dataset' }
  $summary = $documents['xl/worksheets/sheet1.xml']
  $summaryChecks = 0
  foreach ($row in $summary.SelectNodes('//s:row', $ns)) {
    $n = $row.r
    $name = $row.SelectSingleNode("s:c[@r='A$n']/s:is/s:t", $ns).InnerText
    if ($name -eq 'Период A' -or $name -eq 'Период B') {
      $currency = $row.SelectSingleNode("s:c[@r='B$n']/s:is/s:t", $ns).InnerText
      $amount = [decimal]::Parse($row.SelectSingleNode("s:c[@r='D$n']/s:v", $ns).InnerText, [cultureinfo]::InvariantCulture)
      $key = "$(if ($name -eq 'Период A') { 'A' } else { 'B' })/$currency"
      if ($amount -ne $xlsxSums[$key]) { throw 'Summary and operation amounts differ' }
      $summaryChecks++
    }
  }
  $lines = @(Get-Content -LiteralPath (Join-Path $artifactPath 'controlled_report.csv') -Encoding UTF8)
  $index = [Array]::IndexOf($lines, '"Операции"')
  if ($index -lt 0) { throw 'CSV operation section missing' }
  $csvRows = @($lines[($index + 1)..($lines.Count - 1)] | ConvertFrom-Csv -Delimiter ';')
  if ($csvRows.Count -ne $rows.Count) { throw 'CSV and XLSX row counts differ' }
  $csvSums = @{}
  foreach ($row in $csvRows) {
    $key = "$($row.'Периоды / группы')/$($row.Валюта)"
    $csvSums[$key] += [decimal]::Parse($row.Сумма, [cultureinfo]::InvariantCulture)
    if ($row.ID -eq 'formula' -and -not $row.Комментарий.StartsWith("'=")) { throw 'CSV formula is unprotected' }
  }
  foreach ($key in $xlsxSums.Keys) { if ($csvSums[$key] -ne $xlsxSums[$key]) { throw 'CSV and XLSX amounts differ' } }
  $result = [ordered]@{status='passed'; dataset='controlled test data'; sheets=$sheetNames; operations=$rows.Count; summaryChecks=$summaryChecks; operationSums=$xlsxSums; numericAmounts=$true; excelDates=$true; noExecutableFormulas=$true; csvMatchesXlsx=$true}
  $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $artifactPath 'export_verification.json') -Encoding UTF8
  $result | ConvertTo-Json -Depth 5
} finally { $zip.Dispose() }
