"""Shared fixtures: drive ./gnrdev against the minimal projects in
tests/genropy_projects and talk to the resulting site over HTTP.

These are end-to-end tests: they need Docker and create real containers.
Set GNRDEV_TEST_KEEP=1 to leave a project running after the tests, to
inspect it by hand (remove it later with ./gnrdev rm <project> --yes).
"""

import http.cookiejar
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
GNRDEV = ROOT / "gnrdev"
TEST_PROJECTS = ROOT / "tests" / "genropy_projects"

# First start of the official image may pull it and install dependencies.
UP_TIMEOUT = 15 * 60
HTTP_READY_TIMEOUT = 5 * 60


def gnrdev(*args, timeout=UP_TIMEOUT, check=True):
    """Runs ./gnrdev and returns the CompletedProcess; output is captured and
    shown in the failure message, so a broken step explains itself."""
    env = dict(os.environ, NO_COLOR="1")
    proc = subprocess.run(
        [str(GNRDEV), *args], cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
        capture_output=True, text=True, timeout=timeout,
    )
    if check and proc.returncode != 0:
        pytest.fail(
            f"./gnrdev {' '.join(args)} exited {proc.returncode}\n"
            f"--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}"
        )
    return proc


def read_env(path):
    """Minimal KEY=VALUE parser for the project .env files."""
    values = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    return values


class GenropySite:
    """HTTP client for a Genropy site, speaking the same protocol as the
    browser: a page answers GET with a bootstrap HTML that carries a page_id,
    then the client asks for the page content with the `main` RPC."""

    def __init__(self, base_url):
        self.base_url = base_url.rstrip("/")
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )

    def url(self, path):
        return f"{self.base_url}/{path.lstrip('/')}"

    def get(self, path, timeout=30):
        with self.opener.open(self.url(path), timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")

    def wait_ready(self, path="/", timeout=HTTP_READY_TIMEOUT):
        """Polls until the site answers 200: after `up` the server may still
        be starting."""
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            try:
                status, _ = self.get(path, timeout=10)
                if status == 200:
                    return
                last = f"HTTP {status}"
            except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
                last = repr(e)
            time.sleep(2)
        pytest.fail(f"{self.url(path)} not ready after {timeout}s (last: {last})")

    def page_source(self, path):
        """Returns the page content as the client receives it (the `main` RPC
        result), parsed as an XML element."""
        status, html = self.get(path)
        assert status == 200, f"GET {path}: HTTP {status}"
        m = re.search(r"page_id\s*:\s*'([^']+)'", html)
        assert m, f"GET {path}: no page_id in the bootstrap HTML"
        data = urllib.parse.urlencode({"method": "main", "page_id": m.group(1)}).encode()
        with self.opener.open(self.url(path), data=data, timeout=60) as resp:
            assert resp.status == 200, f"main RPC on {path}: HTTP {resp.status}"
            body = resp.read()
        root = ET.fromstring(body)
        result = root.find("result")
        assert result is not None, f"main RPC on {path}: no <result> in the response"
        return result


def element_strings(element):
    """Every text and attribute value in an element tree: the content may sit
    in either, depending on how the framework serialises a widget."""
    for node in element.iter():
        if node.text and node.text.strip():
            yield node.text.strip()
        yield from node.attrib.values()


@pytest.fixture(scope="session")
def project_factory():
    """Creates and starts projects from tests/genropy_projects; removes them
    (containers, volumes, .env) at the end of the session."""
    created = []

    def start(name, *up_args):
        env_file = ROOT / "projects" / f"{name}.env"
        if env_file.exists():
            pytest.fail(
                f"{env_file.relative_to(ROOT)} already exists: the tests create it "
                f"from scratch. Remove it first with ./gnrdev rm {name} --yes"
            )
        gnrdev("new", name, "--projects-dir", str(TEST_PROJECTS), timeout=60)
        created.append(name)
        gnrdev("up", name, *up_args)
        return env_file

    yield start

    if os.environ.get("GNRDEV_TEST_KEEP") == "1":
        return
    for name in created:
        gnrdev("rm", name, "--yes", timeout=300, check=False)
