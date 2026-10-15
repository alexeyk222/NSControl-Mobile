#!/usr/bin/env python3
"""Score independently annotated NSControl episodes on a common time scale.

Usage: python3 tools/score.py input.json [--output result.json]
See docs/storage.md for the JSON contract and limitations of timing evidence.
"""
from __future__ import annotations

import argparse
from collections import deque
import json
import math
from pathlib import Path
import sys


def _number(value, label, *, minimum=None):
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value):
        raise ValueError(f'{label} must be a finite number')
    if minimum is not None and value < minimum:
        raise ValueError(f'{label} must be >= {minimum}')
    return value


def _text(value, label):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f'{label} must be a nonempty string')
    return value


def _records(data, name):
    records = data.get(name, [])
    if not isinstance(records, list):
        raise ValueError(f'{name} must be an array')
    seen = set()
    for row in records:
        if not isinstance(row, dict):
            raise ValueError(f'{name} entries must be objects')
        key = (_text(row.get('device'), 'device'), _text(row.get('id'), 'id'))
        if key in seen:
            raise ValueError(f'duplicate {name} device/id: {key}')
        seen.add(key)
        _text(row.get('type'), 'type')
        _number(row.get('threshold_ms'), 'threshold_ms')
        if row.get('alert_request_latency_ms') is not None:
            _number(row['alert_request_latency_ms'], 'alert_request_latency_ms')
    return records


def _maximum_matching(episodes, detections, tolerance_ms):
    """Deterministic augmenting paths; maximizes count without greedy losses."""
    edges = {
        e: sorted(
            (d for d in range(len(detections))
             if abs(episodes[e]['threshold_ms'] - detections[d]['threshold_ms']) <= tolerance_ms),
            key=lambda d: (abs(episodes[e]['threshold_ms'] - detections[d]['threshold_ms']),
                           detections[d]['threshold_ms'], detections[d]['id']),
        ) for e in range(len(episodes))
    }
    ep_to_det, det_to_ep = {}, {}
    for root in range(len(episodes)):
        queue = deque([root])
        visited_episodes = {root}
        predecessor = {}
        free = None
        while queue and free is None:
            episode = queue.popleft()
            for detection in edges[episode]:
                if detection in predecessor:
                    continue
                predecessor[detection] = episode
                if detection not in det_to_ep:
                    free = detection
                    break
                next_episode = det_to_ep[detection]
                if next_episode not in visited_episodes:
                    visited_episodes.add(next_episode)
                    queue.append(next_episode)
        while free is not None:
            episode = predecessor[free]
            old_detection = ep_to_det.get(episode)
            ep_to_det[episode] = free
            det_to_ep[free] = episode
            free = old_detection
    return ep_to_det, edges


def _metrics(tp, fp, fn, duplicate_fp):
    return {
        'tp': tp, 'fp': fp, 'fn': fn, 'duplicate_fp': duplicate_fp,
        'recall_percent': 100.0 * tp / (tp + fn) if tp + fn else None,
        'precision_percent': 100.0 * tp / (tp + fp) if tp + fp else None,
    }


def _measurement(measurement, modality, threshold_ms):
    if measurement is None or measurement.get(f'{modality}_at_ms') is None:
        return None
    latency = measurement[f'{modality}_at_ms'] - threshold_ms
    uncertainty = measurement['uncertainty_ms']
    limit = 500 if modality == 'sound' else 2000
    early = latency < -uncertainty
    return {
        'latency_ms': latency, 'uncertainty_ms': uncertainty,
        'early': early, 'limit_ms': limit,
        'within_limit': not early and uncertainty <= 100 and latency + uncertainty <= limit,
    }


def _latency_summary(matches, modality):
    measured = [m[modality] for m in matches if m[modality] is not None]
    passed = sum(m['within_limit'] for m in measured)
    failed = len(measured) - passed
    nonnegative = [m['latency_ms'] for m in measured if m['latency_ms'] >= 0]
    return {
        'measured': len(measured), 'missing': len(matches) - len(measured),
        'passed': passed, 'failed': failed, 'early': sum(m['early'] for m in measured),
        'mean_nonnegative_ms': sum(nonnegative) / len(nonnegative) if nonnegative else None,
        'max_nonnegative_ms': max(nonnegative) if nonnegative else None,
        'all_within_limit': False if failed else (True if matches and len(measured) == len(matches) else None),
    }


