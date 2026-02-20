#!/usr/bin/env python3
from __future__ import annotations

import copy
import sys
from pathlib import Path
import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined

REPO_ROOT = Path(__file__).resolve().parents[1]
TEMPLATES_DIR = REPO_ROOT / "templates"
GENERATED_DIR = REPO_ROOT / "generated"
CONFIG_DIR = GENERATED_DIR / "config"

def load_yaml(path: Path) -> dict:
    if not path.exists():
        return {}
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}

def deep_merge(a: dict, b: dict) -> dict:
    out = copy.deepcopy(a)
    for k, v in (b or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        elif isinstance(v, list) and isinstance(out.get(k), list):
            by_name = {i.get("name"): i for i in out[k] if isinstance(i, dict) and i.get("name")}
            for item in v:
                if isinstance(item, dict) and item.get("name"):
                    by_name[item["name"]] = deep_merge(by_name.get(item["name"], {}), item)
            out[k] = list(by_name.values())
        else:
            out[k] = v
    return out

def main() -> int:
    inv = deep_merge(load_yaml(REPO_ROOT / "inventory.yml"), load_yaml(REPO_ROOT / "inventory.private.yml"))
    global_cfg = inv.get("global", {})
    instances = inv.get("instances", [])

    required_global = ["project_name", "stack_root", "parent_iface", "public_subnet_ipv4", "public_subnet_ipv6", "tls_enabled", "certbot_email"]
    missing_g = [k for k in required_global if k not in global_cfg]
    if missing_g:
        print(f"[ERRO] global sem chaves: {missing_g}", file=sys.stderr)
        return 2

    if not isinstance(instances, list) or not instances:
        print("[ERRO] instances vazio.", file=sys.stderr)
        return 2

    for i, inst in enumerate(instances, start=1):
        for key in ["name", "fqdn", "ipv4", "ipv6"]:
            if not inst.get(key):
                print(f"[ERRO] instances[{i}] sem '{key}'.", file=sys.stderr)
                return 2

    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    env_map = {
        "COMPOSE_PROJECT_NAME": str(global_cfg["project_name"]),
        "STACK_ROOT": str(global_cfg["stack_root"]),
        "TLS_ENABLED": "true" if global_cfg["tls_enabled"] else "false",
        "CERTBOT_EMAIL": str(global_cfg["certbot_email"]),
    }

    (GENERATED_DIR / ".env").write_text("".join(f"{k}={v}\n" for k, v in env_map.items()), encoding="utf-8")

    jenv = Environment(
        loader=FileSystemLoader(str(TEMPLATES_DIR)),
        undefined=StrictUndefined,
        autoescape=False,
        trim_blocks=True,
        lstrip_blocks=True,
    )

    compose_out = jenv.get_template("docker-compose.yml.j2").render(**{"global": global_cfg, "instances": instances, "env": env_map})
    (GENERATED_DIR / "docker-compose.yml").write_text(compose_out + "\n", encoding="utf-8")

    nginx_tpl = jenv.get_template("nginx.conf.j2")
    ookla_tpl = jenv.get_template("OoklaServer.properties.j2")

    names = []
    for inst in instances:
        names.append(inst["name"])
        inst_dir = CONFIG_DIR / inst["name"]
        inst_dir.mkdir(parents=True, exist_ok=True)
        (inst_dir / "nginx.conf").write_text(nginx_tpl.render(**{"global": global_cfg, "inst": inst}) + "\n", encoding="utf-8")
        inst.setdefault("ookla", {})
        inst["ookla"].setdefault("properties_raw", "")
        (inst_dir / "OoklaServer.properties").write_text(ookla_tpl.render(inst=inst) + "\n", encoding="utf-8")

    (GENERATED_DIR / "instances.txt").write_text("\n".join(names) + "\n", encoding="utf-8")
    print(f"[OK] arquivos gerados em {GENERATED_DIR}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
