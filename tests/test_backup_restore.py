"""Backup and restore round trip on the dbrecords project.

One record is written, backed up (online and offline), the project is wiped
and recreated empty, then each backup is restored (offline, then online) and
the record must come back with the same date and time.

The steps depend on each other, so they are one test: a failure message says
which step broke.
"""

import gzip

from conftest import (GenropySite, gnrdev, project_leftovers, read_env,
                      remove_project)
from test_dbrecords import PROJECT, RECORD_TEXT, listed_records


def start_site(project_factory):
    """Creates and starts the project, waits for the site."""
    env = read_env(project_factory(PROJECT))
    site = GenropySite(f"http://localhost:{env['GNR_PORT_WEB']}")
    site.wait_ready()
    return site


def wipe_and_recreate(project_factory):
    """Stops and removes the project, checks nothing is left, starts it again
    from scratch and checks its database is empty."""
    gnrdev("down", PROJECT, timeout=300)
    remove_project(PROJECT)
    assert project_leftovers(PROJECT) == [], "rm left something behind"

    site = start_site(project_factory)
    assert listed_records(site) == [], "the recreated project is not empty"
    return site


def assert_backup_written(path):
    """The dump exists, is a valid gzip and contains the record."""
    assert path.exists(), f"{path.name} not written"
    with gzip.open(path, "rt", errors="replace") as f:
        assert RECORD_TEXT in f.read(), f"{path.name} does not contain the record"


def test_backup_and_restore_round_trip(project_factory, tmp_path):
    online_dump = tmp_path / "online.sql.gz"
    offline_dump = tmp_path / "offline.sql.gz"

    # 1-2. One record, remembered as the list shows it (date, time and text).
    site = start_site(project_factory)
    site.page_source("/insert_record.py")
    rows = listed_records(site)
    assert len(rows) == 1, f"expected one record, got {rows}"
    record = rows[0]

    # 3. Both backup modes must complete; offline restarts the stack after.
    gnrdev("backup", PROJECT, str(online_dump), timeout=300)
    assert_backup_written(online_dump)
    gnrdev("backup", PROJECT, str(offline_dump), "--offline", timeout=300)
    assert_backup_written(offline_dump)
    site.wait_ready()

    # 4-5. Wipe everything: the recreated project starts with an empty table.
    site = wipe_and_recreate(project_factory)

    # 6-7. Offline restore (the default): the record is back, same timestamp.
    gnrdev("restore", PROJECT, str(offline_dump), "--yes", timeout=300)
    site.wait_ready()
    assert listed_records(site) == [record], "offline restore: record not restored"

    # 8. Wipe again.
    site = wipe_and_recreate(project_factory)

    # 9-10. Online restore, with the stack running.
    gnrdev("restore", PROJECT, str(online_dump), "--online", "--yes", timeout=300)
    assert listed_records(site) == [record], "online restore: record not restored"
