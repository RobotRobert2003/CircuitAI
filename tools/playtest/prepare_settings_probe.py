"""Stage read-only effective-setting probes in an isolated copied data tree.

Compares all primitive tuning globals at real lifecycle boundaries. The probe
is test-only, uses no RNG and issues no unit orders. Containers/functions are
covered by the exact namespace/member token audit rather than stringifying
mutable handles. Profiles can be run with the normal playtest runner.
"""
import argparse
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'knowledge'))
from check_settings_extraction import members
from script_settings import mask


def function_end(source,signature):
    start=source.index(signature);code=mask(source);brace=code.index('{',start)
    depth=1;end=brace+1
    while depth:
        depth+=(code[end]=='{')-(code[end]=='}');end+=1
    return brace,end-1


def setting_fields(baseline):
    """Read either a historical monolith or the current split defaults."""
    declarations=members((Path(baseline)/'script/src/global.as').read_text())
    for path in sorted((Path(baseline)/'script/src/settings').rglob('*.as')):
        declarations.extend(members(path.read_text()))
    fields=[]
    for namespace,tokens in declarations:
        if namespace[:1]!=('Global',) or len(namespace)<2 or namespace[1] not in ('Porc','Ferry','SeaAssist','BuilderRecovery','ConstructorRequest','Military','Spam','RoleSettings'):continue
        if len(tokens)>3 and tokens[0] in ('int','uint','float','bool','string') and tokens[2]=='=':
            fields.extend('::'.join(namespace+(tokens[index-1],)) for index, token in enumerate(tokens) if token == '=')
    if len(fields) != len(set(fields)):
        raise ValueError('Duplicate effective setting declarations')
    return fields


def prepare(data, baseline, profile_sentinel=True):
    root=Path(data)/'script'; src=root/'src'
    fields=setting_fields(baseline)
    lines=['namespace SettingsProbe {','bool sampled=false;','void Snapshot(const string &in phase) {','if (ai.teamId != 0) return;']
    # This namespace-level constant depends on a moved default. Observe its
    # initialized value separately from the mutable setting snapshots.
    lines.append('GenericHelpers::LogUtil("[DerivedProbe] " + phase + " AirQuotaFrames=" + RoleAir::AIR_DYNAMIC_QUOTA_DELAY_FRAMES, 1);')
    for field in fields:lines.append(f'GenericHelpers::LogUtil("[SettingsProbe] " + phase + " {field}=" + {field}, 1);')
    lines+=['}','void Tick() { if (!sampled && ai.frame >= 60*SECOND) { sampled=true; Snapshot("minute-one"); } }','}']
    (src/'settings_probe.as').write_text('\n'.join(lines)+'\n')
    for profile in ('experimental_balanced','experimental_hard','experimental_terrible'):
        p=root/profile/'main.as';s=p.read_text();s='#include "../src/settings_probe.as"\n'+s
        begin,end=function_end(s,'void AiMain()');s=s[:end]+'SettingsProbe::Snapshot("after-main");\n'+s[end:];s=s[:begin+1]+'\nSettingsProbe::Snapshot("before-main");\n'+s[begin+1:]
        begin,end=function_end(s,'void AiUpdate()');s=s[:end]+'SettingsProbe::Tick();\n'+s[end:]
        # Controlled profile override demonstrates that defaults are not reapplied later.
        if profile_sentinel:
            begin,end=function_end(s,'void ApplyProfileSettings()');s=s[:end]+'Global::RoleSettings::Tech::MinAiSwitchTime = 401;\n'+s[end:]
        p.write_text(s)
    p=src/'setup.as';s=p.read_text();begin,end=function_end(s,'void setupMap(');s=s[:end]+'SettingsProbe::Snapshot("after-setup");\n'+s[end:];p.write_text(s)
    return len(fields)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--data',required=True,type=Path);p.add_argument('--baseline',required=True,type=Path)
    a=p.parse_args();print('Instrumented',prepare(a.data,a.baseline),'settings')
