param([switch]$SkipContactSheets)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$registryPath = Join-Path $root 'assets/category_photoreal/category_set_registry.psv'
$rows = @(Import-Csv -Delimiter '|' -LiteralPath $registryPath)
if ($rows.Count -ne 146) { throw "Expected 146 registry rows, got $($rows.Count)" }
if (@($rows | Group-Object icon_id | Where-Object Count -ne 1).Count) { throw 'Duplicate icon_id' }
if (@($rows | Group-Object kind,set_key | Where-Object Count -ne 1).Count) { throw 'Duplicate kind/set_key' }
$utf8 = [Text.UTF8Encoding]::new($false)
function Q([string]$value) { return $value.Replace("'", "''") }

# Dart catalog consumed by the application. The original legacy catalog remains
# available only as a resolver fallback for already stored icon IDs.
$dart = [Text.StringBuilder]::new()
[void]$dart.AppendLine("import 'icon_catalog.dart';")
[void]$dart.AppendLine("import 'category_tree_icon_catalog.dart';")
[void]$dart.AppendLine()
[void]$dart.AppendLine('// Generated from assets/category_photoreal/category_set_registry.psv.')
[void]$dart.AppendLine('const photorealCategoryIconCatalog = <WalletIconChoice>[')
[void]$dart.AppendLine('  ...categoryTreeIconCatalog,')
foreach ($r in $rows) {
  [void]$dart.AppendLine('  WalletIconChoice(')
  [void]$dart.AppendLine("    '$(Q $r.icon_id)',")
  [void]$dart.AppendLine("    '$(Q $r.name)',")
  [void]$dart.AppendLine("    '$(Q $r.group)',")
  [void]$dart.AppendLine("    'assets/category_photoreal/$(Q $r.icon_id).png',")
  [void]$dart.AppendLine("    '$(Q $r.keywords)',")
  [void]$dart.AppendLine('  ),')
}
[void]$dart.AppendLine('];')
[IO.File]::WriteAllText((Join-Path $root 'lib/photoreal_icon_catalog.dart'),$dart.ToString(),$utf8)

# Auditable machine-readable registry with actual dimensions and hashes.
Add-Type -AssemblyName System.Drawing
$manifest = foreach ($r in $rows) {
  $source = Join-Path $root "source_assets/category_photoreal/$($r.icon_id).png"
  $asset = Join-Path $root "assets/category_photoreal/$($r.icon_id).png"
  if (!(Test-Path $source) -or !(Test-Path $asset)) { throw "Missing image: $($r.icon_id)" }
  $si = [Drawing.Image]::FromFile($source); $ai = [Drawing.Image]::FromFile($asset)
  try {
    [ordered]@{kind=$r.kind;order=[int]$r.order;name=$r.name;set_key=$r.set_key;icon_id=$r.icon_id;group=$r.group;keywords=$r.keywords;interpretation=$r.interpretation;subject=$r.subject;source="source_assets/category_photoreal/$($r.icon_id).png";asset="assets/category_photoreal/$($r.icon_id).png";source_width=$si.Width;source_height=$si.Height;asset_width=$ai.Width;asset_height=$ai.Height;source_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant();asset_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $asset).Hash.ToLowerInvariant();provenance='OpenAI built-in image generation; project-specific prompt; 2026-10-01'}
  } finally { $si.Dispose(); $ai.Dispose() }
}
[IO.File]::WriteAllText((Join-Path $root 'assets/category_photoreal/registry.json'),($manifest | ConvertTo-Json -Depth 5),$utf8)

# SQL migration: immutable set registry plus postgres-only, idempotent installer.
$values = ($rows | ForEach-Object { "  ('category_set_2026_10_01','$(Q $_.set_key)','$(Q $_.kind)',$($_.order),'$(Q $_.name)','$(Q $_.icon_id)')" }) -join ",`n"
$migration = @"
-- Prepared after 001-011. Run once as postgres. The application never calls this installer.
begin;
do `$migration`$ begin
  if current_user <> 'postgres' then raise exception 'Run migration as postgres'; end if;
end `$migration`$;

create table finance_private.category_set_items (
  set_version text not null,
  set_key text not null,
  kind text not null check(kind in ('expense','income')),
  display_order integer not null check(display_order > 0),
  name text not null check(char_length(btrim(name)) between 1 and 100),
  icon_id text not null check(icon_id ~ '^[a-z][a-z0-9_]{0,47}$'),
  primary key(set_version,set_key),
  unique(set_version,kind,display_order),
  unique(set_version,icon_id)
);
revoke all on finance_private.category_set_items from public,anon,authenticated;

insert into finance_private.category_set_items(set_version,set_key,kind,display_order,name,icon_id) values
$values;

create table finance_private.category_set_imports (
  space_id uuid not null references public.spaces(id) on delete cascade,
  set_version text not null,
  set_key text not null,
  kind text not null check(kind in ('expense','income')),
  original_name text not null,
  category_id uuid,
  resolution text not null check(resolution in ('created','reused')),
  imported_at timestamptz not null default now(),
  primary key(space_id,set_version,set_key)
);
revoke all on finance_private.category_set_imports from public,anon,authenticated;

create function finance_private.install_category_set_2026_10_01(p_space_id uuid)
returns jsonb language plpgsql volatile security invoker set search_path='' as `$function`$
declare
  item finance_private.category_set_items%rowtype;
  matched uuid[]; chosen uuid; created_count integer:=0; reused_count integer:=0;
  skipped_count integer:=0; ambiguous_count integer:=0; archived_conflict_count integer:=0;
  ambiguities jsonb:='[]'::jsonb; conflicts jsonb:='[]'::jsonb; archive_details jsonb;
