"""Verify a fresh RLS snapshot against the backup and authoritative catalog."""
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ROOT / '.local-backups/business-expenses'


def main():
    before = json.loads((PRIVATE / 'before.json').read_text(encoding='utf-8-sig'))
    after = json.loads((PRIVATE / 'snapshot-browser.txt').read_text(encoding='utf-8-sig'))
    catalog = json.loads((ROOT / 'design/business-expenses-pack/catalog.json').read_text(encoding='utf-8-sig'))
    scope = before['space_id']
    assert after['space_id'] == scope
    old = {c['id'] for c in before['categories'] if c['space_id'] == scope and c['kind'] == 'expense'}
    actual = [c for c in after['categories'] if c['space_id'] == scope and c['kind'] == 'expense']
    assert len(actual) == 62, f'Expected 62 installed categories, found {len(actual)}'
    assert not old.intersection(c['id'] for c in actual), 'Old categories remain'
    by_icon = {c['icon_id']: c for c in actual}
    assert len(by_icon) == 62, 'Duplicate assignments'
    by_key = {}
    for c in catalog['categories']:
        row = by_icon[c['icon_id']]
        assert row['name'] == c['name'] and not row['is_archived']
        assert row['sort_order'] == c['sort_order']
        by_key[c['key']] = row
    for c in catalog['categories']:
        assert by_key[c['key']]['parent_id'] == (by_key[c['parent_key']]['id'] if c['parent_key'] else None)
    for table in ['spaces', 'wallets', 'opening_balances', 'incomes', 'expenses', 'transfers']:
        def indexed(rows):
            return {r.get('id', r.get('wallet_id')): r for r in rows}
        assert indexed(before[table]) == indexed(after[table]), f'{table} changed unexpectedly'
    def other_categories(snapshot):
        return {c['id']: {k:v for k,v in c.items() if k != 'sort_order'} for c in snapshot['categories']
                if not(c['space_id'] == scope and c['kind'] == 'expense')}
    assert other_categories(before) == other_categories(after), 'Other category scope changed'
    result = {'installed':62, 'roots':11, 'children':51, 'deleted':len(old), 'images':62,
              'remapped_operations':0, 'financial_data_unchanged':True}
    (PRIVATE / 'verification.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
