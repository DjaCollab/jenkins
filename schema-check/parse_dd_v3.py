"""Data dictionary (DES35-00011.pdf v2.0) -> dd_v3.json (tables/columns/keys + views).

First extract the PDF text next to this script:
    pdftotext -table -enc UTF-8 ..\DES35-00011.pdf dd_pdf_table.txt
"""
import re, json, collections

import os
SP = os.path.dirname(os.path.abspath(__file__))
raw = open(os.path.join(SP, 'dd_pdf_table.txt'), encoding='utf-8').read()

FOOTER = re.compile(r'^\s*(© 2025, Forensic Technology.*|CONFIDENTIAL|IBIS Database 6\.0\s+Document Number.*|Data Dictionary\s+Document Version.*)\s*$')
lines = [l for l in raw.split('\n') if not FOOTER.match(l)]
text = '\n'.join(lines)

def section(start_pat, end_pat):
    s = [m.end() for m in re.finditer(start_pat, text, re.M)][-1]      # the real heading, not the TOC
    e = next((m.start() for m in re.finditer(end_pat, text, re.M) if m.start() > s), len(text))
    return text[s:e]

attrs = section(r'^5\s+Attribute Definitions\s*$', r'^6\s+Views\s*$')
views_txt = section(r'^6\s+Views\s*$', r'^7\s+Functions\s*$')

HEAD2 = re.compile(r'^5\.(\d+)\s+([A-Z][A-Za-z ,&]+?)\s*$')
HEAD3 = re.compile(r'^5\.\d+\.\d+(?:\.\d+)?\s+([A-Z][A-Z0-9_]+)\s*$')
COL = re.compile(r'\b([A-Z][A-Z0-9_]*)\s*\(([^()]{1,25})\)\s*:\s*\(([^()]*?=\s*>\s*[^()]*?|Optional|Mandatory)\)')
KEYHDR = re.compile(r'^\s*(Primary Key|Unique Key\(s\)|Foreign Key\(s\))\s{2,}Column\s{2,}Position(\s{2,}Referred Constraint)?\s*$')
KIND = {'Primary Key': 'p', 'Unique Key(s)': 'u', 'Foreign Key(s)': 'f'}

def nullability(spec):
    rhs = re.split(r'=\s*>', spec)[-1].strip()
    if rhs == 'Mandatory': return 'mandatory'
    if rhs == 'Optional': return 'optional'
    if rhs.startswith('Mandatory'): return 'conditional'
    return 'unknown:' + rhs

tables = collections.OrderedDict()
group = table = None
body = []          # text of the current table's column definitions
key_kind = None    # inside a key block
cur_key = None

def flush_columns():
    if table is None: return
    t = tables[table]
    for m in COL.finditer('\n'.join(body)):
        if any(c['name'] == m.group(1) for c in t['columns']):
            continue
        spec = m.group(3)
        t['columns'].append({'name': m.group(1), 'type': m.group(2).strip(),
                             'label': re.split(r'=\s*>', spec)[0].strip() if '=' in spec else '',
                             'null': nullability(spec)})

for l in attrs.split('\n'):
    s = l.strip()
    at_margin = len(l) - len(l.lstrip()) <= 3
    m2, m3 = (HEAD2.match(s), HEAD3.match(s)) if at_margin else (None, None)
    if m3 or m2:
        flush_columns(); body = []; key_kind = cur_key = None
        if m3:
            table = m3.group(1)
            tables.setdefault(table, {'group': group, 'columns': [], 'keys': []})
        else:
            group = m2.group(2); table = None
        continue
    if table is None:
        continue
    mk = KEYHDR.match(l)
    if mk:
        key_kind = KIND[mk.group(1)]; cur_key = None
        hdr_indent = len(l) - len(l.lstrip())
        continue
    if key_kind:
        if not s:
            continue
        cells = re.split(r'[ ]{2,}', s)
        indent = len(l) - len(l.lstrip())
        if indent <= hdr_indent + 2 and len(cells) >= 3 and cells[2].isdigit():
            cur_key = {'kind': key_kind, 'name': cells[0], 'columns': [cells[1]], 'ref': cells[3] if len(cells) > 3 else ''}
            tables[table]['keys'].append(cur_key)
            continue
        if indent > hdr_indent + 2 and cur_key and len(cells) >= 2 and cells[1].isdigit():
            cur_key['columns'].append(cells[0])
            continue
        if indent > hdr_indent + 2 and cur_key and len(cells) == 1 and '(' in cur_key['columns'][-1] and cur_key['columns'][-1].count('(') > cur_key['columns'][-1].count(')'):
            cur_key['columns'][-1] += cells[0]
            continue
        key_kind = cur_key = None      # a NOTE or other text ends the key block
    body.append(l)
flush_columns()

views = re.findall(r'(?m)^6\.\d+\s+([A-Z][A-Z0-9_]+)\s*$', views_txt)

out = {'tables': tables, 'views': views}
json.dump(out, open(os.path.join(SP, 'dd_v3.json'), 'w', encoding='utf-8'), indent=1)
nk = collections.Counter(k['kind'] for t in tables.values() for k in t['keys'])
print('tables:', len(tables), '| columns:', sum(len(t['columns']) for t in tables.values()),
      '| keys:', dict(nk), '| views:', len(views))
print('tables without a primary key listed:', [n for n, t in tables.items() if not any(k['kind'] == 'p' for k in t['keys'])])
print('sample CASES keys:', json.dumps(tables['CASES']['keys']))
print('sample ACQUISITION_BILLING keys:', json.dumps(tables['ACQUISITION_BILLING']['keys']))
print('views:', ', '.join(views))
