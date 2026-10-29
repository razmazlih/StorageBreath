#!/usr/bin/env python3
"""Compile the application model once, then run isolated fixture-based suites."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
SOURCES = ['App.swift', 'StorageEngine.swift', 'VisualEffects.swift', 'CloudEngine.swift',
           'CloudView.swift', 'ProtectionStore.swift', 'FileControls.swift', 'DeepScanEngine.swift',
           'Dashboard.swift', 'AIExchange.swift', 'AIFlow.swift', 'InventoryDatabase.swift', 'PermissionsSetup.swift']
SUITES = ['ProtectionTests', 'AIExchangeTests', 'CloudEngineTests', 'CloudSuggestionTests', 'DeepScanTests',
          'InventoryDatabaseTests', 'DashboardTests', 'DashboardDiskTests',
          'PermissionsSetupTests', 'EngineTests', 'TemporaryTests',
          'CloudPerformanceTests', 'AIFlowResponsivenessTests']

def main():
    with tempfile.TemporaryDirectory(prefix='storage-tests-') as temp:
        folder = Path(temp)
        subprocess.run(['swiftc', '-swift-version', '5', '-D', 'TESTING', '-parse-as-library',
                        '-O', '-enable-testing', '-emit-library', '-emit-module', '-module-name', 'StorageCore',
                        '-module-cache-path', str(ROOT / 'build/module-cache'),
                        *SOURCES, '-o', str(folder / 'libStorageCore.dylib'),
                        '-emit-module-path', str(folder / 'StorageCore.swiftmodule'),
                        '-framework', 'SwiftUI', '-framework', 'AppKit'], cwd=ROOT, check=True)
        def run(suite):
            source = folder / (suite + '.swift')
            source.write_text('@testable import StorageCore\n' + (ROOT / (suite + '.swift')).read_text())
            exe = folder / suite
            build = subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O',
                                    '-I', temp, '-L', temp, '-lStorageCore',
                                    '-Xlinker', '-rpath', '-Xlinker', temp,
                                    str(source), '-o', str(exe)], capture_output=True, text=True)
            if build.returncode:
                return False, suite + ' COMPILE FAILED\n' + build.stderr
            try:
                result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=180)
                return result.returncode == 0, suite + '\n' + result.stdout + result.stderr
            except subprocess.TimeoutExpired:
                return False, suite + ' TIMED OUT'
        # Tests mutate shared protection defaults; run serially to avoid interference.
        results = [run(suite) for suite in SUITES]
        for passed, output in results:
            print(('PASS ' if passed else 'FAIL ') + output, flush=True)
        raise SystemExit(0 if all(passed for passed, _ in results) else 1)

if __name__ == '__main__':
    main()
