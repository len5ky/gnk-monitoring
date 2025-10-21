import argparse
import json
import os
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_file(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except Exception:
        return ""


def parse_meminfo() -> Dict[str, int]:
    result: Dict[str, int] = {}
    for line in read_file(Path("/proc/meminfo")).splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        parts = value.strip().split()
        if not parts:
            continue
        try:
            result[key] = int(parts[0])
        except ValueError:
            continue
    return result


def parse_stat_cpu() -> Dict[str, int]:
    first_line = read_file(Path("/proc/stat")).splitlines()[0]
    parts = first_line.split()
    if parts[0] != "cpu":
        return {}
    values = [int(x) for x in parts[1:]]
    keys = ["user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal", "guest", "guest_nice"]
    return {keys[i]: values[i] for i in range(min(len(keys), len(values)))}


def parse_nvidia_smi() -> Dict:
    import subprocess

    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,memory.total,memory.used,utilization.gpu", "--format=csv,noheader,nounits"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {}

    gpus = []
    for line in result.stdout.splitlines():
        parts = [x.strip() for x in line.split(",")]
        if len(parts) < 4:
            continue
        try:
            gpus.append(
                {
                    "name": parts[0],
                    "memory_total_mb": int(parts[1]),
                    "memory_used_mb": int(parts[2]),
                    "utilization_percent": int(parts[3]),
                }
            )
        except ValueError:
            continue
    return {"gpus": gpus}


def load_process_samples(limit: int = 10) -> Dict:
    entries = []
    proc = Path("/proc")
    for pid_dir in proc.iterdir():
        if not pid_dir.is_dir() or not pid_dir.name.isdigit():
            continue
        try:
            stat = (pid_dir / "stat").read_text().split()
        except Exception:
            continue
        if len(stat) < 24:
            continue
        try:
            pid = int(stat[0])
            comm = stat[1].strip("()")
            utime = int(stat[13])
            stime = int(stat[14])
            rss = int(stat[23])
        except ValueError:
            continue
        entries.append({"pid": pid, "comm": comm, "utime": utime, "stime": stime, "rss_pages": rss})
        if len(entries) >= limit:
            break
    return {"process_samples": entries}


def main() -> None:
    parser = argparse.ArgumentParser(description="Emit system metrics as JSON")
    parser.add_argument("--interval", default=os.getenv("METRICS_INTERVAL", "15"))
    parser.add_argument("--instance-id", default=os.getenv("INSTANCE_ID", "unknown-instance"))
    parser.add_argument("--instance-role", default=os.getenv("INSTANCE_ROLE", "host"))
    parser.add_argument("--gpu", action="store_true", default=os.getenv("METRICS_GPU", "false").lower() == "true")
    parser.add_argument("--process-limit", type=int, default=int(os.getenv("METRICS_PROCESS_LIMIT", "10")))
    args = parser.parse_args()

    try:
        interval = float(args.interval)
    except ValueError:
        interval = 15.0

    while True:
        payload: Dict[str, Dict] = {
            "ts": utcnow(),
            "instance_id": args.instance_id,
            "instance_role": args.instance_role,
            "kind": "system_metrics",
            "cpu": parse_stat_cpu(),
            "memory": parse_meminfo(),
        }
        payload.update(load_process_samples(args.process_limit))

        if args.gpu:
            payload["gpu"] = parse_nvidia_smi()

        print(json.dumps(payload, ensure_ascii=False), flush=True)
        time.sleep(interval)


if __name__ == "__main__":
    main()

