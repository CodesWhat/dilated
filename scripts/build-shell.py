#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import signal
import subprocess


def bounded_build(arguments, log, timeout):
    with log.open('w') as output:
        process = subprocess.Popen(arguments, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            result = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=3)
            raise
    if result:
        print(log.read_text()[-12000:])
        raise SystemExit(f'App shell build failed. See {log}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('configuration', choices=['debug', 'release'])
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    output = root / 'build/automation-shell'
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(['xcodegen', 'generate', '--spec', 'packaging/automation-shell/project.yml',
                    '--project', str(output)], check=True, timeout=30)
    log = output / f'{args.configuration}-build.log'
    bounded_build([
        'xcodebuild', '-project', str(output / 'DilatedAutomationShell.xcodeproj'),
        '-scheme', 'DilatedAutomationShell', '-configuration', args.configuration.title(),
        '-destination', 'generic/platform=macOS', '-derivedDataPath', str(output / 'DerivedData'),
        '-clonedSourcePackagesDirPath', str(output / 'Packages'),
        'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64', '-jobs', '4', 'build',
    ], log, timeout=600)
    text = log.read_text()
    if 'RegisterWithLaunchServices' in text or 'lsregister' in text:
        raise SystemExit(f'App shell unexpectedly registered with Launch Services. See {log}')
    print(f'App shell built. Log: {log}')


if __name__ == '__main__':
    main()
