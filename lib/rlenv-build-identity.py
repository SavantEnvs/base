#!/usr/bin/python3 -I
"""
Prints the primary harness's path and its build identity (rlenv.build.identity).

Installed as /opt/mayhem/bin/rlenv-build-identity. Run it in a built image:
  docker run --rm --entrypoint /opt/mayhem/bin/rlenv-build-identity IMAGE
REPO is the checkout in the image (default /mayhem).

The primary harness: the first instrumented cmd (`libfuzzer`, `afl` or `honggfuzz` true) of the first
REPO/mayhem/Mayhemfile* in byte order, else that file's first cmd. Its argv[0] is resolved the way the
cmd would resolve it (its cwd, then PATH), with the cmd's own `env:` LD_LIBRARY_PATH and PATH applied.

The identity is sha256 over the contents (not paths) of the harness, its ELF interpreter and the
non-system shared libraries the loader resolves for it (`ldd`; those under /lib and /usr/lib don't
count). For a #! script: the script plus its interpreter's closure. It follows rlenv's reference
script step for step; any difference shows up as a mismatch with rlenv's own computation.

Exit 0: two lines on stdout (path, sha256:<hex>). Exit 1: nothing on stdout, the reason on stderr.
Absolute python3 and -I: the image's own PATH and PYTHONPATH mustn't pick the interpreter or its modules.
"""
import argparse
import hashlib
import os
import shlex
import subprocess
import sys

import yaml

INSTRUMENTED = ("libfuzzer", "afl", "honggfuzz")
SYSTEM = ("/lib/", "/lib64/", "/lib32/", "/libx32/", "/usr/lib/", "/usr/lib64/", "/usr/lib32/")


class NotMeasured(Exception):
    pass


def primary_mayhemfile(repo):
    d = os.path.join(repo, "mayhem")
    try:
        names = sorted(n for n in os.listdir(d) if n.startswith("Mayhemfile") and os.path.isfile(os.path.join(d, n)))
    except FileNotFoundError:
        names = []
    if not names:
        raise NotMeasured(f"no {d}/Mayhemfile*")
    return os.path.join(d, names[0])


def is_true(v):
    return v is True or str(v).lower() == "true"


def primary_cmd(doc):
    if not isinstance(doc, dict):
        raise NotMeasured("not a YAML mapping")
    entries = doc["cmds"] if isinstance(doc.get("cmds"), list) else [doc]  # old form: one top-level cmd
    entries = [e for e in entries if isinstance(e, dict) and e.get("cmd") is not None]
    if not entries:
        raise NotMeasured("no cmds[].cmd")
    return next((e for e in entries if any(is_true(e.get(k)) for k in INSTRUMENTED)), entries[0])


def select(repo):
    """The primary harness: {mayhemfile, argv0, cwd, LD_LIBRARY_PATH, PATH}, empty strings when unset."""
    mayhemfile = primary_mayhemfile(repo)
    try:
        with open(mayhemfile) as f:
            doc = yaml.safe_load(f)
    except yaml.YAMLError as e:
        raise NotMeasured(f"{mayhemfile}: could not parse YAML: {e}")
    entry = primary_cmd(doc)
    try:
        words = shlex.split(str(entry["cmd"]))
    except ValueError as e:
        raise NotMeasured(f"{mayhemfile}: could not split cmd {entry['cmd']!r}: {e}")
    if not words:
        raise NotMeasured(f"{mayhemfile}: empty cmd")
    env = entry.get("env") if isinstance(entry.get("env"), dict) else {}
    return {"mayhemfile": mayhemfile, "argv0": words[0], "cwd": str(entry.get("cwd") or ""),
            "LD_LIBRARY_PATH": str(env.get("LD_LIBRARY_PATH") or ""), "PATH": str(env.get("PATH") or "")}


def resolve(argv0, path):
    """argv0 as the cmd would find it: with a / it's a path (relative to the cwd), else the first
    executable file of that name on PATH (an empty PATH entry is the cwd)."""
    if "/" in argv0:
        return argv0
    for d in path.split(":"):
        f = os.path.join(d or ".", argv0)
        if os.path.isfile(f) and os.access(f, os.X_OK):
            return f
    raise NotMeasured(f"unresolved argv0: {argv0}")


def closure(f, env):
    """f, plus its ELF interpreter and non-system libraries as `ldd` resolves them, after symlinks."""
    p = subprocess.run(["ldd", f], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    out = p.stdout
    if p.returncode != 0:
        if "not a dynamic executable" not in out and "statically linked" not in out:
            raise NotMeasured(out.strip())
        out = ""
    if "not found" in out:
        raise NotMeasured(f"unresolved library:\n{out.strip()}")
    files = [f]
    for line in out.splitlines():
        w = line.split()
        if w and w[0].startswith("/"):  # the interpreter, or a library NEEDED by absolute path
            files.append(os.path.realpath(w[0]))
        if len(w) >= 3 and w[1] == "=>" and w[2].startswith("/"):
            lib = os.path.realpath(w[2])
            if not lib.startswith(SYSTEM):
                files.append(lib)
    return files


def identity(exe, env):
    """sha256:<hex> over exe's closure: sort the files' hex digests, join with \\n, sha256 that."""
    with open(exe, "rb") as f:
        script = f.read(2) == b"#!"
    if script:
        with open(exe, "rb") as f:
            words = f.readline()[2:].decode(errors="surrogateescape").split()
        interp = os.path.realpath(words[0]) if words else ""
        if not os.path.isfile(interp):
            raise NotMeasured(f"unresolved interpreter: {words[0] if words else ''}")
        files = [exe, *closure(interp, env)]
    else:
        files = closure(exe, env)
    digests = []
    for path in sorted(set(files)):  # each file once; equal contents at two paths still count twice
        with open(path, "rb") as f:
            digests.append(hashlib.sha256(f.read()).hexdigest())
    return "sha256:" + hashlib.sha256("\n".join(sorted(digests)).encode()).hexdigest()


def measure(repo):
    """(the selection, the resolved harness path, sha256:<hex>), or raise NotMeasured."""
    sel = select(repo)
    env = dict(os.environ, **{k: sel[k] for k in ("LD_LIBRARY_PATH", "PATH") if sel[k]})
    try:
        if sel["cwd"]:
            os.chdir(sel["cwd"])
        exe = os.path.realpath(resolve(sel["argv0"], env.get("PATH", "/usr/bin:/bin")))
        if not os.path.isfile(exe):
            raise NotMeasured(f"no such file: {sel['argv0']}")
        return sel, exe, identity(exe, env)
    except OSError as e:
        raise NotMeasured(str(e))


def main(argv):
    ap = argparse.ArgumentParser(prog="rlenv-build-identity", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("repo", nargs="?", default="/mayhem", help="the checkout in the image (default: %(default)s)")
    args = ap.parse_args(argv)
    try:
        sel, exe, ident = measure(os.path.abspath(args.repo))
    except NotMeasured as e:
        print(f"rlenv-build-identity: {e}", file=sys.stderr)
        return 1
    print(f"rlenv-build-identity: primary harness {sel['argv0']} of {sel['mayhemfile']}", file=sys.stderr)
    print(exe)
    print(ident)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
