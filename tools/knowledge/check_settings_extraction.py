"""Exact namespace-member token comparison for the global/defaults extraction.

Comments/whitespace/includes may change. Every declaration, initializer and
function body must retain its tokens and owning namespace. Member order is
reported separately: non-literal initializer dependencies still require host
validation. This is an offline audit, never a game-loop operation.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re

TOKEN = re.compile(r'//[^\r\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|\w+|[^\s]', re.M)


def members(source):
    source = re.sub(r'^\s*#include[^\r\n]*', '', source, flags=re.M)
    tokens = [m[0] for m in TOKEN.finditer(source) if not m[0].startswith(('//','/*'))]
    result=[]
    def scope(start, namespace):
        position=start
        while position<len(tokens) and tokens[position]!='}':
            if tokens[position]=='namespace':
                name=tokens[position+1]; assert tokens[position+2]=='{'
                position=scope(position+3,namespace+(name,))+1
                continue
            begin=position; braces=parentheses=0; function=False
            while position<len(tokens):
                token=tokens[position]
                if token=='(' and braces==0: parentheses+=1
                if token==')' and braces==0: parentheses-=1
                if token=='{':
                    if braces==0 and '=' not in tokens[begin:position] and ')' in tokens[begin:position]:function=True
                    braces+=1
                if token=='}':
                    braces-=1
                    if braces<0:raise ValueError('Unexpected scope end')
                    if braces==0 and function:
                        position+=1;break
                if token==';' and braces==0 and parentheses==0:
                    position+=1;break
                position+=1
            result.append((namespace,tuple(tokens[begin:position])))
        return position
    scope(0,())
    return result


def compare(before, after):
    original=members((Path(before)/'script/src/global.as').read_text())
    root=Path(after)/'script/src'
    current=members((root/'global.as').read_text())
    for path in sorted((root/'settings').rglob('*.as')):current+=members(path.read_text())
    if Counter(original)!=Counter(current):
        missing=list((Counter(original)-Counter(current)).elements())
        added=list((Counter(current)-Counter(original)).elements())
        raise ValueError(json.dumps({'missing':missing,'added':added},indent=2))
    return {'members_verified':len(original),'namespace_and_member_tokens_identical':True,
            'order_identical': original==current,
            'note':'Extraction reorders sections; initializer dependency audit and host probes required.'}

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before-data',required=True,type=Path)
    parser.add_argument('--after-data',default=Path('data'),type=Path)
    args=parser.parse_args();print(json.dumps(compare(args.before_data,args.after_data),indent=2))