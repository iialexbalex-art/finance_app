"""Generate a private browser read-only inventory, not an atomic database backup."""
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
config = json.loads((ROOT/'config/local.json').read_text(encoding='utf-8-sig'))
script = r"""(async()=>{
 const url=PROJECT_URL,key=PUBLISHABLE;
 const ref=new URL(url).hostname.split('.')[0];
 const session=JSON.parse(localStorage.getItem('sb-'+ref+'-auth-token'));
 if(!session)throw Error('No current authorized session');
 const headers={apikey:key,Authorization:'Bearer '+session.access_token};
 async function rows(table,select,filter=''){
  const all=[];
  for(let offset=0;;offset+=500){
   const res=await fetch(url+'/rest/v1/'+table+'?select='+select+'&order='+
    (table==='wallet_opening_balances'?'wallet_id':'id')+'&offset='+offset+'&limit=500'+filter,{headers});
   if(!res.ok)throw Error('Inventory failed: '+table+' '+res.status);
   const page=await res.json();all.push(...page);if(page.length<500)return all;
  }
 }
 const spaces=(await rows('spaces','*')).filter(x=>x.owner_user_id===session.user.id);
 const filter='&space_id=in.('+spaces.map(s=>s.id).join(',')+')';
 const data={spaces};
 for(const [table,select] of [['wallets','*'],['categories','*'],['expenses','*,amount_minor::text'],['incomes','*,amount_minor::text'],['transfers','*,source_minor::text,target_minor::text,fee_minor::text']])data[table]=await rows(table,select,filter);
 const ids=data.wallets.map(w=>w.id);
 data.wallet_opening_balances=ids.length?await rows('wallet_opening_balances','*,amount_minor::text','&wallet_id=in.('+ids.join(',')+')'):[];
 const probe=await fetch(url+'/rest/v1/finance_settings?select=owner_id&limit=0',{headers});
 const buckets=await fetch(url+'/storage/v1/bucket',{headers});
 return JSON.stringify({kind:'read-only inventory; not a coherent backup',captured_at:new Date().toISOString(),
  project_ref:ref,counts:Object.fromEntries(Object.entries(data).map(([k,v])=>[k,v.length])),
  json_bytes:new TextEncoder().encode(JSON.stringify(data)).length,backup_schema_status:probe.status,
  storage_inventory_status:buckets.status,storage_buckets:buckets.ok?(await buckets.json()).map(x=>({id:x.id,public:x.public})):null});
})()
""".replace('PROJECT_URL',json.dumps(config['SUPABASE_URL'])).replace('PUBLISHABLE',json.dumps(config['SUPABASE_PUBLISHABLE_KEY']))
folder=ROOT/'.local-backups'/'backups-task'
folder.mkdir(parents=True,exist_ok=True)
(folder/'inventory.js').write_text(script,encoding='utf-8')
print('Private read-only inventory script prepared')
