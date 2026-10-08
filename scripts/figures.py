#!/usr/bin/env python3
"""The site's data figure, drawn from the benchmark table in README.md so that a number on the page is a number in the repository.

    python3 scripts/figures.py          # write docs/figures/bench.svg
    python3 scripts/figures.py --check  # exit 1 if the committed figure differs from what README.md gives

The README's table is the one `docs/benchmarks.md` explains (requests a second, one core each, median of 3). The SVG is
self-contained (its own colours, light and dark), because it is shown with <img>.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CELLS = ["GET one user", "a page of 20", "rejected body (422)", "create"]
NAMES = {"cancho": "cancho-web", "Go": "Go net/http", "hand-written C": "hand-written C", "FastAPI": "FastAPI"}

STYLE = """<style>
.t{fill:#14171c;font:600 13px system-ui,sans-serif}.s{fill:#5b6573;font:12px system-ui,sans-serif}.v{fill:#14171c;font:600 12px system-ui,sans-serif}.v,.s{paint-order:stroke;stroke:#fbfbfc;stroke-width:4px;stroke-linejoin:round}
.a{fill:#265e8d}.b{fill:#a89f8f}
@media (prefers-color-scheme:dark){.v,.s{stroke:#0d1217}.t,.v{fill:#e8eaee}.s{fill:#9ba5b3}.a{fill:#6fa3d6}.b{fill:#8c8576}}
</style>"""


def table():
    """{server: [four numbers]} from the README's 'requests a second' table."""
    text = (ROOT / "README.md").read_text()
    start = text.index("| requests a second |")
    rows = {}
    for line in text[start:].splitlines()[2:]:
        if not line.startswith("|"):
            break
        cells = [c.strip().strip("*") for c in line.strip("|").split("|")]
        key = next(k for k in NAMES if cells[0].startswith(k))
        rows[key] = [int(c.replace(",", "")) for c in cells[1:5]]
    assert len(rows) == 4, rows
    return rows


def bench_svg():
    rows = table()
    x0, width, bar, gap, head = 110, 450, 15, 4, 34
    block = head + len(rows) * (bar + gap) + 14
    lines = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 700 %d" role="img" aria-label="Requests per second on one core in four cells, fastest first. cancho-web is far ahead of FastAPI in all four, ahead of Go net/http in all four, level with a hand-written C server on a read and behind it on the other three.">' % (22 + block * len(CELLS)), STYLE]
    lines.append('<text class="t" x="0" y="16">Requests per second, one core each, higher is better (median of 3, one run)</text>')
    for n, label in enumerate(CELLS):
        y0 = 30 + n * block
        values = {k: v[n] for k, v in rows.items()}
        top = max(values.values())
        lines.append('<text class="t" x="0" y="%d">%s</text>' % (y0 + 14, label))
        for i, key in enumerate(sorted(values, key=lambda k: -values[k])):
            y = y0 + head - 10 + i * (bar + gap)
            w = max(2.0, width * values[key] / top)
            us = key == "cancho"
            lines.append('<text class="%s" x="%d" y="%d" text-anchor="end">%s</text>' % ("t" if us else "s", x0 - 8, y + 12, NAMES[key]))
            lines.append('<rect class="%s" x="%d" y="%d" width="%.1f" height="%d" rx="2"/>' % ("a" if us else "b", x0, y, w, bar))
            lines.append('<text class="v" x="%.1f" y="%d">%s</text>' % (x0 + w + 6, y + 12, format(values[key], ",")))
    lines.append("</svg>")
    return "\n".join(lines) + "\n"


def main():
    out = ROOT / "docs" / "figures" / "bench.svg"
    svg = bench_svg()
    if "--check" in sys.argv:
        if not out.exists() or out.read_text() != svg:
            print("figures: docs/figures/bench.svg differs from the table in README.md", file=sys.stderr)
            return 1
        print("the figure is what the README's table gives")
        return 0
    out.write_text(svg)
    print("wrote", out.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
