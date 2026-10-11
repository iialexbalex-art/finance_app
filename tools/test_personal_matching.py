import unittest
from collections import Counter
from prepare_personal_expenses import match_categories, norm


def item(key, name, parent=None, aliases=None):
    return {'key': key, 'name': name, 'parent_key': parent, 'aliases': aliases or []}


def row(id, name, parent=None, archived=False):
    return {'id': id, 'name': name, 'parent_id': parent, 'is_archived': archived}


class MatchingTests(unittest.TestCase):
    def test_reserve_full_paths_before_generic_distribution(self):
        items = [item('a', 'Person A'), item('a-gift', 'Gift', 'a'), item('b', 'Person B'), item('b-gift', 'Gift', 'b')]
        cats = [row('old-a', 'Person A'), row('exact', 'Gift', 'old-a', True), row('generic', 'Gift')]
        matches, conflicts = match_categories(items, cats, Counter())
        self.assertFalse(conflicts)
        self.assertEqual(matches['a-gift'][0]['id'], 'exact')
        self.assertEqual(matches['b-gift'][0]['id'], 'generic')
        self.assertEqual(len({x[0]['id'] for x in matches.values()}), len(matches))

    def test_used_generic_gift_and_subtree_are_conflicts(self):
        items = [item('a', 'Person A'), item('a-gift', 'Gift', 'a')]
        self.assertTrue(match_categories(items, [row('gift', 'Gift')], Counter({'gift': 1}))[1])
        self.assertTrue(match_categories(items, [row('gift', 'Gift'), row('kid', 'Subgift', 'gift')], Counter())[1])

    def test_alias_is_scoped_and_does_not_take_another_person(self):
        items = [item('a', 'Person A'), item('nails', 'Nails', 'a', ['Manicure'])]
        matches, conflicts = match_categories(items, [row('b', 'Person B'), row('n', 'Manicure', 'b')], Counter())
        self.assertFalse(conflicts)
        self.assertNotIn('nails', matches)

    def test_duplicate_exact_paths_do_not_select_first(self):
        self.assertTrue(match_categories([item('a', 'Person A')], [row('a1', 'Person A'), row('a2', 'Person A')], Counter())[1])

    def test_normalization(self):
        self.assertEqual(norm('  Тренажёрный   зал — дом '), norm('тренажерный зал - дом'))


if __name__ == '__main__':
    unittest.main()