begin
  if current_user <> 'postgres' then raise exception using errcode='42501',message='Run installer as postgres'; end if;
  if p_space_id is null then raise exception using errcode='22004',message='Target space UUID is required'; end if;
  perform 1 from public.spaces where id=p_space_id for update;
  if not found then raise exception using errcode='P0002',message='Target space not found'; end if;
  for item in select * from finance_private.category_set_items where set_version='category_set_2026_10_01' order by kind,display_order loop
    if exists(select 1 from finance_private.category_set_imports i where i.space_id=p_space_id and i.set_version=item.set_version and i.set_key=item.set_key) then
      skipped_count:=skipped_count+1; continue;
    end if;
    select coalesce(array_agg(c.id order by c.created_at,c.id),'{}'::uuid[]) into matched
    from public.categories c where c.space_id=p_space_id and c.kind=item.kind
      and lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g'))=lower(regexp_replace(btrim(item.name),'[[:space:]]+',' ','g'));
    -- A matching category is reusable only when both it and every ancestor are
    -- active. Archived matches remain unresolved so a later run can reuse them
    -- after the user explicitly resolves the archive conflict.
    with recursive ancestry(match_id,id,parent_id,is_archived) as (
      select c.id,c.id,c.parent_id,c.is_archived from public.categories c where c.id=any(matched)
      union all
      select a.match_id,p.id,p.parent_id,p.is_archived from ancestry a
      join public.categories p on p.id=a.parent_id
    ), archived as (
      select match_id,array_agg(id order by id) filter(where is_archived) archived_ids
      from ancestry group by match_id having bool_or(is_archived)
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'category_id',match_id,
      'reason',case when match_id=any(archived_ids) then 'category_archived' else 'archived_ancestor' end,
      'archived_category_ids',to_jsonb(archived_ids)
    ) order by match_id),'[]'::jsonb) into archive_details from archived;
    if jsonb_array_length(archive_details)>0 then
      archived_conflict_count:=archived_conflict_count+1;
      conflicts:=conflicts||jsonb_build_array(jsonb_build_object('set_key',item.set_key,'kind',item.kind,'name',item.name,'reason','archived_match','matches',archive_details));
      continue;
    elsif cardinality(matched)>1 then
      ambiguous_count:=ambiguous_count+1;
      ambiguities:=ambiguities||jsonb_build_array(jsonb_build_object('set_key',item.set_key,'kind',item.kind,'name',item.name,'category_ids',to_jsonb(matched)));
      continue;
    elsif cardinality(matched)=1 then
      chosen:=matched[1]; reused_count:=reused_count+1;
      insert into finance_private.category_set_imports(space_id,set_version,set_key,kind,original_name,category_id,resolution)
      values(p_space_id,item.set_version,item.set_key,item.kind,item.name,chosen,'reused');
    else
      insert into public.categories(space_id,kind,name,parent_id,icon_id) values(p_space_id,item.kind,item.name,null,item.icon_id) returning id into chosen;
      created_count:=created_count+1;
      insert into finance_private.category_set_imports(space_id,set_version,set_key,kind,original_name,category_id,resolution)
      values(p_space_id,item.set_version,item.set_key,item.kind,item.name,chosen,'created');
    end if;
  end loop;
  return jsonb_build_object('space_id',p_space_id,'set_version','category_set_2026_10_01','created',created_count,'reused',reused_count,'skipped',skipped_count,'ambiguous',ambiguous_count,'ambiguities',ambiguities,'archived_conflicts',archived_conflict_count,'conflicts',conflicts);
end `$function`$;
revoke all on function finance_private.install_category_set_2026_10_01(uuid) from public,anon,authenticated;
comment on function finance_private.install_category_set_2026_10_01(uuid) is 'Postgres-only explicit-space category installer. Ledger prevents deleted entries or later user edits being restored.';
commit;
"@
[IO.File]::WriteAllText((Join-Path $root 'supabase/migrations/202610010012_category_set.sql'),$migration,$utf8)

if (!$SkipContactSheets) {
  $qa = Join-Path $root 'build/qa'; New-Item -ItemType Directory -Force $qa | Out-Null
  foreach ($kind in 'expense','income') {
    $part = @($rows | Where-Object kind -eq $kind | Sort-Object {[int]$_.order})
    $cols = if($kind -eq 'expense'){5}else{4}; $cellW=220; $cellH=170
    $sheet=[Drawing.Bitmap]::new($cols*$cellW,[math]::Ceiling($part.Count/$cols)*$cellH,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g=[Drawing.Graphics]::FromImage($sheet); $g.Clear([Drawing.Color]::FromArgb(246,249,247)); $g.TextRenderingHint=[Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $font=[Drawing.Font]::new('Arial',10); $brush=[Drawing.Brushes]::Black
    try { for($i=0;$i-lt $part.Count;$i++){ $x=($i%$cols)*$cellW; $y=[math]::Floor($i/$cols)*$cellH; $im=[Drawing.Image]::FromFile((Join-Path $root "assets/category_photoreal/$($part[$i].icon_id).png")); try{$g.DrawImage($im,$x+48,$y+4,124,124)}finally{$im.Dispose()}; $fmt=[Drawing.StringFormat]::new();$fmt.Alignment='Center';$fmt.Trimming='EllipsisCharacter';$g.DrawString($part[$i].name,$font,$brush,[Drawing.RectangleF]::new($x+5,$y+132,$cellW-10,34),$fmt);$fmt.Dispose() } }
    finally { $font.Dispose();$g.Dispose() }
    $sheet.Save((Join-Path $qa "category-set-$kind-contact-sheet.png"),[Drawing.Imaging.ImageFormat]::Png);$sheet.Dispose()
  }
}
Write-Host "Generated catalog, registry and migration for $($rows.Count) categories$(if($SkipContactSheets){'.'}else{' plus contact sheets.'})"
