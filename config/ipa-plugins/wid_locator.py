"""Service locator for WID appliance components.

Config-driven in Phase 1. SRV record discovery planned for Phase 2.
"""

import configparser
import logging
from pathlib import Path
from urllib.request import urlopen
from urllib.error import URLError

log = logging.getLogger(__name__)

CONFIG_SEARCH = [
    "/etc/ipa-wid/wid.conf",
    "/etc/ipa/oauth2d/oauth2d.conf",
]

SERVICES = ["ahdapa", "obo", "akamu", "spire"]


class WIDServiceLocator:
    def __init__(self, config_path=None, fallback_paths=None):
        self._config = configparser.ConfigParser()
        paths = []
        if config_path:
            paths.append(config_path)
        if fallback_paths:
            paths.extend(fallback_paths)
        if not paths:
            paths = CONFIG_SEARCH

        for p in paths:
            try:
                if Path(p).is_file():
                    self._config.read(p)
                    log.debug("WID config loaded from %s", p)
                    break
            except (PermissionError, OSError):
                continue

    def _find(self, service: str) -> str | None:
        try:
            return self._config.get(service, "url")
        except (configparser.NoSectionError, configparser.NoOptionError):
            return None

    def find_ahdapa(self) -> str | None:
        return self._find("ahdapa")

    def find_obo(self) -> str | None:
        return self._find("obo")

    def find_akamu(self) -> str | None:
        return self._find("akamu")

    def find_spire(self) -> str | None:
        return self._find("spire")

    def is_healthy(self, service: str) -> bool:
        url = self._find(service)
        if not url:
            return False
        try:
            resp = urlopen(f"{url}/health", timeout=5)
            return resp.status == 200
        except (URLError, OSError):
            return False

    def status_message(self, service: str) -> str:
        url = self._find(service)
        if not url:
            return f"not configured: {service} URL not in wid.conf"
        if not self.is_healthy(service):
            return f"policy-only: {service} not responding at {url}"
        return f"active: {service} at {url}"
