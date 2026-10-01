#!/usr/bin/env python3
"""Check content folders before `labctl content push`.

    dev/lint.py                       every folder under tutorials/ and challenges/
    dev/lint.py challenges/<slug> ... only those folders

It checks what a learner gets: the page (index.md, front matter included, since task
hints are shown too), the text files in __static__/, and every folder that ships to the
playground as __static__/<folder>.tar.gz, packed with labctl's own .labctlignore rules.
solution.md and .solution.sh stay out of it: Labs only shows them to the author.

Exit status is 1 if anything fails. Every rule here comes from a mistake that reached a
reviewer once; AGENTS.md says why each one exists.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Learners only see the page and the playground. Anything naming this repo's tooling is a
# dead reference for them. The lookbehind lets /dev/null, controller-tools/ and the like through.
REPO_ONLY = re.compile(
    r"(?<![-/\w.~])(dev|tools|docs)/[\w.-]"
    r"|render\.py|lint\.py|run-tests|tutorial\.template|\bharness(es)?\b|labctlignore|\.solution\.sh"
    r"|my-iximiuz-content",
    re.I,
)
# Images on the page: markdown ![alt](__static__/x.png) or an ::image-box with `:src: __static__/x.png`.
IMAGE = re.compile(r"\]\((__static__/[^)\s]+\.(?:png|svg|jpe?g|gif|webp))\)|^:?src: (__static__/\S+\.(?:png|svg|jpe?g|gif|webp))\s*$", re.M)
# Drafting leftovers.
UNFINISHED = re.compile(r"\b(TODO|FIXME|XXX|TBD)\b|lorem ipsum|\{\{(file|excerpt):")


# labctl's .labctlignore rules (cmd/content/push.go: listFiles, matchesIgnorePatterns).
def go_match(pattern: str, name: str) -> bool:
    """Go's filepath.Match: * and ? never match a /."""
    rx = "".join("[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c) for c in pattern)
    return re.fullmatch(rx, name) is not None


def ignore_patterns(d: pathlib.Path) -> list[str]:
    f = d / ".labctlignore"
    if not f.exists():
        return []
    return [line.strip() for line in f.read_text().splitlines() if line.strip() and not line.strip().startswith("#")]


def ignored(rule_sets: list, path: pathlib.Path, is_dir: bool) -> bool:
    for base, patterns in rule_sets:
        rel = path.relative_to(base).as_posix()
        for pattern in patterns:
            if pattern.endswith("/") and not is_dir:
                continue
            p = pattern.rstrip("/")
            if go_match(p, rel if "/" in p else path.name):
                return True
    return False


def archive_files(folder: pathlib.Path, rule_sets=None) -> list[pathlib.Path]:
    """The files labctl packs (or pushes) from folder, in labctl's order of rules."""
    rule_sets = (rule_sets or []) + ([(folder, ignore_patterns(folder))] if ignore_patterns(folder) else [])
    files = []
    for entry in sorted(folder.iterdir()):
        if entry.name.startswith(".git") or entry.name.endswith("~") or entry.name == ".labctlignore":
            continue
        if ignored(rule_sets, entry, entry.is_dir()):
            continue
        files += archive_files(entry, rule_sets) if entry.is_dir() else [entry]
    return files


def split_front_matter(text: str) -> tuple[dict, str, str]:
    import yaml
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return {}, "", text
    return yaml.safe_load(m[1]) or {}, m[1], text[m.end():]


def scan_text(errors: list, name: str, text: str) -> None:
    for n, line in enumerate(text.splitlines(), 1):
        m = REPO_ONLY.search(line)
        if m:
            errors.append(f"{name}:{n}: {m[0]!r} only exists in this repo, learners can't see it: {line.strip()}")
        m = UNFINISHED.search(line)
        if m:
            errors.append(f"{name}:{n}: unfinished draft text {m[0]!r}: {line.strip()}")


def read_text(path: pathlib.Path, overrides: dict) -> str | None:
    if path.resolve() in overrides:
        return overrides[path.resolve()]
    try:
        return path.read_text()
    except UnicodeDecodeError:
        return None  # binary: images, archives


def lint(base: pathlib.Path, overrides: dict | None = None) -> list[str]:
    """Problems with one content folder. overrides maps paths to text not written yet (render.py)."""
    overrides = overrides or {}
    errors: list[str] = []
    rel = base.relative_to(ROOT) if base.is_relative_to(ROOT) else base
    index = base / "index.md"
    page = read_text(index, overrides)
    if page is None or not (index.exists() or index.resolve() in overrides):
        return [f"{rel}: no index.md"]
    fm, fm_text, body = split_front_matter(page)
    if not fm:
        return [f"{rel}/index.md: no front matter"]
    kind = fm.get("kind")
    static = base / "__static__"

    # 1. The page and everything it ships say nothing about this repo.
    scan_text(errors, f"{rel}/index.md", page)
    if static.is_dir():
        for f in sorted(static.iterdir()):
            if f.suffix == ".md":
                errors.append(f"{rel}/__static__/{f.name}: Labs parses any .md in __static__ as content and rejects it; rename it (e.g. to .txt)")
            if f.is_file() and f.name != "WARNING.txt" and (text := read_text(f, overrides)) is not None:
                scan_text(errors, f"{rel}/__static__/{f.name}", text)

    # 2. The cover exists, and a tutorial uses one of its own diagrams.
    cover = fm.get("cover")
    if not cover or not (base / cover).is_file():
        errors.append(f"{rel}: `cover: {cover}` must point at an existing file")
    else:
        embedded = set(m[0] or m[1] for m in re.findall(IMAGE, body))
        if kind == "tutorial" and embedded and cover not in embedded:
            errors.append(f"{rel}: the cover is {cover}, but tutorials use one of the diagrams on the page as cover: {', '.join(sorted(embedded))}")

    # 3. Every image the page embeds exists.
    for src in (m[0] or m[1] for m in re.findall(IMAGE, body)):
        if not (base / src).is_file():
            errors.append(f"{rel}/index.md: embeds {src}, which doesn't exist")

    # 4. startupFiles: Labs' push rules, the archives labctl builds, and the IDE folder.
    startup = (fm.get("playground") or {}).get("startupFiles") or []
    pushed = archive_files(base)
    extracted_home_dirs = []
    code_server = None
    for i, f in enumerate(startup):
        where = f"{rel}: startupFiles[{i}] ({f.get('path')})"
        if not str(f.get("path", "")).startswith("/"):
            errors.append(f"{where}: path must be absolute")
        if f.get("extract"):
            if str(f.get("path", "")).startswith("/home/laborant/"):
                extracted_home_dirs.append(f["path"])
            if f.get("owner") is None and str(f.get("path", "")).startswith("/home/"):
                errors.append(f"{where}: an archive extracted into a home directory needs `owner: laborant`, or it lands root-owned")
        elif not f.get("append") and not ("owner" in f and "mode" in f):
            errors.append(f"{where}: needs `append`, or both `owner` and `mode`")
        if f.get("path") == "/etc/default/code-server":
            code_server = f.get("content", "")
        src = f.get("source", "")
        if src.startswith("__static__/"):
            m = re.fullmatch(r"__static__/(.+)\.(tar\.gz|tgz|tar)", src)
            folder = base / m[1] if m else None
            if folder and folder.is_dir():
                if any(folder in p.parents for p in pushed):
                    errors.append(f"{rel}/.labctlignore must list {m[1]}, or push uploads its raw files too")
                for p in archive_files(folder):
                    if p.name == ".DS_Store":
                        errors.append(f"{rel}/{m[1]}: a .DS_Store would ship; add it to {m[1]}/.labctlignore")
                    elif (text := read_text(p, overrides)) is not None:
                        scan_text(errors, f"{rel}/{p.relative_to(base)}", text)
            elif not (base / src).is_file():
                errors.append(f"{where}: source {src} doesn't exist (and no {src.split('/')[1].split('.')[0]}/ folder to pack it from)")
    if len(startup) > 20:
        errors.append(f"{rel}: {len(startup)} startupFiles, Labs allows at most 20")
    # The IDE opens ~ unless told otherwise. If the learner works in one shipped project, open that.
    if len(extracted_home_dirs) == 1 and not (code_server and f"CODE_SERVER_PATH={extracted_home_dirs[0]}" in code_server):
        errors.append(
            f"{rel}: the playground ships one project to {extracted_home_dirs[0]}; add a startupFiles entry "
            f"`path: /etc/default/code-server` with `CODE_SERVER_PATH={extracted_home_dirs[0]}` (owner root, mode \"644\") so the IDE opens it"
        )

    # 5. Every task script parses.
    for name, task in (fm.get("tasks") or {}).items():
        for key in ("run", "hintcheck"):
            script = (task or {}).get(key)
            if script:
                r = subprocess.run(["bash", "-n"], input=script, text=True, capture_output=True)
                if r.returncode:
                    errors.append(f"{rel}: tasks.{name}.{key} has a bash syntax error: {r.stderr.strip()}")

    # 6. Dates.
    if fm.get("createdAt") and fm.get("updatedAt") and str(fm["updatedAt"]) < str(fm["createdAt"]):
        errors.append(f"{rel}: updatedAt is before createdAt")
    return errors


def main(args: list[str]) -> int:
    dirs = [pathlib.Path(a).resolve() for a in args] or sorted(
        d for kind in ("tutorials", "challenges") for d in (ROOT / kind).iterdir() if d.is_dir()
    )
    errors = [e for d in dirs for e in lint(d)]
    for e in errors:
        print(e, file=sys.stderr)
    print(f"lint: {len(dirs)} folder(s), {len(errors)} problem(s)", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
