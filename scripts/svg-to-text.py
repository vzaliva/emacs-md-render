#!/usr/bin/env python3
"""Extract the character grid from a Textual/Rich SVG screenshot as plain text.

Usage: svg-to-text.py SCREENSHOT.svg > out.txt

Textual writes one <text> element per styled run, positioned in pixels and
carrying a textLength attribute; textLength / len(run) gives the cell width,
which maps x positions back to columns.
"""
import html
import re
import sys
from collections import defaultdict

svg = open(sys.argv[1], encoding="utf-8").read()
rows = defaultdict(list)
cells = []
pat = re.compile(
    r'<text[^>]*?\bx="([\d.]+)"[^>]*?\by="([\d.]+)"[^>]*?\btextLength="([\d.]+)"[^>]*>(.*?)</text>',
    re.S,
)
for m in pat.finditer(svg):
    x, y, tl, content = float(m.group(1)), float(m.group(2)), float(m.group(3)), m.group(4)
    content = html.unescape(re.sub(r"<[^>]+>", "", content)).replace("\xa0", " ")
    if content:
        cells.append(tl / len(content))
        rows[round(y)].append((x, content))
cells.sort()
cell = cells[len(cells) // 2]
x0 = min(x for r in rows.values() for x, _ in r)
out = []
for y in sorted(rows):
    line = []
    for x, content in sorted(rows[y]):
        col = round((x - x0) / cell)
        if len(line) < col:
            line.extend(" " * (col - len(line)))
        line[col:col + len(content)] = list(content)
    out.append("".join(line).rstrip())
sys.stdout.write("\n".join(out) + "\n")
print(f"{len(out)} lines, cell width {cell:.2f}px", file=sys.stderr)
