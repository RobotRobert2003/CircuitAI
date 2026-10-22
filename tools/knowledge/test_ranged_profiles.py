import unittest
from check_ranged_profiles import span, parse, neutralize


class RangedProfileTest(unittest.TestCase):
    def test_span_nested_threat_keeps_late_retreat_and_mixed_newlines(self):
        unit = b'"armmanni": {\r\n"threat":{"vs":{"spam":0}},\n"retreat":0\r\n}'
        raw = b'{"behaviour":{'+unit+b',"armrad":{"role":["radar"]}}}'
        start, end = span(raw, 'armmanni')
        self.assertEqual(raw[start:end], unit)
        self.assertEqual(parse(raw)['behaviour']['armmanni']['retreat'], 0)

    def test_span_braces_in_comments_do_not_end_object(self):
        raw = b'{"armsnipe": {/* } */ "role":["anti_heavy"], // {\n"retreat":0.95}}'
        start, end = span(raw, 'armsnipe')
        self.assertEqual(raw[start:end], raw[1:-1])

    def test_neutralize_preserves_unrelated_definition_bytes(self):
        raw = b'{"armrad":{"role":["radar"]},"armsnipe":{"role":["anti_heavy"]}}'
        self.assertEqual(neutralize(raw), b'{"armrad":{"role":["radar"]},}')


if __name__ == '__main__': unittest.main()
