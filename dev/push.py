#!/usr/bin/env python3
"""Publish one content folder to iximiuz Labs, safely.

    dev/push.py tutorials/<slug>
    dev/push.py challenges/<slug>

1. Runs dev/lint.py on the folder and stops on any problem.
2. Packs every startupFiles `source: __static__/<folder>.tar.gz` that has a <folder>/ next to
   index.md, with labctl's .labctlignore rules. labctl 0.1.107 doesn't do this itself: with
   --force, it deletes the remote archive (absent locally, as *.tar.gz is gitignored) and
   uploads nothing, so the playground starts without the shipped files. That happened once.
3. `labctl content push <kind> <slug> --dir <folder> --force`.
4. Pulls the content back into a temp dir and fails unless every local file, archives
   included, is on Labs byte for byte, and nothing else is.
"""
import filecmp
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile

from lint import ROOT, archive_files, lint, split_front_matter


def pack(base: pathlib.Path) -> None:
    fm, _, _ = split_front_matter((base / "index.md").read_text())
    for f in (fm.get("playground") or {}).get("startupFiles") or []:
        m = re.fullmatch(r"__static__/(.+)\.tar\.gz", str(f.get("source", "")))
        if not m or not (base / m[1]).is_dir():
            continue
        folder, out = base / m[1], base / f["source"]

        def clean(ti):
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            return ti

        with tarfile.open(out, "w:gz", format=tarfile.PAX_FORMAT) as tf:
            for p in archive_files(folder):
                tf.add(p, arcname=p.relative_to(folder).as_posix(), filter=clean)
        print(f"packed {out.relative_to(ROOT)} ({len(archive_files(folder))} files)")


def pushed_files(base: pathlib.Path) -> set[str]:
    return {p.relative_to(base).as_posix() for p in archive_files(base) if p.name != ".DS_Store"}


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    base = pathlib.Path(sys.argv[1]).resolve()
    kind = {"tutorials": "tutorial", "challenges": "challenge"}.get(base.parent.name)
    if not kind:
        sys.exit(f"push.py: {sys.argv[1]} is not under tutorials/ or challenges/")

    problems = lint(base)
    if problems:
        print("\n".join(problems), file=sys.stderr)
        sys.exit("push.py: fix the lint problems first")
    pack(base)

    subprocess.run(["labctl", "content", "push", kind, base.name, "--dir", str(base), "--force"], check=True)

    with tempfile.TemporaryDirectory() as tmp:
        remote = pathlib.Path(tmp)
        subprocess.run(["labctl", "content", "pull", kind, base.name, "--dir", str(remote)],
                       check=True, stdout=subprocess.DEVNULL)
        local = pushed_files(base)
        got = {p.relative_to(remote).as_posix() for p in remote.rglob("*") if p.is_file()}
        bad = [f"missing on Labs: {f}" for f in sorted(local - got)]
        bad += [f"only on Labs: {f}" for f in sorted(got - local)]
        bad += [f"differs on Labs: {f}" for f in sorted(local & got)
                if not filecmp.cmp(base / f, remote / f, shallow=False)]
        if bad:
            print("\n".join(bad), file=sys.stderr)
            sys.exit("push.py: Labs doesn't match the repo")
    print(f"push.py: {kind} {base.name} is on Labs and matches the repo ({len(local)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
