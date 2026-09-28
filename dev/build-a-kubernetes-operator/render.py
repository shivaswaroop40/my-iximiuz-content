#!/usr/bin/env python3
"""Render tutorial.template.md into the published tutorial.

Code in the tutorial comes from the tested reference files in this directory:
{{file:path}} includes a whole file and {{excerpt:path#from=RE#to=RE}} a slice of one.
The full files ship to the playground at startup: ship() copies them into the
tutorial's pet-operator/ folder, which labctl packs into __static__/pet-operator.tar.gz
on every push. Re-run after editing either side:

    dev/build-a-kubernetes-operator/render.py
"""
import pathlib
import re
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parent.parent / "tutorials" / "build-a-kubernetes-operator-from-scratch-a6eecb2c" / "index.md"
SHIP_DIR = "pet-operator"
# Files the learner finds in ~/pet-operator. zz_generated.deepcopy.go and the generated
# CRD are left out on purpose: the learner runs controller-gen to produce them.
SHIP = {
    "pet-operator/go.mod": "go.mod",
    "pet-operator/go.sum": "go.sum",
    "pet-operator/main.go": "main.go",
    "pet-operator/api/v1alpha1/groupversion_info.go": "api/v1alpha1/groupversion_info.go",
    "pet-operator/api/v1alpha1/pet_types.go": "api/v1alpha1/pet_types.go",
    "pet-operator/internal/controller/pet_controller.go": "internal/controller/pet_controller.go",
    "../open-a-kubernetes-zoo/crd/5-status-and-columns.yaml": "config/crd-by-hand.yaml",
    "bash/naive-controller.sh": "bash/naive-controller.sh",
}


def include(match: re.Match) -> str:
    path, _, flag = match.group(1).partition("|")
    text = (HERE / path).read_text().rstrip("\n")
    if flag == "strip-comments":
        lines = text.splitlines()
        while lines and lines[0].startswith("#"):
            lines.pop(0)
        text = "\n".join(lines)
    return text


def excerpt(match: re.Match) -> str:
    """{{excerpt:PATH#from=REGEX#to=REGEX}}: the lines of PATH from the first line
    matching `from` through the first line after it matching `to` (or the end of the
    file if `to` is omitted). Fails loudly if a regex stops matching, so an excerpt
    can't silently drift from the code the playground ships."""
    path, *opts = match.group(1).split("#")
    opt = dict(o.split("=", 1) for o in opts)
    lines = (HERE / path).read_text().rstrip("\n").splitlines()
    start = next((i for i, l in enumerate(lines) if re.search(opt["from"], l)), None)
    if start is None:
        sys.exit(f"excerpt {path}: no line matches from={opt['from']!r}")
    end = len(lines) - 1
    if "to" in opt:
        end = next((i for i in range(start, len(lines)) if re.search(opt["to"], lines[i])), None)
        if end is None:
            sys.exit(f"excerpt {path}: no line after {start + 1} matches to={opt['to']!r}")
    return "\n".join(lines[start:end + 1])


def ship() -> None:
    """Copy the files the playground starts with into the tutorial's archive folder."""
    dest = OUT.parent / SHIP_DIR
    shutil.rmtree(dest, ignore_errors=True)
    for src, rel in SHIP.items():
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(HERE / src, target)


template = (HERE / "tutorial.template.md").read_text()
ship()
text = re.sub(r"\{\{file:([^}]+)\}\}", include, template)
# An excerpt directive is a line of its own, so its regexes may contain "}".
text = re.sub(r"^\{\{excerpt:(.*)\}\}$", excerpt, text, flags=re.M)
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(text)
print(f"wrote {OUT.relative_to(HERE.parent.parent)} and {SHIP_DIR}/")
