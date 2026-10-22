"""Audit D-228's opt-in boundary without rewriting JSONC or line endings."""
import subprocess
from pathlib import Path
from check_ranged_profiles import parse, span

ROOT = Path(__file__).resolve().parents[2]
PROFILES = ('experimental_balanced', 'experimental_hard', 'experimental_terrible')

def main():
    for profile in PROFILES:
        path = ROOT/'data/config'/profile/'behaviour.json'
        raw = path.read_bytes()
        old = subprocess.check_output(['git', '-c', 'safe.directory='+ROOT.as_posix(),
                                       'show', 'd2ec833f:'+path.relative_to(ROOT).as_posix()])
        a, b = span(old, 'corthud'), span(raw, 'corthud')
        assert (old[:a[0]]+old[a[1]:]).replace(b'\r\n',b'\n') == (raw[:b[0]]+raw[b[1]:]).replace(b'\r\n',b'\n'), profile
        before, after = parse(old)['behaviour']['corthud'], parse(raw)['behaviour']['corthud']
        policy = after.pop('ranged')
        assert after.pop('attribute') == ['ranged']
        assert before == after, profile+' changed production/classification'
        assert policy['coordinated'] is True
        assert .5 <= policy['range_fraction'] <= .99
        assert .1 <= policy['reaction_seconds'] <= 5
        assert 1 <= policy['cohort_size'] <= 12
        assert policy['rush_ratio'] > 1 and policy['catch_seconds'] > 0
        assert 0 < policy['engagement_seconds'] <= 30
        assert 1 <= policy['advantage_exit'] <= policy['advantage_enter'] <= 5
        assert 0 < policy['static_loss_fraction'] < policy['loss_fraction'] < .9
    for path in (ROOT/'data/config').rglob('behaviour.json'):
        if path.parent.name in PROFILES: continue
        entry = parse(path.read_bytes()).get('behaviour',{}).get('corthud',{})
        assert not entry.get('ranged',{}).get('coordinated',False), str(path)
    print('Thug profiles: exactly three opt-ins; production, other units and legacy profiles unchanged')

if __name__ == '__main__': main()
