#!/usr/bin/env python3
"""Render the Gas Station installer background at 1x and 2x, without Finder scripting."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
APP_X, APPS_X, ICON_Y = 170, 490, 190


def main():
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    renderer = output / 'background-renderer'
    subprocess.run(['swiftc', '-O', str(ROOT / 'scripts/dmg/background.swift'), '-o', str(renderer)],
                   check=True, capture_output=True, timeout=90)
    subprocess.run([str(renderer), str(output)], check=True, timeout=30)
    subprocess.run(['tiffutil', '-cathidpicheck', str(output / 'background.png'),
                    str(output / 'background@2x.png'), '-out', str(output / 'background.tiff')],
                   check=True, capture_output=True, timeout=30)
    renderer.unlink()


if __name__ == '__main__':
    main()
