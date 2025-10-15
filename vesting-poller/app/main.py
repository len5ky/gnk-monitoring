import json
import os
import subprocess
import sys
import time
from typing import Any, Dict, List

import yaml


def parse_duration_seconds(text: str) -> float:
    if text.endswith("ms"):
        return float(text[:-2]) / 1000.0
    if text.endswith("s"):
        return float(text[:-1])
    if text.endswith("m"):
        return float(text[:-1]) * 60.0
    if text.endswith("h"):
        return float(text[:-1]) * 3600.0
    return float(text)


def load_addresses(config_path: str) -> List[str]:
    with open(config_path, "r", encoding="utf-8") as f:
        content = yaml.safe_load(f) or {}
    addrs = content.get("addresses", [])
    return [str(a).strip() for a in addrs if str(a).strip()]


def run_query(binary_path: str, address: str, node_url: str, timeout_s: float) -> str:
    cmd = [
        binary_path,
        "query",
        "streamvesting",
        "total-vesting",
        address,
        "--node",
        node_url,
    ]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, timeout=timeout_s)
        return out.decode("utf-8", errors="replace")
    except subprocess.CalledProcessError as e:
        return e.output.decode("utf-8", errors="replace")
    except Exception as e:  # timeout or other
        return f"__ERROR__ {type(e).__name__}: {e}"


def parse_total_amount(text: str) -> float:
    # Expected either YAML-like block with amount or 'total_amount: null'
    # We'll scan for 'amount: "<digits>"' first.
    amount_nano = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("amount:"):
            # amount: "90351467433283"
            parts = line.split("\"")
            if len(parts) >= 2 and parts[1].isdigit():
                amount_nano = int(parts[1])
                break
    if amount_nano is None:
        if "total_amount: null" in text:
            amount_nano = 0
    if amount_nano is None:
        return float("nan")
    # convert nano (1e-9)
    return amount_nano / 1_000_000_000.0


def main() -> None:
    config_path = os.getenv("VESTING_ADDRESSES_CONFIG", "/etc/vesting/addresses.yml")
    binary_path = os.getenv("INFERENCED_BIN", "/usr/local/bin/inferenced")
    node_url = os.getenv("CHAIN_RPC_NODE", "http://node1.gonka.ai:8000/chain-rpc/")
    poll_interval = parse_duration_seconds(os.getenv("VESTING_POLL_INTERVAL", "60s"))
    timeout_s = parse_duration_seconds(os.getenv("VESTING_REQUEST_TIMEOUT", "15s"))

    if not os.path.exists(binary_path):
        print(json.dumps({"level": "error", "msg": "missing_binary", "binary": binary_path}), flush=True)
        sys.exit(1)

    addresses = load_addresses(config_path)
    if not addresses:
        print(json.dumps({"level": "warn", "msg": "no_addresses_configured", "config_path": config_path}), flush=True)

    while True:
        total_sum = 0.0
        results: List[Dict[str, Any]] = []
        for addr in addresses:
            raw = run_query(binary_path, addr, node_url, timeout_s)
            amount = parse_total_amount(raw)
            if amount == amount:  # not NaN
                total_sum += amount
            results.append({
                "address": addr,
                "amount": round(amount, 3) if amount == amount else None,
            })

        # emit one line per address for Grafana/Loki with labels and value
        for r in results:
            payload = {
                "address": r["address"],
                "amount": r["amount"],
                "node": node_url,
            }
            print(json.dumps(payload), flush=True)

        # emit a total line for aggregation
        print(json.dumps({"total_amount": round(total_sum, 3), "node": node_url}), flush=True)

        time.sleep(poll_interval)


if __name__ == "__main__":
    main()




