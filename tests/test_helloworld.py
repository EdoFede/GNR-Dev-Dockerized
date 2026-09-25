"""The basic flow: create a project, start it, browse its pages.

    ./gnrdev new gnrdev_test_helloworld --projects-dir tests/genropy_projects
    ./gnrdev up gnrdev_test_helloworld --no-dbmigrate

The assertions stay loose on purpose: they check what the page shows, not how
the framework builds it, so they survive changes in Genropy's markup.
"""

import pytest

from conftest import TEST_PROJECTS, GenropySite, element_strings, read_env

PROJECT = "gnrdev_test_helloworld"


@pytest.fixture(scope="module")
def env(project_factory):
    return read_env(project_factory(PROJECT, "--no-dbmigrate"))


@pytest.fixture(scope="module")
def site(env):
    site = GenropySite(f"http://localhost:{env['GNR_PORT_WEB']}")
    site.wait_ready()
    return site


def test_new_uses_the_test_projects_dir(env):
    assert env["GNR_PROJECT"] == PROJECT
    assert env["GNR_INSTANCE"], "no instance detected"
    assert env["GNR_PROJECTS_DIR"] == str(TEST_PROJECTS)


def test_index_links_hello_world(site):
    strings = list(element_strings(site.page_source("/")))
    assert any("hello_world" in s for s in strings), "hello_world page not listed in the index"


def test_hello_world_page_shows_hello_world(site):
    strings = element_strings(site.page_source("/hello_world.py"))
    assert any("hello world" in s.lower() for s in strings), "'Hello world' not in the page"
