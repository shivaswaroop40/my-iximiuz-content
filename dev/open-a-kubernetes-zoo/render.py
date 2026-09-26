#!/usr/bin/env python3
"""Render tutorial.template.md into the published tutorial.

Code in the tutorial comes from the tested reference files in this directory
({{file:path}} placeholders), so the tutorial can't drift from the code that
run-tests.sh actually exercises. Re-run after editing either side:

    dev/open-a-kubernetes-zoo/render.py
"""
import pathlib
import re

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parent.parent / "tutorials" / "open-a-kubernetes-zoo-9ad54ae8" / "index.md"


def include(match: re.Match) -> str:
    path, _, flag = match.group(1).partition("|")
    text = (HERE / path).read_text().rstrip("\n")
    if flag == "strip-comments":
        lines = text.splitlines()
        while lines and lines[0].startswith("#"):
            lines.pop(0)
        text = "\n".join(lines)
    return text


template = (HERE / "tutorial.template.md").read_text()
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(re.sub(r"\{\{file:([^}]+)\}\}", include, template))
print(f"wrote {OUT.relative_to(HERE.parent.parent)}")
