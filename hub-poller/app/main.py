import asyncio
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List

import httpx
import yaml
from tenacity import retry, stop_after_attempt, wait_exponential


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


def load_hubs(config_path: str) -> List[Dict[str, str]]:
    with open(config_path, "r", encoding="utf-8") as f:
        content = yaml.safe_load(f) or {}
    hubs = content.get("hubs", [])
    result: List[Dict[str, str]] = []
    for hub in hubs:
        name = str(hub.get("name", "")).strip()
        ip = str(hub.get("ip", "")).strip()
        if not name or not ip:
            continue
        result.append({"name": name, "ip": ip})
    return result


@retry(wait=wait_exponential(multiplier=0.5, min=1, max=8), stop=stop_after_attempt(3))
async def fetch_nodes(client: httpx.AsyncClient, hub_ip: str, timeout_s: float) -> List[Dict[str, Any]]:
    url = f"http://{hub_ip}:9200/admin/v1/nodes"
    resp = await client.get(url, timeout=timeout_s)
    resp.raise_for_status()
    return resp.json()


def make_log_record(
    hub_name: str,
    hub_ip: str,
    node_entry: Dict[str, Any],
) -> List[Dict[str, Any]]:
    ts = datetime.now(timezone.utc).isoformat()

    node = node_entry.get("node", {})
    state = node_entry.get("state", {})
    models = state.get("epoch_models") or {}
    ml_nodes = state.get("epoch_ml_nodes") or {}

    records: List[Dict[str, Any]] = []

    # Default record regardless of models
    base_record: Dict[str, Any] = {
        "ts": ts,
        "hub": hub_name,
        "hub_ip": hub_ip,
        "node_id": node.get("id"),
        "node_host": node.get("host"),
        "intended_status": state.get("intended_status"),
        "current_status": state.get("current_status"),
        "failure_reason": state.get("failure_reason", ""),
    }

    # For each model, attach poc_weight when available
    if ml_nodes:
        for model_id, ml in ml_nodes.items():
            with_model = dict(base_record)
            with_model.update(
                {
                    "model": model_id,
                    "poc_weight": ml.get("poc_weight"),
                }
            )
            records.append(with_model)
    else:
        records.append(base_record)

    return records


async def poll_hub(
    client: httpx.AsyncClient,
    hub: Dict[str, str],
    timeout_s: float,
) -> None:
    hub_name = hub["name"]
    hub_ip = hub["ip"]
    try:
        nodes = await fetch_nodes(client, hub_ip, timeout_s)
    except Exception as exc:  # log an error line so we can alert in Grafana
        record = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "hub": hub_name,
            "hub_ip": hub_ip,
            "level": "error",
            "error": f"fetch_failed: {type(exc).__name__}: {exc}",
        }
        print(json.dumps(record), flush=True)
        return

    for entry in nodes:
        for rec in make_log_record(hub_name, hub_ip, entry):
            print(json.dumps(rec), flush=True)


async def main_async() -> None:
    config_path = os.getenv("HUBS_CONFIG", "/etc/hubs/hubs.yml")
    poll_interval = parse_duration_seconds(os.getenv("POLL_INTERVAL", "30s"))
    timeout_s = parse_duration_seconds(os.getenv("REQUEST_TIMEOUT", "10s"))
    concurrency = int(os.getenv("CONCURRENT_REQUESTS", "4"))

    hubs = load_hubs(config_path)
    if not hubs:
        print(json.dumps({"level": "warn", "msg": "no_hubs_configured", "config_path": config_path}), flush=True)

    limits = httpx.Limits(max_keepalive_connections=concurrency, max_connections=concurrency)
    async with httpx.AsyncClient(limits=limits) as client:
        while True:
            tasks = [poll_hub(client, hub, timeout_s) for hub in hubs]
            if tasks:
                await asyncio.gather(*tasks)
            await asyncio.sleep(poll_interval)


def main() -> None:
    try:
        asyncio.run(main_async())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()


