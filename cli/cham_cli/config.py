"""Configuration loading and saving for Cham CLI."""

import os
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

import tomli_w


CONFIG_DIR = Path.home() / ".config" / "cham"
CONFIG_FILE = CONFIG_DIR / "config.toml"

DEFAULTS = {
    "server": {
        "url": "http://localhost:4000",
        "api_key": "",
    }
}


def load_config() -> dict:
    """Load config from TOML file, with env var overrides."""
    config = _deep_copy(DEFAULTS)

    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, "rb") as f:
                file_config = tomllib.load(f)
            _deep_merge(config, file_config)
        except Exception as e:
            print(f"Warning: could not read config file: {e}", file=sys.stderr)

    # Env var overrides
    env_url = os.environ.get("CHAM_URL")
    if env_url:
        config["server"]["url"] = env_url

    env_key = os.environ.get("CHAM_API_KEY")
    if env_key:
        config["server"]["api_key"] = env_key

    return config


def save_config(config: dict) -> None:
    """Save config to TOML file."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_FILE, "wb") as f:
        tomli_w.dump(config, f)


def get_server_url(config: dict) -> str:
    return config["server"]["url"].rstrip("/")


def get_api_key(config: dict) -> str:
    return config["server"]["api_key"]


def redact_api_key(key: str) -> str:
    """Redact API key for display, showing only last 4 chars."""
    if not key:
        return "(not set)"
    if len(key) <= 4:
        return "****"
    return "****" + key[-4:]


def _deep_copy(d: dict) -> dict:
    result = {}
    for k, v in d.items():
        if isinstance(v, dict):
            result[k] = _deep_copy(v)
        else:
            result[k] = v
    return result


def _deep_merge(base: dict, override: dict) -> None:
    """Merge override into base, in place."""
    for k, v in override.items():
        if k in base and isinstance(base[k], dict) and isinstance(v, dict):
            _deep_merge(base[k], v)
        else:
            base[k] = v
