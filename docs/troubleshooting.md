# Implementation notes

Constraints verified in the Genropy sources while building this environment.
They explain why some choices are what they are.

## One stack per project, no shared daemon

On the host the habit is one `gnr web daemon` plus N `gnr web serve`. That does
not carry over to containers:

- `addSiteRegister` (`gnr/web/daemon/handler.py:281-296`) forks the site
  registers with `multiprocessing.Process` **inside the daemon's container**,
  and they load the instance code. A shared daemon would need the sources and
  pip packages of every project.
- `checkdep` installs with `pip install` into the running interpreter
  (`gnr/app/gnrapp.py:1093`), so a shared interpreter cannot isolate
  dependencies.

It is not needed anyway: with `<sitedaemon/>` the client reads the URIs from
`sitedaemon.xml` and **never contacts the central GnrDaemon**
(`gnr/web/daemon/siteregister_client.py:136-148`).

## daemon and serve share a container

`siteregister_client.py:142` checks the PID from `sitedaemon.xml` with
`psutil.pid_exists()`, which is PID-namespace local — separate containers would
give false positives.

For the same reason the entrypoint **removes `sitedaemon.xml` at every start**:
after an unclean stop the file survives in the bind mount with a PID that may
match an unrelated process in the new container.

## Autoreload

inotify events do not cross the bind mount from macOS, and Werkzeug hardcodes
`reloader_type="auto"` (`gnr/web/serverwsgi.py:411`), which selects the inotify
observer.

`docker/polling_observer.py`, installed as a `.pth`, swaps
`watchdog.observers.Observer` for the `PollingObserver` when
`GNR_FORCE_POLLING=1`. A `.pth` runs on every interpreter start, so it also
covers the children the reloader spawns.

Measured on OrbStack: `stat` over 28k files takes ~0.2s, negligible.
`GNR_POLLING_INTERVAL` (default 1.0s) tunes the frequency.

`--debugpy` disables autoreload (`serverwsgi.py:316`) — correct, since the
reloader forks and would drop the attach.

## Read-only environment.xml

Without `<external_secret>` the framework generates one and tries to **rewrite
the file** (`gnr/core/gnrconfig.py:219-229`), which fails on the read-only
mount. Hence the value is present in `gnrfolder/environment.xml`.

Also because of the read-only mount, `<gnrdaemon>` holds literal values rather
than `{GNR_*}` placeholders: `getFullOptions` (`handler.py:56`) re-reads the
file **without** env interpolation.

## Order of the <projects> paths

`project_path()` returns the first directory matching a project name. The
sources contain **two** `gnrextra`: a partial one in `genropy_projects` (only
`srvy`, `wpn`) and the complete one in `gnrextra_projects`. With the partial one
first, `pkgcode="gnrextra:neon"` fails with `package neon not found`.

A name collision across trees always looks like this: a package reported
missing while sitting on disk.

## Web port identical inside and out

Supervisor starts the server with `gnr web serve <instance> -p ${GNR_PORT_WEB}`
and the compose mapping is 1:1, so the URL in the framework logs is the real
one.

The port cannot be set through `GNR_WSGI_OPT_PORT`: `dictExtract`
(`gnr/core/gnrdict.py:42`) yields the key `PORT` while `init_options`
(`gnr/web/serverwsgi.py:294`) compares against `port`, so the env override never
applies. Hence the CLI argument.

## Volume permissions

Named volumes are created root-owned while processes run as `genro`. The
`init-perms` service fixes `pylibs` before `app` starts.

`PIP_USER=1` makes `checkdep` install into `PYTHONUSERBASE`, i.e. the
per-project volume; without it pip would target `/usr/local` (not writable) and
projects would share packages.

`HOST_UID`/`HOST_GID` align the container user with the host one, so the files
the daemon writes into the sitepath (`sitedaemon.xml`,
`siteregister_data.pik`) stay manageable.

## Backups

`pg_dumpall` covers every database in the cluster, which matters for multidb
instances where each store is its own database. Roles and the service databases
are filtered out: the cluster belongs to the project, its role already exists,
and `psql` connects to `postgres` during the restore — replaying them would only
produce `cannot drop the currently open database`.

Backup `--offline` and the default restore quiesce the stack through a `trap`,
so the containers come back even on failure or Ctrl-C.

## supervisorctl needs a socket

The image's `/etc/supervisor/supervisord.conf` declares `serverurl` for
supervisorctl but no `[unix_http_server]`, so the socket is never created and
`supervisorctl` cannot reach supervisord — which `gnrdev debug` relies on.
`docker/supervisor/supervisord.conf` replaces it and adds the section.

## PostgreSQL 18 data path

