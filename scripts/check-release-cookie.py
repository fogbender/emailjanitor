#!/usr/bin/env python3
"""Probe the installed wrapper with deterministic leading-plus random output."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

artifact, program, base64 = sys.argv[1:]
wrapper = (Path(artifact) / "bin" / program).read_text()
assert wrapper.count(base64) == 1
with tempfile.TemporaryDirectory(prefix="janitor-cookie-") as directory:
    root = Path(directory)
    encoder = root / "base64"
    shell = shutil.which("sh")
    assert shell
    encoder.write_text(f"#!{shell}\nprintf '+SyntheticCookie\\n'\n")
    encoder.chmod(0o700)
    probe = root / "probe"
    probe.write_text(wrapper.replace(base64, str(encoder)))
    probe.chmod(0o700)
    result = subprocess.run(
        [str(probe), "eval", ":ok"],
        cwd=root,
        env={"PATH": os.environ["PATH"], "HOME": str(root), "RELEASE_TMP": str(root / "release"),
             "ERL_CRASH_DUMP": "/dev/null"},
        capture_output=True, timeout=30,
    )
    if result.returncode != 0:
        raise SystemExit("Installed release rejected a leading-plus random cookie.")
