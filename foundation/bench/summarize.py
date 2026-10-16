"""Print a one-line-per-run summary of benchmark result folders.

  python3 summarize.py results/*        # all runs
  python3 summarize.py results/<run>    # one run
"""

import json
import sys
from pathlib import Path


def load(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def main(dirs):
    print(f"{'run':44} {'conc':>4} {'out tok/s':>9} {'TTFT ms':>8} {'TPOT ms':>8}"
          f" {'cold TTFT s':>11} {'warm TTFT s':>11} {'warm hit':>8}")
    for d in sorted(Path(p) for p in dirs):
        if not d.is_dir():
            continue
        pc = load(d / "prefix-cache.json")
        extra = (f" {pc.get('ttft_cold_s', '-')!s:>11} {pc.get('ttft_warm_s', '-')!s:>11}"
                 f" {pc.get('warm_request_hit_rate', '-')!s:>8}")
        runs = sorted(d.glob("serve-c*.json"), key=lambda p: int(p.stem.split("-c")[1]))
        if not runs:
            print(f"{d.name:44} {'-':>4} {'-':>9} {'-':>8} {'-':>8}{extra}")
        for i, f in enumerate(runs):
            r = load(f)
            print(f"{d.name if i == 0 else '':44} {r.get('max_concurrency', '?')!s:>4}"
                  f" {r.get('output_throughput', 0):9.1f} {r.get('median_ttft_ms', 0):8.0f}"
                  f" {r.get('median_tpot_ms', 0):8.1f}{extra if i == 0 else ''}")


if __name__ == "__main__":
    main(sys.argv[1:])
