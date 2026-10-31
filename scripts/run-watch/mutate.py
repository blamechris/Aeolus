"""Mutated copies of the watcher, for the dry run's D4 and the unit tests' kill sweep.

A mutation here is a function of the watcher's source: blank one function (its body becomes a
bare `return`), or replace one function by another text. The result is written to a private
directory, never into the working tree, and each step proves it did what it claims: the function
was found exactly once, the copy differs from the original, and the copy still compiles. The
caller proves the copy still runs by firing a control injection at it.

One sweep at a time: a sweep takes a lock file in the directory and a second one refuses."""

from __future__ import annotations

import ast
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


def blank_function(source, name):
    """`source` with the body of the one function called `name` replaced by `return`."""
    tree = ast.parse(source)
    found = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == name]
    if len(found) != 1:
        raise LookupError("%s: %d definitions found, expected exactly one" % (name, len(found)))
    found[0].body = [ast.Return(value=None)]
    ast.fix_missing_locations(tree)
    return ast.unparse(tree) + "\n"


def replace_function(source, name, replacement):
    """`source` with the one function called `name` replaced by the function in `replacement`."""
    tree = ast.parse(source)
    found = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == name]
    new = [n for n in ast.parse(replacement).body if isinstance(n, ast.FunctionDef)]
    if len(found) != 1 or len(new) != 1:
        raise LookupError("%s: cannot replace (%d found, %d given)" % (name, len(found), len(new)))
    found[0].body = new[0].body
    ast.fix_missing_locations(tree)
    return ast.unparse(tree) + "\n"


class Sweep:
    """A private directory of mutated copies, held under a lock for the sweep's length."""

    def __init__(self, directory):
        self.directory = os.path.abspath(directory)
        real = os.path.realpath(self.directory)
        if real == REPO or real.startswith(REPO + os.sep):
            raise SystemExit("refusing a mutation directory inside the working tree: %s" % real)
        os.makedirs(self.directory, exist_ok=True)
        self.lock = os.path.join(self.directory, ".sweep.lock")

    def __enter__(self):
        try:
            fd = os.open(self.lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            raise SystemExit(
                "another sweep holds %s (pid %s); one sweep at a time" % (
                    self.lock, open(self.lock).read().strip() or "?"))
        os.write(fd, ("%d\n" % os.getpid()).encode())
        os.close(fd)
        return self

    def __exit__(self, *exc):
        os.unlink(self.lock)

    def make(self, label, mutate, files=("run_watch.py",)):
        """Write a copy of the tool's sources into `<directory>/<label>/` with `mutate` applied to
        run_watch.py. Returns the path of the mutated run_watch.py."""
        target = os.path.join(self.directory, label)
        os.makedirs(target, exist_ok=True)
        original = None
        for name in sorted(os.listdir(HERE)):
            if not name.endswith(".py") or name in ("mutate.py", "dryrun.py"):
                continue
            with open(os.path.join(HERE, name), encoding="utf-8") as handle:
                text = handle.read()
            if name == "run_watch.py":
                original, text = text, mutate(text)
            with open(os.path.join(target, name), "w", encoding="utf-8") as handle:
                handle.write(text)
        mutated = os.path.join(target, "run_watch.py")
        with open(mutated, encoding="utf-8") as handle:
            changed = handle.read()
        if changed == original:
            raise AssertionError("%s: the mutation changed nothing" % label)
        compile(changed, mutated, "exec")
        return mutated


def run_unit_tests(directory, python=sys.executable, timeout=600):
    """Run the unit tests inside a mutated copy; returns (exit code, the last lines of output)."""
    result = subprocess.run(
        [python, "-I", "-m", "unittest"], cwd=directory, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, check=False)
    text = result.stdout.decode("utf-8", "replace")
    return result.returncode, text
