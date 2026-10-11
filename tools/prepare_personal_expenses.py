"""Prepare original assets and an explicit, snapshot-checked personal import.

No database writes. Matching reserves whole paths before distributing empty,
generic leaf records. The report records every decision; no fuzzy matching.
"""
import csv
import hashlib
import json
import re
import shutil
import struct
import uuid
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / 'design/personal-expenses-pack'
PRIVATE = ROOT / '.local-backups/personal-expenses'
PACKAGE = 'personal_expenses_20261006_v1'


def norm(s):
    return re.sub(r'\s+', ' ', re.sub('[‐‑‒–—−]', '-', s.lower().replace('ё', 'е'))).strip()


def dart(s):
    return json.dumps(s, ensure_ascii=False).replace('$', r'\$')


def sql(s):
    return 'null' if s is None else "'" + str(s).replace("'", "''") + "'"


def match_categories(items, cats, refs):
    by_id = {c["id"]: c for c in cats}
    children = Counter(c["parent_id"] for c in cats)
    def path(c):
        return (path(by_id[c["parent_id"]]) + " / " if c["parent_id"] else "") + c["name"]
    # User-created names that clearly identify an existing branch, not fuzzy matches.
    contextual = {
        'sasha': ['Лично Саша'], 'jaecoo': ['Jaecoo'],
        'education': ['Обучение'], 'loans': ['Кредит'],
        'entertainment-cafe': ['Развлечения / Кафе / ресторан'],
        'natasha-cosmetics': ['Наташа лично / Косметика Наташа'],
        'home-utilities': ['Дом / Коммунальные услуги Дом Ижевск'],
    }
    matches, reserved, conflicts = {}, set(), []
    keys = {c['key']: c for c in items}
    def paths(c):
        names = [c['name']] + c['aliases']
        if c['parent_key']:
            return [p + ' / ' + n for p in paths(keys[c['parent_key']]) for n in names] + contextual.get(c['key'], [])
        return names + contextual.get(c['key'], [])
    # Reserve every exact/contextual full-path match before assigning generic rows.
    for c in items:
        candidates = [x for x in cats if norm(path(x)) in {norm(p) for p in paths(c)}]
        if len(candidates) > 1:
            conflicts.append({'key': c['key'], 'candidates': [x['id'] for x in candidates], 'reason': 'multiple full-path matches'})
        elif candidates:
            old = candidates[0]
            assert old['id'] not in reserved
            matches[c['key']] = (old, 'normalized full path / explicit contextual alias')
            reserved.add(old['id'])
    # Only empty unqualified generic roots may be distributed across people/cars.
    for c in items:
        if c['key'] in matches:
            continue
        names = {norm(n) for n in [c['name']] + c['aliases']}
        candidates = [x for x in cats if x['id'] not in reserved and x['parent_id'] is None and norm(x['name']) in names]
        if len(candidates) > 1 or any(refs[x['id']] or children[x['id']] for x in candidates):
            conflicts.append({'key': c['key'], 'candidates': [x['id'] for x in candidates], 'reason': 'generic category with history/subtree or multiple candidates'})
        elif candidates:
            old = candidates[0]
            matches[c['key']] = (old, 'empty generic root; first free compatible catalog branch after exact reservations')
            reserved.add(old['id'])
    return matches, conflicts


