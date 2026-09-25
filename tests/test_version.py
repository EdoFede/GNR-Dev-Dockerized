"""Which framework a project actually runs, in each framework mode.

    ./gnrdev new gnrdev_test_version --projects-dir tests/genropy_projects
    ./gnrdev up gnrdev_test_version --no-dbmigrate                        # image
    ./gnrdev up gnrdev_test_version --framework-git <ref> --no-dbmigrate
    ./gnrdev up gnrdev_test_version --framework-local --no-dbmigrate

version.py shows gnr.VERSION and whether the framework is a git checkout,
detected as `gnr dev bugreport` does. The same project is restarted in each
mode, so the tests run in file order and each one leaves the stack in its mode.
"""

import re

import pytest

from conftest import ROOT, GenropySite, gnrdev, read_env

PROJECT = "gnrdev_test_version"
PAGE = "/version.py"

IMAGE_TAG = "26.09.29"
GIT_COMMIT = "1dba6ba"
GIT_COMMIT_RELEASE = "26.09.04"

# What a failed start leaves in the output or in the app logs
ERROR_RE = re.compile(r"Traceback|: ERROR:|\bFATAL\b|exited: ")


@pytest.fixture(scope="module")
def env(project_factory):
    return read_env(project_factory(PROJECT, "--no-dbmigrate", env={"GENROPY_TAG": IMAGE_TAG}))


@pytest.fixture(scope="module")
def site(env):
    return GenropySite(f"http://localhost:{env['GNR_PORT_WEB']}")


def up(*args):
    """Restarts the project in another framework mode; the start must be clean."""
    proc = gnrdev("up", PROJECT, *args, "--no-dbmigrate")
    assert not ERROR_RE.search(proc.stdout + proc.stderr), f"errors during up:\n{proc.stdout}\n{proc.stderr}"


def framework_info(site):
    """The values version.py shows, keyed by name (genropy_version, ...).
    Also checks that the app started without errors."""
    site.wait_ready(PAGE)
    logs = gnrdev("logs", f"{PROJECT}.app").stdout
    errors = [line for line in logs.splitlines() if ERROR_RE.search(line)]
    assert not errors, "errors in the app logs:\n" + "\n".join(errors)
    info = {}
    for node in site.page_source(PAGE).iter():
        cls = node.attrib.get("_class", "")
        if cls.startswith("version_"):
            info[cls[len("version_"):]] = node.attrib.get("innerHTML")
    assert "genropy_version" in info, f"no version in {PAGE}"
    return info


def local_framework_version():
    """VERSION from the host checkout (HOST_GENROPY), or None without one."""
    genropy = read_env(ROOT / ".env").get("HOST_GENROPY", "").strip('"')
    init = ROOT / genropy / "gnrpy" / "gnr" / "__init__.py" if genropy else None
    if not init or not init.is_file():
        return None
    m = re.search(r"""^VERSION\s*=\s*['"]([^'"]+)['"]""", init.read_text(), re.M)
    return m.group(1) if m else None


def test_image_runs_the_tag_release(site):
    info = framework_info(site)
    assert info["genropy_version"] == IMAGE_TAG
    assert info["genropy_from_git"] == "False"


def test_framework_git_runs_the_commit_release(site):
    up("--framework-git", GIT_COMMIT)
    info = framework_info(site)
    assert info["genropy_version"] == GIT_COMMIT_RELEASE
    assert info["genropy_from_git"] == "True"
    assert info["genropy_git_commit"].startswith(GIT_COMMIT)


def test_framework_local_runs_the_host_checkout(site):
    expected = local_framework_version()
    if expected is None:
        pytest.skip("no local framework: HOST_GENROPY not set or not a genropy checkout")
    up("--framework-local")
    assert framework_info(site)["genropy_version"] == expected
