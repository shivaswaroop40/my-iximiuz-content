#!/usr/bin/env python3
"""Render both tutorials from their templates.

Each tutorial's template is dev/<name>/tutorial.template.md, and it renders to
tutorials/<slug>/index.md. The code a tutorial ships to the playground lives in a
folder next to index.md (tutorials/<slug>/<ship dir>/). That folder is the source
of truth: the harnesses test it, `labctl content push` packs it into
__static__/<ship dir>.tar.gz (leaving out whatever the folder's own .labctlignore
lists), and the template's `startupFiles` unpack it into the learner's home.

Templates quote that code with directives, and paths are relative to tutorials/<slug>/:

    {{file:PATH}}                      a whole file ({{file:PATH|strip-comments}} drops leading # lines)
    {{excerpt:PATH#from=RE#to=RE}}     a slice of a file, on a line of its own:
                                       from the only line matching `from` through the
                                       first later line matching `to` (`to=EOF` for the end)

Everything is rendered in memory first, so a broken directive leaves the published
files untouched. Re-run after editing a template or any shipped file:

    dev/render.py
"""
import pathlib
import re
import shutil
import sys

DEV = pathlib.Path(__file__).resolve().parent
TUTORIALS_DIR = DEV.parent / "tutorials"
ZOO = TUTORIALS_DIR / "open-a-kubernetes-zoo-9ad54ae8"
OPERATOR = TUTORIALS_DIR / "build-a-kubernetes-operator-from-scratch-a6eecb2c"

TUTORIALS = [
    {"template": DEV / "open-a-kubernetes-zoo" / "tutorial.template.md", "out": ZOO, "ship_dir": "pet-crd"},
    {"template": DEV / "build-a-kubernetes-operator" / "tutorial.template.md", "out": OPERATOR, "ship_dir": "pet-operator"},
]

# The operator tutorial starts from the finished zoo CRD. The archive can't follow a
# symlink, so it ships a real copy.
COPIES = {ZOO / "pet-crd" / "5-status-and-columns.yaml": OPERATOR / "pet-operator" / "config" / "crd-by-hand.yaml"}

EXCERPT = re.compile(r"^(?P<path>[^#]+)#from=(?P<start>.*?)#to=(?P<end>.*)$")


def fail(msg: str) -> None:
    sys.exit(f"render.py: {msg}")


def include(base: pathlib.Path, arg: str) -> str:
    path, _, flag = arg.partition("|")
    text = (base / path).read_text().rstrip("\n")
    if flag == "strip-comments":
        lines = text.splitlines()
        while lines and lines[0].startswith("#"):
            lines.pop(0)
        text = "\n".join(lines)
    return text


def excerpt(base: pathlib.Path, arg: str) -> str:
    m = EXCERPT.match(arg)
    if not m:
        fail(f"excerpt {arg!r}: expected PATH#from=REGEX#to=REGEX (or #to=EOF)")
    path, start_re, end_re = m["path"], m["start"], m["end"]
    lines = (base / path).read_text().rstrip("\n").splitlines()
    starts = [i for i, line in enumerate(lines) if re.search(start_re, line)]
    if len(starts) != 1:
        fail(f"excerpt {path}: from={start_re!r} matches {len(starts)} lines, it must match exactly one")
    start = starts[0]
    if end_re == "EOF":
        end = len(lines) - 1
    else:
        end = next((i for i in range(start + 1, len(lines)) if re.search(end_re, lines[i])), None)
        if end is None:
            fail(f"excerpt {path}: no line after {start + 1} matches to={end_re!r}")
    return "\n".join(lines[start:end + 1])


def render(t: dict) -> str:
    base, ship_dir = t["out"], t["ship_dir"]
    text = t["template"].read_text()
    text = re.sub(r"\{\{file:([^}]+)\}\}", lambda m: include(base, m[1]), text)
    # An excerpt directive is a line of its own, so its regexes may contain "}".
    text = re.sub(r"^\{\{excerpt:(.*)\}\}$", lambda m: excerpt(base, m[1]), text, flags=re.M)
    leftover = re.search(r"\{\{(file|excerpt):.*", text)
    if leftover:
        fail(f"{base.name}: directive not rendered (is it on a line of its own?): {leftover[0]}")
    source = f"source: __static__/{ship_dir}.tar.gz"
    if source not in text.split("\n---\n", 1)[0]:
        fail(f"{base.name}: the front matter's startupFiles must declare `{source}`")
    if not (base / ship_dir).is_dir():
        fail(f"{base.name}: the shipped folder {ship_dir}/ is missing")
    ignore = (base / ".labctlignore").read_text().split() if (base / ".labctlignore").exists() else []
    if ship_dir not in ignore:
        fail(f"{base.name}/.labctlignore must list {ship_dir}, or push uploads its raw files too")
    return text


for src, dest in COPIES.items():
    if not dest.exists() or dest.read_bytes() != src.read_bytes():
        shutil.copy2(src, dest)
rendered = [(t, render(t)) for t in TUTORIALS]  # fails before any index.md is written
for t, text in rendered:
    (t["out"] / "index.md").write_text(text)
    print(f"wrote tutorials/{t['out'].name}/index.md")
