#!/usr/bin/env python3
"""Exercise native IPC without launching or modifying installed Shelf/Ted apps."""

import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="shelf-ted-smoke-") as temporary:
        directory = Path(temporary)
        executable = directory / "probe"
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(directory / "cache"))
        subprocess.run([
            "swiftc", "-swift-version", "6", "-parse-as-library",
            str(root / "Sources/CortexInfra/ShelfTedHandshake.swift"),
            str(root / "Sources/CortexInfra/ShelfTedBridge.swift"),
            str(root / "Tests/BridgeSmoke/Probe.swift"),
            "-o", str(executable),
        ], env=env, check=True)
        for order in [("shelf", "ted"), ("ted", "shelf")]:
            run = directory / ("presence-" + "-".join(order))
            run.mkdir()
            children = []
            try:
                for role in order:
                    children.append(subprocess.Popen(
                        [str(executable), role, str(run)],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                    ))
                    time.sleep(0.2)
                failures = []
                for role, child in zip(order, children):
                    output, _ = child.communicate(timeout=15)
                    print(output, end="")
                    if child.returncode:
                        failures.append(f"{role} exited {child.returncode}")
                if failures:
                    raise RuntimeError("; ".join(failures))
                print(f"PASS: {' then '.join(order)} + stop/restart")
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.wait()


if __name__ == "__main__":
    main()
