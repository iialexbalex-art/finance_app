$ErrorActionPreference = 'Stop'
$projectConfig = Get-Content "$PSScriptRoot/../config/local.json" -Raw | ConvertFrom-Json
$projectUrl = $projectConfig.SUPABASE_URL
$publicKey = $projectConfig.SUPABASE_PUBLISHABLE_KEY
if (!$publicKey) { throw 'Missing publishable key' }
$snapshotScript = @'
(async () => {
  const session = JSON.parse(localStorage.getItem('sb-bgyuxibywuxdultxsmiv-auth-token'));
  if (!session) throw Error('Sign in first');
  const headers = {apikey: PUBLIC_KEY, Authorization: 'Bearer ' + session.access_token};
  async function rows(table, columns) {
    const result = [];
    for (let offset = 0; ; offset += 500) {
      const response = await fetch(PROJECT_URL + '/rest/v1/' + table + '?select=' + columns + '&order=id&offset=' + offset + '&limit=500', {headers});
      if (!response.ok) throw Error(table + ': ' + response.status + ' ' + await response.text());
      const page = await response.json(); result.push(...page);
      if (page.length < 500) return result;
    }
  }
  const spaces = await rows('spaces', '*');
  const business = spaces.filter(s => s.kind === 'business' && s.owner_user_id === session.user.id);
  if (business.length !== 1) throw Error('Ambiguous business spaces: ' + JSON.stringify(business));
  const categories = await rows('categories', '*');
  const expenses = await rows('expenses', '*,amount_minor::text');
  const incomes = await rows('incomes', '*,amount_minor::text');
  const transfers = await rows('transfers', '*,source_minor::text,target_minor::text,fee_minor::text');
  const wallets = await rows('wallets', '*');
  const openingResponse = await fetch(PROJECT_URL + '/rest/v1/wallet_opening_balances?select=wallet_id,amount_minor::text', {headers});
  if (!openingResponse.ok) throw Error('Opening balances: ' + openingResponse.status);
  const storage = Object.fromEntries(Object.keys(localStorage).filter(k => !k.includes('auth-token')).map(k => [k, localStorage.getItem(k)]));
  return JSON.stringify({captured_at: new Date().toISOString(), space_id:business[0].id, spaces,categories,expenses,incomes,transfers,wallets,opening_balances:await openingResponse.json(),local_storage:storage});
})()
'@
$snapshotScript = $snapshotScript.Replace('PUBLIC_KEY', ($publicKey | ConvertTo-Json -Compress)).Replace('PROJECT_URL', ($projectUrl | ConvertTo-Json -Compress))
$privateDir = "$PSScriptRoot/../.local-backups/business-expenses"
New-Item -ItemType Directory -Path $privateDir -Force | Out-Null
$snapshotScript | browser-act --session business-expenses-install eval --stdin | Set-Content -Encoding UTF8 "$privateDir/snapshot-browser.txt"
if ($LASTEXITCODE -ne 0) { throw 'Snapshot failed; inspect snapshot-browser.txt' }
$snapshotCheck = Get-Content "$privateDir/snapshot-browser.txt" -Encoding UTF8 -Raw | ConvertFrom-Json
if (!$snapshotCheck.space_id) { throw 'Incomplete snapshot' }
Write-Output "Snapshot saved in $privateDir/snapshot-browser.txt"

