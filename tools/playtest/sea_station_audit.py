"""Physical shoreline coverage, independent of assignment-only log checks."""
import re


def audit_handoff(text, spec):
    """Every assigned guard must release on the delayed wave; require real damage too."""
    wave = spec['wave_seconds'] * 30
    deadline = wave + spec['maximum_response_seconds'] * 30
    guards, released, attackers = set(), set(), set()
    for line in text.splitlines():
        match = re.search(r'\[f=0*(\d+)\]', line)
        if not match:
            continue
        frame = int(match[1])
        fields = dict(re.findall(r'(\w+)=([^\s]+)', line))
        if '[SEA]' in line and (':T:0:' in line):
            if '[SubPerimeter]' in line and frame < wave:
                guards.add(fields['cohort'])
            elif '[GuardReleased]' in line:
                if frame < wave:
                    guards.discard(fields['cohort'])
                elif frame <= deadline:
                    released.add(fields['cohort'])
        elif '[SeaArena]' in line and ' damage ' in line and frame >= wave:
            if fields.get('attackerUnit') in spec['submarines'] and fields.get('victimUnit') == spec['enemy'] and fields.get('team') == '0':
                attackers.add(fields['attacker'])
    failures = []
    if not guards or guards - released:
        failures.append(f'Guards not released by deadline: {sorted(guards - released)}; assigned={len(guards)}')
    if not attackers:
        failures.append('No physical submarine damage to delayed enemy wave')
    return failures, dict(guards=sorted(guards), released=sorted(released), damaging_submarines=sorted(attackers))


def audit_coast(text, spec):
    """Compare stationary hulls with independent terrain samples, not goals."""
    queues, observed = {}, {}
    for line in text.splitlines():
        if '[SeaArena]' not in line:
            continue
        fields = dict(re.findall(r'(\w+)=([^\s]+)', line))
        if ' boat ' in line:
            queues[fields['id']] = int(fields['queue'])
        elif ' coast ' in line:
            observed[fields['id']] = dict(frame=int(fields['frame']), queue=queues.get(fields['id']),
                error=abs(float(fields['distance'])-float(fields['range'])*spec['range_fraction']))
    failures = []
    if len(observed) < spec['minimum_observed']:
        failures.append('Missing independent coast measurements')
    settled = {uid: row for uid, row in observed.items() if row['queue'] == 0}
    aligned = {uid: row for uid, row in settled.items() if row['error'] <= spec['maximum_error']}
    if len(aligned) < spec['minimum_aligned'] or len(aligned) != len(settled):
        failures.append(f'Only {len(aligned)} of {len(settled)} stationary hulls on range contour')
    return failures, dict(observed=observed, stationary=len(settled), aligned=len(aligned))


def audit_visibility(text, spec):
    """Five-second observer samples; first discovery is checked separately."""
    objectives = {}
    for line in text.splitlines():
        if '[SeaArena]' not in line or ' objective ' not in line:
            continue
        fields = dict(re.findall(r'(\w+)=([^\s]+)', line))
        row = objectives.setdefault(fields['id'], dict(first=None, last=None, blackout=0, maximum_blackout=0))
        frame = int(fields['frame'])
        if fields['los'] == 'true':
            if row['first'] is None:
                row['first'] = frame
            row['blackout'] = 0
        elif row['first'] is not None and row['last'] is not None:
            row['blackout'] += frame-row['last']
            row['maximum_blackout'] = max(row['maximum_blackout'], row['blackout'])
        row['last'] = frame
    failures = []
    if len(objectives) < spec['minimum_objectives']:
        failures.append('Missing objective visibility observations')
    for uid, row in objectives.items():
        if row['first'] is None or row['maximum_blackout'] > spec['maximum_blackout_seconds']*30:
            failures.append(f'Objective {uid} lacks sustained LOS: {row}')
    return failures, objectives


def audit_production(text, spec):
    produced, finished = set(), {}
    for line in text.splitlines():
        if '[SeaArena]' not in line:
            continue
        fields = dict(re.findall(r'(\w+)=([^\s]+)', line))
        if fields.get('team') != '0':
            continue
        if ' produced ' in line:
            produced.add(fields['id'])
        elif ' finished ' in line and fields['id'] in produced:
            finished.setdefault(fields['unit'], []).append(int(fields['frame']))
    scouts, subs = finished.get(spec['scout'], []), finished.get(spec['submarine'], [])
    failures = []
    if len(subs) < spec['minimum_submarines']:
        failures.append(f'Only {len(subs)} newly built submarines completed')
    if not scouts or not subs or min(scouts) >= min(subs):
        failures.append('No newly completed scout before first completed submarine')
    return failures, {'completed_frames': finished}


def audit(text, spec):
    goals, boats = {}, {}
    last_frame = 0
    for line in text.splitlines():
        match = re.search(r'\[f=0*(\d+)\]', line)
        if not match:
            continue
        frame = int(match[1])
        last_frame = max(last_frame, frame)
        fields = dict(re.findall(r'(\w+)=([^\s]+)', line))
        if '[SEA][SubPerimeter]' in line:
            goals[fields['cohort']] = tuple(map(float, fields['goal'].split(',')))
        elif '[SeaArena]' in line and ' boat ' in line and fields.get('unit') in spec['units']:
            boats[fields['id']] = (frame, float(fields['x']), float(fields['z']))
    occupied = {}
    for frame, x, z in boats.values():
        if last_frame-frame > spec.get('maximum_age_frames', 300) or not goals:
            continue
        station = min(goals, key=lambda key: (x-goals[key][0])**2+(z-goals[key][1])**2)
        gx, gz = goals[station]
        if (x-gx)**2+(z-gz)**2 <= spec.get('arrival_radius', 400)**2:
            occupied[station] = occupied.get(station, 0)+1
    measured = {'observed': len(boats), 'stationed': sum(occupied.values()), 'occupied': occupied,
                'goals': goals, 'last_frame': last_frame}
    failures = []
    if measured['stationed'] < spec['minimum_stationed']:
        failures.append(f"Only {measured['stationed']} submarines physically at stations")
    if len(occupied) < spec['minimum_stations']:
        failures.append(f'Only {len(occupied)} physically occupied stations')
    return failures, measured
