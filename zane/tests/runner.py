#!/usr/bin/env python3
"""Exercise the executable protocol and regressions against the suite fixtures."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'out/host/zane'
FIXTURE = json.loads((ROOT.parent / 'test.js').read_text())

class RunnerTests(unittest.TestCase):
    def run_config(self, config, pattern=None, expected=0):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.json'
            path.write_text(config if isinstance(config, str) else json.dumps(config))
            args = [str(BINARY), str(path)]
            if pattern is not None:
                args.append(pattern)
            result = subprocess.run(args, text=True, capture_output=True, timeout=60)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            return result

    def test_all_reference_checksums(self):
        result = self.run_config(FIXTURE)
        self.assertEqual(result.stdout.count(': OK '), len(FIXTURE))
        self.assertRegex(result.stdout, r'Summary: [0-9.]+s, 50, 50, 0')

    def test_production_json_parse_checksums(self):
        config = json.loads((ROOT.parent / "run.js").read_text())
        config = [row for row in config if row["name"].startswith("Json::")]
        result = self.run_config(config)
        self.assertEqual(result.stdout.count(": OK "), 3)

    def test_case_insensitive_filter(self):
        result = self.run_config(FIXTURE, 'bInArYtReEs')
        self.assertEqual(result.stdout.count(': OK '), 2)

    def test_checksum_failure(self):
        config = [copy.deepcopy(FIXTURE[0])]
        config[0]['checksum'] += 1
        self.assertIn('ERR[actual=', self.run_config(config, expected=1).stdout)

    def test_no_matching_benchmark(self):
        self.run_config(FIXTURE, 'does-not-exist', expected=2)

    def test_unknown_benchmark(self):
        self.run_config([{'name': 'Unknown::Benchmark'}], expected=2)

    def test_unknown_name_with_known_family(self):
        config = [copy.deepcopy(FIXTURE[0])]
        config[0]["name"] = "Binarytrees::Unknown"
        self.run_config(config, expected=2)

    def test_invalid_json(self):
        self.run_config('{invalid', expected=2)

    def test_missing_field(self):
        self.run_config([{'name': 'Binarytrees::Obj'}], expected=2)

    def test_zero_warmup_is_respected(self):
        config = [copy.deepcopy(FIXTURE[0])]
        config[0].update(warmup_iterations=0, checksum=93)
        self.run_config(config)

if __name__ == '__main__':
    unittest.main()