PostgreSQL 18 expects a single mount at `/var/lib/postgresql` and keeps the
cluster in a `data` subdirectory; mounting `/var/lib/postgresql/data` directly
makes it refuse to start with "There appears to be PostgreSQL data in ...
(unused mount/volume)". The compose file mounts the volume one level up.

Versions up to 17 are the opposite: their image declares
`VOLUME /var/lib/postgresql/data`, so with the mount one level up Docker adds an
anonymous volume on that path. The cluster ends up there, and every recreated
db container starts from an empty database while the old one is left dangling.
For a `POSTGRES_TAG` below 18, `gnrdev` adds `compose.pg-legacy.yaml`, which
mounts the volume on `/var/lib/postgresql/data` instead.

A volume initialised by 16 cannot be read by 18 regardless: upgrading
`POSTGRES_TAG` on a project with data means `./gnrdev backup`, recreate, then
`./gnrdev restore`.

## Framework from source and the image copy of gnr

The official image installs the framework into
`/usr/local/lib/python3.11/site-packages/gnr`, non-editable. That path is
searched before the editable finder, so an editable install of the mounted
checkout is not enough: `pip list` reports the checkout while `import gnr` still
loads the image copy — silently, with framework edits having no effect.

The directory is therefore removed at **build time** (`FRAMEWORK_FROM_SRC=1` in
`Dockerfile.dev`), since `site-packages` is not writable by the `genro` user at
runtime; the same build replaces `/home/genro/genropy` with a symlink to
`/home/genro/framework`, so the static assets declared in `environment.xml`
come from the same tree as the Python code. Both source modes tag that image
`:fwsrc`, so projects on the official image never reuse it.

`/home/genro/framework` is the single mount point: `compose.framework-local.yaml`
bind-mounts the host checkout there, `compose.framework-git.yaml` mounts a
per-project volume that the `fwgit` service clones and re-checks-out at every
start.

The install follows the installation guide profiles:
`pip install --user -e <checkout>/gnrpy[developer,pgsql]`. The entrypoint then
verifies that `import gnr` really resolves inside the checkout and fails loudly
if it does not.

## Colours through `docker compose exec`

`exec -T` gives the command no TTY, and the tools inside the container then drop
their colours. `gnrdev` passes `-T` only when its own stdout is not a terminal
(`exec_tty_flag`), so colours survive interactive use while redirected output
stays clean and scripted runs do not fail with "the input device is not a TTY".

## Framework refs and stale networks

`fwgit` resolves the ref before checking it out. A name that is neither a
branch, a tag nor a commit stops the start with a readable error and, when the
name looks like part of an existing branch, the candidates:

```
[fwgit] ERROR: '496-runtime-model' is not a branch, tag or commit of ...
[fwgit] did you mean:
[fwgit]   feature/496-runtime-model
```

Without the check git reports `--detach does not take a path argument`, which
says nothing about the ref being missing. Branch names in the Genropy
repository are often prefixed (`feature/`, `fix/`), so the full name is needed.

Containers left from a previous run can also keep a reference to a network that
no longer exists, and compose then fails with `network <id> not found`. `up`
removes stopped containers of the project before starting: their state lives in
the volumes, so nothing is lost.

## Notes on the official image

- `GNRLOCAL_PROJECTS` in the official Dockerfile is a typo: the code reads
  `GNR_LOCAL_PROJECTS` (`gnr/app/pathresolver.py:61`).
- The image ships no `siteconfig/`, so there is no reload/debug until we provide
  one.
- It ships `watchgod` but not `watchdog`.
- `debugpy.listen` binds to `localhost` (`serverwsgi.py:320`), so publishing the
  port is not enough — hence the `socat` bridge.
- Python 3.11; the framework requires >= 3.11.
- `GNR_WSGI_OPT_*` does not work for wsgi options: see the port section.
- Its `supervisord.conf` has no `[unix_http_server]`: see above.

## Common problems

**"package X not found" but the directory exists** — name collision across
project trees: see the `<projects>` order.

**`relation "adm.adm_preference" does not exist`** — empty database. Normally
`up` creates the schema on first start; if it was skipped with
`--no-dbmigrate`, run `./gnrdev dbmigrate <project>`.

**`db migrate` proposes an unexpected CREATE SCHEMA** — the NG migrator catches
discrepancies the legacy `db setup` ignored, typos in the model included. In
sandbox, `packages/sandbox/main.py` declares `sqlschema='sabdbox'`, so migrate
proposes `CREATE SCHEMA "sabdbox"`. Check with `./gnrdev dbcheck` first.

**The app does not answer right after `up`** — the first start installs
dependencies and builds resources. Follow `./gnrdev logs <project> -f`.

**Edits have no effect** — check polling is active: `./gnrdev shell <project>`
then `python3 -c "import watchdog.observers as o; print(o.Observer.__name__)"`,
which must print `_TunedPollingObserver`.
