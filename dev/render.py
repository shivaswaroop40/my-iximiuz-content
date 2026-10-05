#!/usr/bin/env python3
"""Render both tutorials from their templates.

Each tutorial's template is dev/<name>/tutorial.template.md, and it renders to
tutorials/<slug>/index.md. The files a tutorial ships to the playground live in
folders next to index.md (tutorials/<slug>/<folder>/), plus the odd single file in
__static__/. Those are the source of truth: the harnesses test them, `labctl content
push` packs each folder into __static__/<folder>.tar.gz (leaving out whatever the
folder's own .labctlignore lists), and the template's `startupFiles` unpack them into
the learner's home.

Templates quote that code with directives, and paths are relative to tutorials/<slug>/:

    {{file:PATH}}                      a whole file ({{file:PATH|strip-comments}} drops leading # lines)
    {{excerpt:PATH#from=RE#to=RE}}     a slice of a file, on a line of its own:
                                       from the only line matching `from` through the
                                       first later line matching `to` (`to=EOF` for the end)

Everything, including the generated copy of the finished zoo CRD, is prepared in
memory first, so a broken directive leaves every file untouched. Re-run after editing
a template or any shipped file:

    dev/render.py

Before writing anything it runs dev/lint.py's checks on the result.

`dev/render.py --archive-files DIR` prints the files labctl would pack from DIR, using
labctl's own .labctlignore rules; the operator harness uses it to copy what ships.
"""
import pathlib
import re
import sys

from lint import archive_files, lint

DEV = pathlib.Path(__file__).resolve().parent
TUTORIALS_DIR = DEV.parent / "tutorials"
ZOO = TUTORIALS_DIR / "open-a-kubernetes-zoo-9ad54ae8"
OPERATOR = TUTORIALS_DIR / "build-a-kubernetes-operator-from-scratch-a6eecb2c"
KAGENT = TUTORIALS_DIR / "run-ai-agents-on-kubernetes-with-kagent"

TUTORIALS = [
    # ships: folders packed into __static__/<folder>.tar.gz; static: files the startupFiles fetch as they are.
    {"template": DEV / "open-a-kubernetes-zoo" / "tutorial.template.md", "out": ZOO,
     "ships": ["pet-crd", "pets"], "static": ["pet-api.txt"]},
    {"template": DEV / "build-a-kubernetes-operator" / "tutorial.template.md", "out": OPERATOR,
     "ships": ["pet-operator"], "static": []},
    {"template": DEV / "kagent-smaug-escaped" / "tutorial.template.md", "out": KAGENT,
     "ships": ["detective", "setup"], "static": []},
]

# The operator tutorial uses the zoo's first and finished CRDs, so the two tutorials
# define the same Pet. The archive can't follow a symlink, so it ships real copies.
# Their header is for learners, who only ever see the playground: it names the zoo
# tutorial's file, never this repo's tooling. Edit the zoo file, not the copy.
CRD_COPIES = {
    OPERATOR / "pet-operator" / "config" / "crd-minimal.yaml": (
        ZOO / "pet-crd" / "1-names.yaml",
        '# The first Pet CRD from the "How Kubernetes CRDs Work" tutorial: names only, any spec.',
    ),
    OPERATOR / "pet-operator" / "config" / "crd-by-hand.yaml": (
        ZOO / "pet-crd" / "5-status-and-columns.yaml",
        '# The finished Pet CRD from the "How Kubernetes CRDs Work" tutorial.',
    ),
}


def crd_copy(source: pathlib.Path, title: str) -> str:
    lines = source.read_text().splitlines(keepends=True)
    while lines and lines[0].startswith("#"):
        lines.pop(0)
    header = f"{title}\n# Same as ~/pet-crd/{source.name} in that tutorial's playground.\n"
    return header + "".join(lines)


# Files render.py is about to write, so directives quote the new content.
PENDING: dict[pathlib.Path, str] = {copy: crd_copy(*src) for copy, src in CRD_COPIES.items()}


def read(path: pathlib.Path) -> str:
    path = path.resolve()
    return PENDING[path] if path in PENDING else path.read_text()


EXCERPT = re.compile(r"^(?P<path>[^#]+)#from=(?P<start>.*?)#to=(?P<end>.*)$")


def fail(msg: str) -> None:
    sys.exit(f"render.py: {msg}")


def include(base: pathlib.Path, arg: str) -> str:
    path, _, flag = arg.partition("|")
    text = read(base / path).rstrip("\n")
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
    lines = read(base / path).rstrip("\n").splitlines()
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
    base = t["out"]
    text = t["template"].read_text()
    text = re.sub(r"\{\{file:([^}]+)\}\}", lambda m: include(base, m[1]), text)
    # An excerpt directive is a line of its own, so its regexes may contain "}".
    text = re.sub(r"^\{\{excerpt:(.*)\}\}$", lambda m: excerpt(base, m[1]), text, flags=re.M)
    leftover = re.search(r"\{\{(file|excerpt):.*", text)
    if leftover:
        fail(f"{base.name}: directive not rendered (is it on a line of its own?): {leftover[0]}")
    front_matter = text.split("\n---\n", 1)[0]
    pushed = archive_files(base)
    for ship_dir in t["ships"]:
        if f"source: __static__/{ship_dir}.tar.gz" not in front_matter:
            fail(f"{base.name}: the front matter's startupFiles must declare `source: __static__/{ship_dir}.tar.gz`")
        if not (base / ship_dir).is_dir():
            fail(f"{base.name}: the shipped folder {ship_dir}/ is missing")
        if any((base / ship_dir) in f.parents for f in pushed):
            fail(f"{base.name}/.labctlignore must exclude {ship_dir}/, or push uploads its raw files too")
        shipped = archive_files(base / ship_dir)
        if any(f.name == ".DS_Store" for f in shipped):
            fail(f"{base.name}/{ship_dir}: a .DS_Store would ship to learners; add it to {ship_dir}/.labctlignore")
    for name in t["static"]:
        if f"source: __static__/{name}" not in front_matter or not (base / "__static__" / name).is_file():
            fail(f"{base.name}: __static__/{name} must exist and be declared as a startupFiles source")
    return text


if sys.argv[1:2] == ["--archive-files"]:
    folder = pathlib.Path(sys.argv[2]).resolve()
    print("\n".join(f.relative_to(folder).as_posix() for f in archive_files(folder)))
    sys.exit(0)

for t in TUTORIALS:
    PENDING[(t["out"] / "index.md").resolve()] = render(t)
# dev/lint.py's checks (what learners see, startupFiles, cover, IDE folder) on the pending
# text, so a failure still leaves every file untouched.
problems = [e for t in TUTORIALS for e in lint(t["out"], PENDING)]
if problems:
    fail("dev/lint.py found problems:\n  " + "\n  ".join(problems))
for path, text in PENDING.items():
    if not path.exists() or path.read_text() != text:
        path.write_text(text)
        print(f"wrote {path.relative_to(DEV.parent)}")
