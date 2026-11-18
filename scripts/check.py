#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MASON_LUALS = Path.home() / ".local/share/nvim/mason/bin/lua-language-server"


def vimruntime() -> str:
    out = subprocess.run(
        ["nvim", "--headless", "-c", "lua io.write(vim.env.VIMRUNTIME)", "-c", "q"],
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stderr or out.stdout


def luals() -> str:
    return shutil.which("lua-language-server") or str(MASON_LUALS)


def run(argv: list[str], env: dict[str, str]) -> int:
    return subprocess.run(argv, cwd=ROOT, env=env).returncode


def main() -> int:
    env = {**os.environ, "VIMRUNTIME": vimruntime()}
    results = [
        run(["stylua", "--check", "."], env),
        run([luals(), "--check", ".", "--checklevel=Hint"], env),
    ]
    return max(results)


if __name__ == "__main__":
    sys.exit(main())