def score(data, *, tolerance_ms=1000):
    if not isinstance(data, dict):
        raise ValueError('root must be an object')
    _number(tolerance_ms, 'tolerance_ms', minimum=0)
    episodes = _records(data, 'episodes')
    detections = _records(data, 'detections')
    measurement_rows = data.get('external_measurements', [])
    if not isinstance(measurement_rows, list):
        raise ValueError('external_measurements must be an array')
    measurements = {}
    detection_keys = {(d['device'], d['id']) for d in detections}
    for row in measurement_rows:
        if not isinstance(row, dict):
            raise ValueError('external_measurements entries must be objects')
        key = (_text(row.get('device'), 'device'), _text(row.get('detection_id'), 'detection_id'))
        if key in measurements or key not in detection_keys:
            raise ValueError(f'duplicate or unknown measurement detection: {key}')
        _number(row.get('uncertainty_ms'), 'uncertainty_ms', minimum=0)
        for field in ('sound_at_ms', 'vibration_at_ms'):
            if row.get(field) is not None:
                _number(row[field], field)
        measurements[key] = row
    result = {'schema_version': 1, 'tolerance_ms': tolerance_ms, 'devices': {}}
    total = [0, 0, 0, 0]
    for device in sorted({row['device'] for row in episodes + detections}):
        types = {}
        all_matches = []
        for kind in sorted({row['type'] for row in episodes + detections if row['device'] == device}):
            sort_key = lambda r: (r['threshold_ms'], r['id'])
            es = sorted((r for r in episodes if r['device'] == device and r['type'] == kind), key=sort_key)
            ds = sorted((r for r in detections if r['device'] == device and r['type'] == kind), key=sort_key)
            matching, edges = _maximum_matching(es, ds, tolerance_ms)
            used = set(matching.values())
            unmatched = set(range(len(ds))) - used
            eligible = {d for adjacency in edges.values() for d in adjacency}
            duplicate = unmatched & eligible
            counts = [len(matching), len(unmatched), len(es) - len(matching), len(duplicate)]
            total = [left + right for left, right in zip(total, counts)]
            metrics = _metrics(*counts)
            matches = []
            for e, d in sorted(matching.items()):
                episode, detection = es[e], ds[d]
                measurement = measurements.get((device, detection['id']))
                matches.append({
                    'episode_id': episode['id'], 'detection_id': detection['id'],
                    'threshold_delta_ms': detection['threshold_ms'] - episode['threshold_ms'],
                    'alert_request_latency_ms': detection.get('alert_request_latency_ms'),
                    'sound': _measurement(measurement, 'sound', episode['threshold_ms']),
                    'vibration': _measurement(measurement, 'vibration', episode['threshold_ms']),
                })
            metrics.update({
                'matches': matches,
                'missed_episode_ids': [e['id'] for index, e in enumerate(es) if index not in matching],
                'unmatched_detection_ids': [ds[d]['id'] for d in sorted(unmatched)],
                'duplicate_detection_ids': [ds[d]['id'] for d in sorted(duplicate)],
            })
            types[kind] = metrics
            all_matches.extend(matches)
        result['devices'][device] = {
            'types': types,
            'external_latency': {modality: _latency_summary(all_matches, modality)
                                 for modality in ('sound', 'vibration')},
        }
    result['totals'] = _metrics(*total)
    result['totals_are_descriptive_only'] = True
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--tolerance-ms', type=float, default=1000)
    args = parser.parse_args(argv)
    try:
        result = score(json.loads(args.input.read_text(encoding='utf-8')), tolerance_ms=args.tolerance_ms)
        output = json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + '\n'
        if args.output:
            args.output.write_text(output, encoding='utf-8')
        else:
            sys.stdout.write(output)
    except (OSError, ValueError, TypeError) as error:
        parser.exit(2, f'invalid input: {error}\n')


if __name__ == '__main__':
    main()
