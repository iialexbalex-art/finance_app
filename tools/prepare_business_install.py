"""Prepare a concrete SQL install and mapping report from a local RLS backup."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ROOT / '.local-backups/business-expenses'


def normalize(value):
    return re.sub(r'\s+', ' ', value.translate(str.maketrans('ёЁ‐‑‒–—−', 'еЕ------')).strip()).lower()


def main():
    backup = json.loads((PRIVATE / 'before.json').read_text(encoding='utf-8-sig'))
    catalog = json.loads((ROOT / 'design/business-expenses-pack/catalog.json').read_text(encoding='utf-8-sig'))
    scope = backup['space_id']
    space = next(s for s in backup['spaces'] if s['id'] == scope)
    assert space['kind'] == 'business'
    old = {c['id']: c for c in backup['categories'] if c['space_id'] == scope and c['kind'] == 'expense'}
    new = {c['key']: c for c in catalog['categories']}
    paths = {}

    def path(category):
        if category['id'] in paths:
            return paths[category['id']]
        parent = category['parent_id']
        result = (path(old[parent]) + ' / ' if parent else '') + category['name']
        paths[category['id']] = result
        return result

    accepted = {}
    for key, c in new.items():
        names = [c['path']]
        parent_path = new[c['parent_key']]['path'] + ' / ' if c['parent_key'] else ''
        names.extend(parent_path + alias for alias in c['aliases'])
        for name in names:
            accepted.setdefault(normalize(name), set()).add(key)
    mapping = []
    for category in old.values():
        old_path = path(category)
        matches = accepted.get(normalize(old_path), set())
        expenses = [e for e in backup['expenses'] if e['category_id'] == category['id']]
        fees = [t for t in backup['transfers'] if t['fee_category_id'] == category['id']]
        totals = {}
        for e in expenses:
            totals[e['currency']] = str(int(totals.get(e['currency'], '0')) + int(e['amount_minor']))
        mapping.append({'old_category_id': category['id'], 'old_path': old_path,
                        'new_category_key': next(iter(matches)) if len(matches) == 1 else None,
                        'operations': len(expenses), 'transfer_references': len(fees), 'amount_minor_by_currency': totals})
    (PRIVATE / 'mapping.json').write_text(json.dumps(mapping, ensure_ascii=False, indent=2), encoding='utf-8')
    unresolved = [m for m in mapping if not m['new_category_key'] and (m['operations'] or m['transfer_references'])]
    if unresolved:
        raise RuntimeError('Unresolved used categories; inspect mapping.json before installation')
    old_ids = ','.join("'%s'::uuid" % id for id in sorted(old))
    references = sorted([e['id'] for e in backup['expenses'] if e['category_id'] in old] +
                        [t['id'] for t in backup['transfers'] if t['fee_category_id'] in old])
    reference_ids = 'array[' + ','.join("'%s'::uuid" % id for id in references) + ']::uuid[]'
    call = "select finance_private.install_business_expenses_20261006('%s'::uuid,'%s'::uuid,array[%s],p_expected_reference_ids => %s);" % (scope, space['owner_user_id'], old_ids, reference_ids)
    migration = (ROOT / 'supabase/migrations/202610060015_business_expenses.sql').read_text(encoding='utf-8')
    tests = (ROOT / 'supabase/tests/15_business_expenses.sql').read_text(encoding='utf-8')
    sql = ('-- Target: Бизнес; explicit owner and the 130 IDs from the local backup.\n'
           '-- Schema setup ONCE, rollback-only migration tests, then atomic replacement.\n'
           + migration + '\n' + tests + '\nbegin;\n' + call + '\ncommit;\n'
           '-- Repeat installer: must return already_installed=true without mutating categories.\n'
           + call + '\n')
    (PRIVATE / 'APPLY_BUSINESS_EXPENSES.sql').write_text(sql, encoding='utf-8')
    (PRIVATE / 'RECHECK_INSTALL.sql').write_text(call + '\n', encoding='utf-8')
    print('Prepared replacement: %d old, 62 new, %d used ambiguities.' % (len(old), len(unresolved)))


if __name__ == '__main__':
    main()