def prepare():
    catalog = json.loads((PACK / 'catalog.json').read_text(encoding='utf-8-sig'))
    items = catalog['categories']
    manifest = json.loads((PACK / 'asset-manifest.json').read_text(encoding='utf-8-sig'))
    assert len(items) == 143 and sum(c['parent_key'] is None for c in items) == 16
    assert len({c['key'] for c in items}) == 143 and len(manifest) == 101
    registry = {}
    for filename in ['photoreal_icon_catalog.dart', 'business_expense_catalog.dart',
                     'category_tree_icon_catalog.dart', 'wallet_photo_catalog.dart', 'bank_icons_hq_catalog.dart']:
        text = (ROOT / 'lib' / filename).read_text(encoding='utf-8')
        for match in re.finditer(r"WalletIconChoice\(\s*['\"]([^'\"]+)['\"],\s*['\"][^'\"]*['\"],\s*['\"][^'\"]*['\"],\s*['\"]([^'\"]+\.png)['\"]", text):
            registry.setdefault(match[2], match[1])
    hashes = {}
    for path, icon in registry.items():
        hashes.setdefault(hashlib.sha256((ROOT / path).read_bytes()).hexdigest(), (path, icon))
    destination = ROOT / 'assets/personal_expenses'
    destination.mkdir(exist_ok=True)
    images = {}
    choices = []
    imported = reused = 0
    category_registry_paths = set()
    for filename in ['photoreal_icon_catalog.dart', 'business_expense_catalog.dart', 'category_tree_icon_catalog.dart']:
        category_registry_paths.update(re.findall(r"['\"](assets/[^'\"]+\.png)['\"]", (ROOT / 'lib' / filename).read_text(encoding='utf-8')))
    for asset in manifest:
        binary = (PACK / asset['file']).read_bytes()
        assert hashlib.sha256(binary).hexdigest() == asset['sha256']
        assert binary[:8] == b'\x89PNG\r\n\x1a\n'
        assert list(struct.unpack('>II', binary[16:24])) == asset['size_px']
        assert (binary[25] in (4, 6) or (binary[25] == 3 and b'tRNS' in binary)) and asset['alpha_range'][0] == 0 and asset['alpha_range'][1] >= 254
        found = hashes.get(asset['sha256'])
        if found:
            path, icon = found
            reused += 1
        else:
            path = 'assets/personal_expenses/' + Path(asset['file']).name
            icon = 'personal_' + asset['key'].replace('-', '_')
            shutil.copyfile(PACK / asset['file'], ROOT / path)
            imported += 1
        if path not in category_registry_paths:
            # A wallet can share the binary; category choices register it once.
            choices.append((icon, asset['label'], 'Личные расходы', path, asset['key']))
            category_registry_paths.add(path)
        images[asset['key']] = {**asset, 'icon_id': icon, 'runtime_asset': path}
    lines = ["// Generated by tools/prepare_personal_expenses.py. Original RGBA assets.",
             "import 'icon_catalog.dart';", "import 'category.dart';", '',
             'const personalExpenseIconCatalog = <WalletIconChoice>[']
    for choice in choices:
        lines.append('  WalletIconChoice(%s),' % ', '.join(map(dart, choice)))
    lines += ['];', '', '// QA only. No startup seeding or database writes.',
              'List<FinanceCategory> personalExpenseFixtures(String spaceId) => [']
    for c in items:
        lines.append('  FinanceCategory(id: %s, spaceId: spaceId, kind: CategoryKind.expense, name: %s, parentId: %s, iconId: %s, sortOrder: %d),' % (
            dart(c['key']), dart(c['name']), dart(c['parent_key']) if c['parent_key'] else 'null',
            dart(images[c['asset_key']]['icon_id']), c['sort_order']))
    lines += ['];', '']
    (ROOT / 'lib/personal_expense_catalog.dart').write_text('\n'.join(lines), encoding='utf-8')
    (destination / 'asset_registry.json').write_text(json.dumps(images, ensure_ascii=False, indent=2), encoding='utf-8')

    snapshot = json.loads((PRIVATE / 'before.json').read_text(encoding='utf-8-sig'))
    spaces = [s for s in snapshot['spaces'] if s['kind'] == 'personal']
    assert len(spaces) == 1, 'Select an explicit personal scope first'
    scope = spaces[0]
    cats = [c for c in snapshot['categories'] if c['space_id'] == scope['id'] and c['kind'] == 'expense']
    by_id = {c['id']: c for c in cats}
    def path(c):
        return (path(by_id[c['parent_id']]) + ' / ' if c['parent_id'] else '') + c['name']
    refs = Counter(e['category_id'] for e in snapshot['expenses'])
    refs.update(t.get('fee_category_id') for t in snapshot['transfers'])
    matches, conflicts = match_categories(items, cats, refs)
    assert not conflicts, json.dumps(conflicts, ensure_ascii=False)
    # Stable prepared UUIDs survive regeneration. Never installed automatically.
    old_plan_file = PRIVATE / 'plan.json'
    old_plan = json.loads(old_plan_file.read_text(encoding='utf-8')) if old_plan_file.exists() else {}
    old_plan = {c['key']: c for c in old_plan.get('plan', [])}
    plan = []
    for c in items:
        old, reason = matches.get(c['key'], (None, 'no compatible candidate; create'))
        icon = images[c['asset_key']]['icon_id']
        if old and old['icon_id'] in registry.values() and c['key'] != 'natasha':
            icon = old['icon_id']
        plan.append({**c, 'id': old['id'] if old else old_plan.get(c['key'], {}).get('id', str(uuid.uuid4())),
                     'reuse': old is not None, 'old_path': path(old) if old else None,
                     'old_parent_id': old['parent_id'] if old else None, 'icon_id': icon, 'reason': reason})
    assert len({c['id'] for c in plan}) == 143
    ids = {c['key']: c['id'] for c in plan}
    for c in plan:
        c['parent_id'] = ids.get(c['parent_key'])
    # Simulate final tree, including retained grandchildren, before generating SQL.
    final = {c['id']: dict(c) for c in cats}
    for c in plan:
        final[c['id']] = c
    for c in final.values():
        seen = set(); node = c
        while node:
            assert node['id'] not in seen and len(seen) < 3, ('depth/cycle', c)
            seen.add(node['id']); node = final.get(node['parent_id'])
    expected = [{'id': c['id'], 'revision': c['revision']} for c in sorted(cats, key=lambda x: x['id'])]
    financial = {table: [r for r in snapshot[table] if r['space_id'] == scope['id']] for table in ['expenses', 'incomes', 'transfers']}
    reused_count = sum(c['reuse'] for c in plan)
    moved_count = sum(c['reuse'] and c['old_parent_id'] != c['parent_id'] for c in plan)
    totals = {t: dict(Counter()) for t in financial}
    for table in ['expenses', 'incomes']:
        amounts = Counter()
        for r in financial[table]:
            amounts[r['currency']] += int(r['amount_minor'])
        totals[table] = dict(amounts)
    transfer_totals = {name: Counter() for name in ['source', 'target', 'fee']}
    for r in financial['transfers']:
        transfer_totals['source'][r['source_currency']] += int(r['source_minor'])
        transfer_totals['target'][r['target_currency']] += int(r['target_minor'])
        transfer_totals['fee'][r['source_currency']] += int(r['fee_minor'])
    totals['transfers'] = {k: dict(v) for k, v in transfer_totals.items()}
    output = {'scope': scope, 'plan': plan, 'expected': expected, 'references': financial,
              'operation_counts': {k: len(v) for k, v in financial.items()},
              'counts': {'reused': reused_count, 'moved': moved_count, 'created': 143-reused_count,
                         'merged': 0, 'images_reused': reused, 'images_imported': imported}, 'totals': totals}
    (PRIVATE / 'plan.json').write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding='utf-8')
    report = ROOT / 'PERSONAL_EXPENSES_MAPPING.csv'
    with report.open('w', encoding='utf-8-sig', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['key', 'ID', 'reused', 'old_path', 'new_path', 'icon_id', 'reason'])
        for c in plan:
            writer.writerow([c['key'], c['id'], c['reuse'], c['old_path'], c['path'], c['icon_id'], c['reason']])
    values = ',\n'.join('  (' + ','.join([sql(c['key']), sql(c['name']), sql(c['parent_key']), str(c['sort_order']), sql(images[c['asset_key']]['icon_id'])]) + ')' for c in items)
    template = (ROOT / 'supabase/personal_expenses_migration.template.sql').read_text(encoding='utf-8')
    migration = template.replace('__CATALOG_VALUES__', values)
    (ROOT / 'supabase/migrations/202610060017_personal_expenses.sql').write_text(migration, encoding='utf-8')
    install = migration.removesuffix('commit;\n') + '\nselect finance_private.install_personal_expenses_20261006(\n' + ',\n'.join([
        '  '+sql(scope['id'])+'::uuid', '  '+sql(scope['owner_user_id'])+'::uuid',
        '  '+sql(json.dumps([{'key': c['key'], 'id': c['id'], 'reuse': c['reuse'], 'icon_id': c['icon_id']} for c in plan], ensure_ascii=False))+'::jsonb',
        '  '+sql(json.dumps(expected))+'::jsonb', '  '+sql(json.dumps(financial, ensure_ascii=False))+'::jsonb']) + '\n);\ncommit;\n'
    folder = ROOT / 'personal-expenses-install'
    folder.mkdir(exist_ok=True)
    # JSON arguments on separate physical lines keep the SQL editor readable.
    install = install.replace('}, {', '},\n {')
    payload = install.replace('\n', '\r\n').encode('utf-8-sig')
    for ext in ['sql', 'txt']:
        (folder / ('INSTALL_PERSONAL_EXPENSES.'+ext)).write_bytes(payload)
    import zipfile
    with zipfile.ZipFile(ROOT / 'personal-expenses-install.zip', 'w', zipfile.ZIP_DEFLATED) as z:
        for p in folder.iterdir():
            z.write(p, p.name)
    print(json.dumps({'counts': output['counts'], 'sql_lines': len(install.splitlines()), 'first': install.splitlines()[0], 'last': install.splitlines()[-1]}, ensure_ascii=False))


if __name__ == '__main__':
    prepare()

