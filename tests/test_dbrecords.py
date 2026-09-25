"""A project with a database: first start creates the schema, pages write and
read records.

    ./gnrdev new gnrdev_test_dbrecords --projects-dir tests/genropy_projects
    ./gnrdev up gnrdev_test_dbrecords

insert_record.py adds a row (current date/time and a fixed text) each time it
is built; list_records.py prints every row. The checks count the fixed text in
the list, so they depend on the data, not on the markup.
"""

import pytest

from conftest import GenropySite, element_strings, read_env

PROJECT = "gnrdev_test_dbrecords"
# Same text as RECORD_TEXT in webpages/insert_record.py
RECORD_TEXT = "gnrdev test record"


@pytest.fixture(scope="module")
def site(project_factory):
    env = read_env(project_factory(PROJECT))
    site = GenropySite(f"http://localhost:{env['GNR_PORT_WEB']}")
    site.wait_ready()
    return site


def listed_records(site):
    """The rows list_records.py shows ("<date> <time> <text>")."""
    strings = element_strings(site.page_source("/list_records.py"))
    return [s for s in strings if RECORD_TEXT in s]


def test_insert_page_shows_the_new_record(site):
    strings = element_strings(site.page_source("/insert_record.py"))
    assert any(RECORD_TEXT in s for s in strings), "inserted record not shown"


def test_list_page_shows_every_inserted_record(site):
    before = len(listed_records(site))
    for _ in range(3):
        site.page_source("/insert_record.py")
    assert len(listed_records(site)) == before + 3
