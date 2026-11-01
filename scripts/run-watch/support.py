"""Helpers shared by the test modules: replay a synthetic run, read what was raised."""

from __future__ import annotations

import os
import tempfile

import run_watch
import synth


def replay(run, speak=False, mark_ended=True):
    """Replay a synthetic Run through the watcher in memory, as `--replay` does. With
    `mark_ended` False a source is over only if its own sampler wrote a stop line."""
    with tempfile.TemporaryDirectory() as directory:
        paths = run.write(directory)
        events = run_watch.load_events(paths, paths["polls"] if run.polls else None)
    out = run_watch.MemoryOutput()
    watcher = run_watch.Watcher(out, speak=speak)
    run_watch.run_events(watcher, events, mark_ended=mark_ended)
    watcher.memory = out
    return watcher


def titles(watcher):
    return [r.title for r in watcher.raised]


def first(watcher, title):
    """Seconds from the run's start at which `title` was first raised, or None."""
    for r in watcher.raised:
        if r.title == title:
            return r.t - synth.T0
    return None


def notes(watcher, level="NOTE"):
    return [text for _, lvl, text in watcher.memory.lines if lvl == level]


def lines(watcher, level):
    return [text for _, lvl, text in watcher.memory.lines if lvl == level]


def idle(seconds=40.0, **kwargs):
    return synth.Run.idle(seconds, **kwargs)


def captures_dir():
    """P1's captures, if they are on this machine. The tests that use them skip otherwise."""
    path = os.path.expanduser("~/aeolus-captures/P1")
    return path if os.path.isdir(path) else None
