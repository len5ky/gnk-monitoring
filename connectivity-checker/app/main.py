import argparse
import asyncio
import json
import os
import re
import socket
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional

import httpx
import yaml


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_duration(text: str, default: float) -> float:
    if not text:
        return default
    value = text.strip().lower()
    try:
        if value.endswith("ms"):
            return float(value[:-2]) / 1000.0
        if value.endswith("s"):
            return float(value[:-1])
        if value.endswith("m"):
            return float(value[:-1]) * 60.0
        if value.endswith("h"):
            return float(value[:-1]) * 3600.0
        return float(value)
    except ValueError:
        return default


def hostname() -> str:
    return socket.gethostname()


def expand_env(value: str, extra_env: Optional[Dict[str, str]] = None) -> str:
    if extra_env:
        lookup = os.environ.copy()
        lookup.update(extra_env)
    else:
        lookup = os.environ
    return os.path.expandvars(value) if "$" in value else value


def load_yaml(path: Path, extra_env: Optional[Dict[str, str]] = None) -> Dict:
    text = path.read_text(encoding="utf-8")
    # First apply extra_env substitutions (for ADDRESS)
    if extra_env:
        for key, value in extra_env.items():
            text = text.replace(f"${{{key}}}", value)
    # Then expand environment variables (for NETWORKNODE_IP, etc.)
    # Use custom replacement to handle ${VAR} syntax properly
    def expand_var(match):
        var_name = match.group(1)
        return os.environ.get(var_name, match.group(0))
    text = re.sub(r'\$\{([^}]+)\}', expand_var, text)
    return yaml.safe_load(text) or {}


@dataclass
class PingCheck:
    name: str
    host: str


@dataclass
class HttpCheck:
    name: str
    method: str
    url: str
    expect_text: Optional[str]
    expect_status: Optional[int]
    accept_error_substring: Optional[str]


@dataclass
class NodeChecks:
    node_name: str
    ping: List[PingCheck]
    http: List[HttpCheck]


