"""Staged AngelScript settings access; supports split defaults and pinned legacy data.

These helpers edit only the caller-supplied tree. Namespaces are resolved with
balanced braces after masking comments/strings, never by the next closing line.
No runtime AI behavior or settings precedence is implemented here.
"""
from pathlib import Path
import re


def mask(source):
    return re.sub(r'//[^\r\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
                  lambda m: ''.join('\n' if c == '\n' else ' ' for c in m[0]), source)


def namespace_span(source, names):
    """Return the unique named namespace's declaration/body/end offsets."""
    code = mask(source)
    regions = []
    for match in re.finditer(r'\bnamespace\s+(\w+)\s*\{', code):
        brace = match.end()-1
        depth, end = 1, brace+1
        while depth and end < len(code):
            depth += (code[end] == '{') - (code[end] == '}')
            end += 1
        if depth: raise ValueError('Unbalanced namespace')
        parents = [r[0] for r in regions if r[1] < match.start() < r[3]]
        regions.append((match[1], match.start(), brace+1, end, tuple(parents+[match[1]])))
    found = [r for r in regions if r[4] == tuple(names)]
    if len(found) != 1: raise ValueError('Expected one namespace: ' + '::'.join(names))
    return found[0][1:4]


def role_settings_path(source_root, role):
    """Prefer split settings; fallback only for historical unsplit snapshots."""
    root = Path(source_root)
    split = root/'settings/roles'/f'{role.lower()}.as'
    path = split if split.is_file() else root/'global.as'
    if not path.is_file(): raise ValueError('Missing settings file: '+str(path))
    namespace_span(path.read_text(encoding='utf-8'), ('Global','RoleSettings',role))
    return path


def apply_override(source_root, expression):
    """Key=value is TECH shorthand; Role.Key=value selects a role explicitly."""
    key, separator, value = expression.partition('=')
    if not separator or not value.strip(): raise ValueError('Expected [Role.]Key=value')
    parts = key.strip().split('.')
    role, key = ('Tech', parts[0]) if len(parts) == 1 else parts if len(parts) == 2 else ('','')
    roles = {r.lower():r for r in ('Tech','Air','Sea','Front','Support','Tactical')}
    if role.lower() not in roles or not re.fullmatch(r'\w+', key): raise ValueError('Unknown role or key')
    role = roles[role.lower()]
    path = role_settings_path(source_root, role)
    source = path.read_bytes().decode('utf-8')
    _, begin, end = namespace_span(source, ('Global','RoleSettings',role))
    block = source[begin:end-1]
    # Mask quoted values too, so commas/semicolons inside strings cannot split
    # declarations. Support compact declarations such as float Metal=50, Energy=500.
    clean = mask(block)
    matches = []
    for declaration in re.finditer(r"\b(?:int|uint|float|bool|string)\s+([^;]+);", clean):
        for item in re.finditer(r"(?:^|,)\s*(\w+)\s*=([^,]*)", declaration[1]):
            if item[1] != key:
                continue
            start = begin + declaration.start(1) + item.start(2)
            finish = begin + declaration.start(1) + item.end(2)
            raw = source[start:finish]
            start += len(raw) - len(raw.lstrip())
            finish -= len(raw) - len(raw.rstrip())
            matches.append((start, finish))
    if len(matches) != 1: raise ValueError(f'Expected one {role}.{key} setting, found {len(matches)}')
    start, finish = matches[0]
    path.write_bytes((source[:start]+value.strip()+source[finish:]).encode('utf-8'))
    return f'{role}::{key}'

def role_script_path(source_root, module):
    """Find a current role module or its flat location in a pinned old tree."""
    if not re.fullmatch(r"(?:air|sea|tech|front|support|tactical)(?:_[a-z]+)*", module):
        raise ValueError("Invalid role module: " + module)
    root=Path(source_root)/'roles'
    current=root/module.split('_')[0]/(module+'.as')
    legacy=root/(module+'.as')
    if current.is_file(): return current
    if legacy.is_file(): return legacy
    raise ValueError("Missing role module: " + module)
