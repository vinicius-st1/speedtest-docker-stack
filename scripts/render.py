#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
import copy
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined


STACK_ROOT = Path("/opt/speedtest-docker-stack")
TEMPLATES_DIR = STACK_ROOT / "templates"
GENERATED_DIR = STACK_ROOT / "generated"
CONFIG_DIR = GENERATED_DIR / "config"


def deep_merge(a: dict, b: dict) -> dict:
    """Recursively merge b into a (b wins)."""
    out = copy.deepcopy(a)
    for k, v in (b or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        elif isinstance(v, list) and isinstance(out.get(k), list):
            # Merge list of dicts by "name" when possible
            if all(isinstance(i, dict) and "name" in i for i in v) and all(isinstance(i, dict) and "name" in i for i in out[k]):
                by_name = {i["name"]: i for i in out[k]}
                for item in v:
                    name = item["name"]
                    by_name[name] = deep_merge(by_name.get(name, {}), item)
                out[k] = list(by_name.values())
            else:
                out[k] = v
        else:
            out[k] = v
    return out


def load_yaml(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def main() -> int:
    inv_public = load_yaml(STACK_ROOT / "inventory.yml")
    inv_private = load_yaml(STACK_ROOT / "inventory.private.yml")
    inv = deep_merge(inv_public, inv_private)

    global_cfg = inv.get("global", {})
    instances = inv.get("instances", [])

    required_globals = ["project_name", "stack_root", "parent_iface", "public_subnet_ipv4", "tls_enabled", "certbot_email"]
    missing = [k for k in required_globals if k not in global_cfg]
    if missing:
        print(f"[render.py] ERRO: chaves ausentes em global: {missing}", file=sys.stderr)
        return 2

    if not isinstance(instances, list) or len(instances) == 0:
        print("[render.py] ERRO: instances está vazio.", file=sys.stderr)
        return 2

    # Prepare env vars for compose/template rendering
    env_map = {
        "COMPOSE_PROJECT_NAME": str(global_cfg["project_name"]),
        "STACK_ROOT": str(global_cfg["stack_root"]),
        "TLS_ENABLED": "true" if global_cfg["tls_enabled"] else "false",
        "CERTBOT_EMAIL": str(global_cfg["certbot_email"]),
    }

    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    # Write .env (used by docker compose)
    env_path = GENERATED_DIR / ".env"
    with env_path.open("w", encoding="utf-8") as f:
        for k, v in env_map.items():
            f.write(f"{k}={v}\n")

    # Render templates
    jenv = Environment(
        loader=FileSystemLoader(str(TEMPLATES_DIR)),
        undefined=StrictUndefined,
        autoescape=False,
        trim_blocks=True,
        lstrip_blocks=True,
    )

    # Compose
    compose_tpl = jenv.get_template("docker-compose.yml.j2")
    compose_out = compose_tpl.render(global=global_cfg, instances=instances, env=env_map)
    (GENERATED_DIR / "docker-compose.yml").write_text(compose_out + "\n", encoding="utf-8")

    # Per-instance configs
    nginx_tpl = jenv.get_template("nginx.conf.j2")
    ookla_tpl = jenv.get_template("OoklaServer.properties.j2")

    names_txt = []
    for inst in instances:
        name = inst["name"]
        names_txt.append(name)

        inst_dir = CONFIG_DIR / name
        inst_dir.mkdir(parents=True, exist_ok=True)

        # nginx.conf
        nginx_out = nginx_tpl.render(global=global_cfg, inst=inst)
        (inst_dir / "nginx.conf").write_text(nginx_out + "\n", encoding="utf-8")

        # OoklaServer.properties
        # Guarantee nested dict exists
        inst.setdefault("ookla", {})
        inst["ookla"].setdefault("properties_raw", "")
        ookla_out = ookla_tpl.render(inst=inst)
        (inst_dir / "OoklaServer.properties").write_text(ookla_out + "\n", encoding="utf-8")

    (GENERATED_DIR / "instances.txt").write_text("\n".join(names_txt) + "\n", encoding="utf-8")

    print("[render.py] OK: arquivos gerados em /opt/speedtest-docker-stack/generated/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
