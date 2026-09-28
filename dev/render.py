#!/usr/bin/env python3
"""Render both tutorials from their templates, and the files their playgrounds ship.

Each tutorial lives in dev/<name>/tutorial.template.md. Code in it comes from the
tested files next to the template:

    {{file:PATH}}                      a whole file ({{file:PATH|strip-comments}} drops leading # lines)
    {{excerpt:PATH#from=RE#to=RE}}     a slice of a file, on a line of its own:
                                       from the only line matching `from` through the
                                       first later line matching `to` (`to=EOF` for the end)

The full files ship to the playground at startup: they're copied into
tutorials/<slug>/<ship dir>/, which `labctl content push` packs into
__static__/<ship dir>.tar.gz for the template's `startupFiles` to unpack.

Everything is rendered in memory first, so a broken directive leaves the
published files untouched. Re-run after editing a template or a tested file:

    dev/render.py
"""
import pathlib
import re
import shutil
import sys
import tempfile

DEV = pathlib.Path(__file__).resolve().parent
ROOT = DEV.parent

TUTORIALS = [
    {
        "src": DEV / "open-a-kubernetes-zoo",
        "slug": "open-a-kubernetes-zoo-9ad54ae8",
        "ship_dir": "pet-crd",
        "ship": {f"crd/{n}": n for n in ["1-names.yaml", "2-schema.yaml", "3-rules.yaml",
                                          "4-defaults.yaml", "5-status-and-columns.yaml"]},
    },
    {
        "src": DEV / "build-a-kubernetes-operator",
        "slug": "build-a-kubernetes-operator-from-scratch-a6eecb2c",
        "ship_dir": "pet-operator",
        # zz_generated.deepcopy.go and the generated CRD are left out on purpose:
        # the learner runs controller-gen to produce them.
        "ship": {
            "pet-operator/go.mod": "go.mod",
            "pet-operator/go.sum": "go.sum",
            "pet-operator/main.go": "main.go",
            "pet-operator/api/v1alpha1/groupversion_info.go": "api/v1alpha1/groupversion_info.go",
            "pet-operator/api/v1alpha1/pet_types.go": "api/v1alpha1/pet_types.go",
            "pet-operator/internal/controller/pet_controller.go": "internal/controller/pet_controller.go",
            "../open-a-kubernetes-zoo/crd/5-status-and-columns.yaml": "config/crd-by-hand.yaml",
            "bash/naive-controller.sh": "bash/naive-controller.sh",
        },
    },
]

EXCERPT = re.compile(r"^(?P<path>[^#]+)#from=(?P<start>.*?)#to=(?P<end>.*)$")


def fail(msg: str) -> None:
    sys.exit(f"render.py: {msg}")


def include(src: pathlib.Path, arg: str) -> str:
    path, _, flag = arg.partition("|")
    text = (src / path).read_text().rstrip("\n")
    if flag == "strip-comments":
        lines = text.splitlines()
        while lines and lines[0].startswith("#"):
            lines.pop(0)
        text = "\n".join(lines)
    return text


def excerpt(src: pathlib.Path, arg: str) -> str:
    m = EXCERPT.match(arg)
    if not m:
        fail(f"excerpt {arg!r}: expected PATH#from=REGEX#to=REGEX (or #to=EOF)")
    path, start_re, end_re = m["path"], m["start"], m["end"]
    lines = (src / path).read_text().rstrip("\n").splitlines()
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
    src = t["src"]
    text = (src / "tutorial.template.md").read_text()
    text = re.sub(r"\{\{file:([^}]+)\}\}", lambda m: include(src, m[1]), text)
    # An excerpt directive is a line of its own, so its regexes may contain "}".
    text = re.sub(r"^\{\{excerpt:(.*)\}\}$", lambda m: excerpt(src, m[1]), text, flags=re.M)
    leftover = re.search(r"\{\{(file|excerpt):.*", text)
    if leftover:
        fail(f"{t['slug']}: directive not rendered (is it on a line of its own?): {leftover[0]}")
    source = f"source: __static__/{t['ship_dir']}.tar.gz"
    if source not in text.split("\n---\n", 1)[0]:
        fail(f"{t['slug']}: the front matter's startupFiles must declare `{source}`")
    return text


def write(t: dict, text: str) -> None:
    out = ROOT / "tutorials" / t["slug"]
    out.mkdir(parents=True, exist_ok=True)
    # Build the shipped folder next to its destination, then swap it in.
    staged = pathlib.Path(tempfile.mkdtemp(dir=out))
    try:
        for src_rel, dest_rel in t["ship"].items():
            target = staged / dest_rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(t["src"] / src_rel, target)
        dest = out / t["ship_dir"]
        shutil.rmtree(dest, ignore_errors=True)
        staged.rename(dest)
    finally:
        shutil.rmtree(staged, ignore_errors=True)
    # labctl packs the folder into __static__/<ship dir>.tar.gz; keep the raw files out of the push.
    (out / ".labctlignore").write_text(f"{t['ship_dir']}\n")
    (out / "index.md").write_text(text)
    print(f"wrote tutorials/{t['slug']}/index.md and {t['ship_dir']}/")


rendered = [(t, render(t)) for t in TUTORIALS]  # fails before anything is written
for t, text in rendered:
    write(t, text)