async def run_ping(check: PingCheck, ping_command: str, count: int) -> Dict:
    start = time.monotonic()
    proc = await asyncio.create_subprocess_exec(
        ping_command,
        "-c",
        str(count),
        "-n",
        check.host,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    duration = time.monotonic() - start

    record = {
        "ts": utcnow(),
        "kind": "ping",
        "name": check.name,
        "host": check.host,
        "status": "ok" if proc.returncode == 0 else "error",
        "latency_s": duration,
        "return_code": proc.returncode,
        "stdout": stdout.decode().strip(),
        "stderr": stderr.decode().strip(),
    }
    if proc.returncode != 0:
        record["error"] = "ping_failed"
    return record


async def run_http(check: HttpCheck, timeout: float) -> Dict:
    start = time.monotonic()
    error: Optional[str] = None
    body: Optional[str] = None
    status_code: Optional[int] = None
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            response = await client.request(check.method, check.url)
        body = response.text
        status_code = response.status_code
        duration = time.monotonic() - start

        ok = True
        if check.expect_status is not None and status_code != check.expect_status:
            ok = False
            error = f"unexpected_status:{status_code}"
        if ok and check.expect_text is not None and check.expect_text not in body:
            ok = False
            error = "unexpected_body"

        record = {
            "ts": utcnow(),
            "kind": "http",
            "name": check.name,
            "url": check.url,
            "status": "ok" if ok else "error",
            "latency_s": duration,
            "http_status": status_code,
            "body_sample": body[:512] if body else "",
        }
        if not ok:
            record["error"] = error or "check_failed"
        return record
    except Exception as exc:  # pragma: no cover - network errors
        duration = time.monotonic() - start
        detail = str(exc)
        # Check if this error should be accepted as "ok"
        if check.accept_error_substring and check.accept_error_substring in detail:
            return {
                "ts": utcnow(),
                "kind": "http",
                "name": check.name,
                "url": check.url,
                "status": "ok",
                "latency_s": duration,
                "note": "accepted_error",
                "accepted_error": detail,
            }
        return {
            "ts": utcnow(),
            "kind": "http",
            "name": check.name,
            "url": check.url,
            "status": "error",
            "latency_s": duration,
            "error": f"exception:{type(exc).__name__}",
            "detail": detail,
            "http_status": status_code,
            "body_sample": body[:512] if body else "",
        }


def log_record(record: Dict, instance_id: str, instance_role: str, node_name: str) -> None:
    enriched = dict(record)
    enriched["instance_id"] = instance_id
    enriched["instance_role"] = instance_role
    enriched["node"] = node_name
    enriched["host"] = hostname()
    print(json.dumps(enriched, ensure_ascii=False), flush=True)


async def run_checks_for_node(
    node_checks: NodeChecks,
    poll_interval: float,
    timeout: float,
    ping_command: str,
    ping_count: int,
    instance_id: str,
    instance_role: str,
) -> None:
    while True:
        tasks: List[asyncio.Task] = []
        for ping_check in node_checks.ping:
            tasks.append(asyncio.create_task(run_ping(ping_check, ping_command, ping_count)))
        for http_check in node_checks.http:
            tasks.append(asyncio.create_task(run_http(http_check, timeout)))

        for task in asyncio.as_completed(tasks):
            try:
                result = await task
                log_record(result, instance_id, instance_role, node_checks.node_name)
            except Exception as exc:  # pragma: no cover - defensive
                log_record(
                    {
                        "ts": utcnow(),
                        "kind": "error",
                        "status": "error",
                        "error": f"task_exception:{type(exc).__name__}",
                        "detail": str(exc),
                    },
                    instance_id,
                    instance_role,
                    node_checks.node_name,
                )

        await asyncio.sleep(poll_interval)


def materialise_checks(
    inventory_path: Path,
    profiles_dir: Path,
    template_override: Optional[Path],
    config_dir: Path,
) -> Iterable[NodeChecks]:
    inventory = load_yaml(inventory_path)
    nodes = inventory.get("nodes", [])
    profiles_cache: Dict[str, Dict] = {}

    for node in nodes:
        node_name = str(node.get("name") or node.get("id") or "node").strip()
        address = str(node.get("address") or node.get("host") or "").strip()
        profile_name = node.get("profile", "default")

        if not node_name or not address:
            continue

        if template_override and template_override.exists():
            profile_data = load_yaml(template_override, {"ADDRESS": address})
        else:
            if profile_name not in profiles_cache:
                profile_path = profiles_dir / f"{profile_name}.yml"
                profiles_cache[profile_name] = load_yaml(profile_path)
            raw_profile = profiles_cache[profile_name]
            profile_json = json.dumps(raw_profile)
            profile_json = profile_json.replace("${ADDRESS}", address)
            profile_data = json.loads(profile_json)

        ping_checks: List[PingCheck] = []
        for entry in profile_data.get("ping", []):
            name = str(entry.get("name") or entry.get("host") or "ping").strip()
            host = str(entry.get("host") or address)
            ping_checks.append(PingCheck(name=name, host=host))

        http_checks: List[HttpCheck] = []
        for entry in profile_data.get("http", []):
            name = str(entry.get("name") or entry.get("url") or "http").strip()
            url = str(entry.get("url") or "")
            if not url:
                continue
            url = url.replace("${ADDRESS}", address)
            http_checks.append(
                HttpCheck(
                    name=name,
                    method=str(entry.get("method") or "GET").upper(),
                    url=url,
                    expect_text=entry.get("expect_text"),
                    expect_status=entry.get("expect_status"),
                    accept_error_substring=entry.get("accept_error_substring"),
                )
            )

        yield NodeChecks(node_name=node_name, ping=ping_checks, http=http_checks)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Connectivity checker")
    parser.add_argument("--config-dir", default=os.getenv("CONNECTIVITY_CONFIG_DIR", "/etc/connectivity"))
    parser.add_argument("--inventory", default=os.getenv("CONNECTIVITY_INVENTORY", "nodes.yml"))
    parser.add_argument("--profiles", default=os.getenv("CONNECTIVITY_PROFILES_DIR", "profiles"))
    parser.add_argument("--template", default=os.getenv("CONNECTIVITY_TEMPLATE"))
    parser.add_argument("--poll-interval", default=os.getenv("POLL_INTERVAL", "10s"))
    parser.add_argument("--timeout", default=os.getenv("REQUEST_TIMEOUT", "5s"))
    parser.add_argument("--ping-command", default=os.getenv("PING_COMMAND", "ping"))
    parser.add_argument("--ping-count", type=int, default=int(os.getenv("PING_COUNT", "1")))
    parser.add_argument("--instance-id", default=os.getenv("INSTANCE_ID", "unknown-instance"))
    parser.add_argument("--instance-role", default=os.getenv("INSTANCE_ROLE", "host"))
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    config_dir = Path(args.config_dir)
    inventory_path = (config_dir / args.inventory).resolve()
    profiles_dir = (config_dir / args.profiles).resolve()
    template_override = (Path(args.template).resolve() if args.template else None)

    poll_interval = parse_duration(args.poll_interval, 10.0)
    timeout = parse_duration(args.timeout, 5.0)

    if not inventory_path.exists():
        log_record(
            {
                "ts": utcnow(),
                "kind": "config",
                "status": "error",
                "error": "inventory_missing",
                "config_path": str(inventory_path),
            },
            args.instance_id,
            args.instance_role,
            "inventory",
        )
        time.sleep(poll_interval)
        return

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    tasks = []
    for node_checks in materialise_checks(inventory_path, profiles_dir, template_override, config_dir):
        tasks.append(
            loop.create_task(
                run_checks_for_node(
                    node_checks,
                    poll_interval=poll_interval,
                    timeout=timeout,
                    ping_command=args.ping_command,
                    ping_count=args.ping_count,
                    instance_id=args.instance_id,
                    instance_role=args.instance_role,
                )
            )
        )

    try:
        loop.run_until_complete(asyncio.gather(*tasks))
    except KeyboardInterrupt:  # pragma: no cover - interactive use
        for task in tasks:
            task.cancel()
        loop.run_until_complete(asyncio.gather(*tasks, return_exceptions=True))
    finally:
        loop.close()


if __name__ == "__main__":  # pragma: no cover - script entry
    main()
 
