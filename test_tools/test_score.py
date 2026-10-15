"""Behavioral acceptance scoring tests using the public JSON CLI."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ScoreTest(unittest.TestCase):
    def score(self, data):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'input.json'
            source.write_text(json.dumps(data), encoding='utf-8')
            completed = subprocess.run(
                [sys.executable, str(ROOT / 'tools/score.py'), str(source)],
                text=True, capture_output=True, check=False,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout)

    def test_duplicate_is_fp_and_unavailable_episode_stays_fn(self):
        result = self.score({
            'episodes': [
                {'id': 'a', 'device': 'iphone11', 'type': 'eyes', 'threshold_ms': 2000},
                {'id': 'b', 'device': 'iphone11', 'type': 'eyes', 'threshold_ms': 9000, 'available': False},
            ],
            'detections': [
                {'id': 'd1', 'device': 'iphone11', 'type': 'eyes', 'threshold_ms': 2000},
                {'id': 'd2', 'device': 'iphone11', 'type': 'eyes', 'threshold_ms': 2100},
                {'id': 'd3', 'device': 'iphone11', 'type': 'head', 'threshold_ms': 2000},
            ],
        })
        eyes = result['devices']['iphone11']['types']['eyes']
        self.assertEqual((eyes['tp'], eyes['fp'], eyes['fn'], eyes['duplicate_fp']), (1, 1, 1, 1))
        self.assertEqual((eyes['recall_percent'], eyes['precision_percent']), (50.0, 50.0))
        self.assertEqual(result['devices']['iphone11']['types']['head']['fp'], 1)

    def test_maximum_matching_handles_competing_neighbors(self):
        result = self.score({
            'episodes': [
                {'id': 'a', 'device': 'pura70', 'type': 'eyes', 'threshold_ms': 2000},
                {'id': 'b', 'device': 'pura70', 'type': 'eyes', 'threshold_ms': 3500},
            ],
            'detections': [
                {'id': 'x', 'device': 'pura70', 'type': 'eyes', 'threshold_ms': 2800},
                {'id': 'y', 'device': 'pura70', 'type': 'eyes', 'threshold_ms': 1000},
            ],
        })
        eyes = result['devices']['pura70']['types']['eyes']
        self.assertEqual((eyes['tp'], eyes['fn'], eyes['fp']), (2, 0, 0))
        self.assertEqual({(m['episode_id'], m['detection_id']) for m in eyes['matches']}, {('a', 'y'), ('b', 'x')})

    def test_boundary_is_inclusive_and_devices_never_cross_match(self):
        result = self.score({
            'episodes': [{'id': 'a', 'device': 'one', 'type': 'eyes', 'threshold_ms': 2000}],
            'detections': [
                {'id': 'x', 'device': 'two', 'type': 'eyes', 'threshold_ms': 2000},
                {'id': 'y', 'device': 'one', 'type': 'eyes', 'threshold_ms': 3000.001},
            ],
        })
        self.assertEqual(result['devices']['one']['types']['eyes']['fn'], 1)
        self.assertIsNone(result['devices']['two']['types']['eyes']['recall_percent'])
        self.assertEqual(result['devices']['two']['types']['eyes']['precision_percent'], 0)
        empty = self.score({'episodes': [], 'detections': []})
        self.assertIsNone(empty['totals']['recall_percent'])
        self.assertIsNone(empty['totals']['precision_percent'])

    def test_external_latency_is_separate_from_internal_request_and_early_is_rejected(self):
        result = self.score({
            'episodes': [
                {'id': 'a', 'device': 'one', 'type': 'eyes', 'threshold_ms': 2000},
                {'id': 'b', 'device': 'one', 'type': 'eyes', 'threshold_ms': 5000},
                {'id': 'c', 'device': 'one', 'type': 'head', 'threshold_ms': 8000},
            ],
            'detections': [
                {'id': 'x', 'device': 'one', 'type': 'eyes', 'threshold_ms': 2000, 'alert_request_latency_ms': 1},
                {'id': 'y', 'device': 'one', 'type': 'eyes', 'threshold_ms': 5000},
                {'id': 'z', 'device': 'one', 'type': 'head', 'threshold_ms': 8000, 'alert_request_latency_ms': 1},
            ],
            'external_measurements': [
                {'detection_id': 'x', 'device': 'one', 'sound_at_ms': 2420, 'vibration_at_ms': 3900, 'uncertainty_ms': 80},
                {'detection_id': 'y', 'device': 'one', 'sound_at_ms': 4800, 'uncertainty_ms': 100},
            ],
        })
        latency = result['devices']['one']['external_latency']
        sound = latency['sound']
        self.assertEqual((sound['measured'], sound['missing'], sound['early'], sound['passed'], sound['failed']), (2, 1, 1, 1, 1))
        self.assertEqual(sound['mean_nonnegative_ms'], 420)
        self.assertIs(sound['all_within_limit'], False)
        self.assertEqual(latency['vibration']['passed'], 1)
        head = result['devices']['one']['types']['head']['matches'][0]
        self.assertEqual(head['alert_request_latency_ms'], 1)
        self.assertIsNone(head['sound'])

    def test_invalid_ids_or_nonfinite_times_fail_without_emitting_metrics(self):
        for data in [
            {'episodes': [{'id': 'a', 'device': 'one', 'type': 'eyes', 'threshold_ms': float('nan')}], 'detections': []},
            {'episodes': [], 'detections': [{'id': 'x', 'device': 'one', 'type': 'eyes', 'threshold_ms': 1}] * 2},
        ]:
            with tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / 'input.json'
                source.write_text(json.dumps(data), encoding='utf-8')
                completed = subprocess.run([sys.executable, str(ROOT / 'tools/score.py'), str(source)], capture_output=True, text=True)
            self.assertEqual(completed.returncode, 2)
            self.assertEqual(completed.stdout, '')
            self.assertIn('invalid input', completed.stderr)


if __name__ == '__main__':
    unittest.main()
