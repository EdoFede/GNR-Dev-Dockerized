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

Werkzeug hardcodes `reloader_type="auto"` (`gnr/web/serverwsgi.py:411`): the
watchdog reloader when `watchdog` is importable, the stat (polling) one
otherwise. The official image has no `watchdog`, but `gnrcore/sys` requires it
(`attachment_uploader.py`), so `checkdep` installs it and the watchdog reloader
is the one in use.

It relies on inotify, and on OrbStack inotify events do cross the bind mount
from macOS: creating, editing and deleting a file on the host each trigger a
reload, for project and framework code alike. Earlier versions of this
environment forced watchdog's `PollingObserver` through a `.pth` patch; it is
no longer needed and was dropped with the dev image.

Not verified on Docker Desktop. If edits there do not reload, the stat reloader
is the fallback to reach for: it polls mtimes, which are always correct.

`--debugpy` disables autoreload (`serverwsgi.py:312`) — correct, since the
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

## Running the official image unchanged

No image is built: `app` runs `ghcr.io/genropy/genropy` as published, and what
the old dev image added is provided at runtime.

| Need | Provided by |
|---|---|
| entrypoint, supervisor config | `docker/` mounted read-only on `/opt/gnrdev` |
| host uid/gid | the entrypoint, see below |
| Python dependencies | `checkdep` into the per-project `pylibs` volume |
| `psql`, `pg_dump`, `pg_restore` | the `pgclient` service, see below |
| debugpy bridge | the `debugbridge` sidecar |
| waiting for the database | `depends_on: condition: service_healthy` |

### Runtime user

The image runs as root. The entrypoint adds a passwd entry for
`HOST_UID`/`HOST_GID` (`gnrdev`, unless the uid already exists) and drops to it
with `setpriv`, so on Linux the files written into the bind mounts — the
instance's temporary files, `sitedaemon.xml`, `siteregister_data.pik` — belong
to the host user. On macOS OrbStack maps bind-mount ownership to the host user
whatever the container uid (verified); Docker Desktop is expected to behave the
same, not verified.

Details that matter:

- A new entry, not `usermod -u genro`: `usermod` chowns the whole home, which
  would copy the framework tree into every container's writable layer.
- Only `/home/genro` and the `pylibs` volume root are chowned, not
  recursively. That replaces the old `init-perms` service.
- stdout/stderr are root-owned `0600` pipes. supervisord reopens them by path
  (`/dev/stdout`) and gets `EACCES` once root is dropped, so the entrypoint
  hands them to the user first.
- Loading a package's startup data unpacks `startup_data.gz` into a `.pik`
  next to it (`gnr/app/gnrdbo.py:157`), inside the framework tree the image owns
  as `genro`. Those package directories are chowned; a mounted checkout is
  never touched.
- `docker exec` defaults to root, so `gnrdev` always passes `-u` for app.

`PIP_USER=1` makes `checkdep` install into `PYTHONUSERBASE`, i.e. the
per-project volume; without it pip would target `/usr/local` (not writable) and
projects would share packages. Caches go to `XDG_CACHE_HOME`, inside the same
volume, so they survive a recreated container.

### Dependency stamp

`checkdep` is skipped when nothing changed. The stamp hashes the projects'
`requirements.txt`, the instance name and the list of packages in the image's
`site-packages`: a different image can drop a package the old one provided, so
after a `pull` or a `GENROPY_TAG` change the check runs again.

### PostgreSQL client tools

The postgres adapter runs `psql`, `pg_dump` and `pg_restore`
(`gnr/sql/adapters/_gnrbasepostgresadapter.py:112`) for dumps and restores; the
official image has none of them and logs `DB adapter required executables not
found`. The `pgclient` service copies them from `postgres:${POSTGRES_TAG}` —
already on disk for the db — into a volume mounted on `/opt/pgclient`.

`libpq` comes along: psql 18 needs symbols the image's `libpq` lacks
(`PQfullProtocolVersion`). Wrapper scripts set `LD_LIBRARY_PATH` for these tools
only, so psycopg keeps its own. A client from the server's own image also means
`pg_dump` is never older than the server, which it refuses to dump.

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
`docker/supervisor/supervisord.conf` is used instead (the image's file is left
alone: it also includes `conf.d/genropy.conf`, a bare `gnr web daemon`) and
adds the section. `gnrdev` points `supervisorctl` at it with `-c`.

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
checkout alone is not enough: `pip list` reports the checkout while
`import gnr` still loads the image copy — silently, with framework edits having
no effect.

Instead of removing that copy (which needed a build, since `site-packages` is
not writable at runtime), the checkout is put ahead of it:

- It is mounted over `/home/genro/genropy`: a bind mount of the host checkout
  in `compose.framework-local.yaml`, the per-project `fwgit` volume (with
  `nocopy`) in `compose.framework-git.yaml`. `environment.xml` already points
  there for the static assets, so they follow the checkout too.
- Its `gnrpy/` is set as `PYTHONPATH`, which comes before `site-packages`.
- It is still installed editable into `pylibs`
  (`pip install --user -e gnrpy[developer,pgsql]`, the installation guide
  profiles): that brings in the dependencies it declares and metadata matching
  its version. The stamp is the hash of `pyproject.toml`, so a ref with other
  dependencies reinstalls.

pip runs with `PYTHONPATH` unset. Otherwise it sees the `genropy.egg-info`
setuptools leaves in `gnrpy/` as one more installed genropy and tries to remove
the image's copy, failing with `Permission denied: '/usr/local/bin/gnr'`.

Going back to the image framework, the entrypoint uninstalls the editable
install: the user site comes before `site-packages`, so its metadata would
otherwise shadow the image's.

The entrypoint verifies that `import gnr` really resolves inside the checkout
and fails loudly if it does not. `gnrdev ls` tells the modes apart by the mount
on `/home/genro/genropy`: bind is local, volume is git, none is the image.

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
- It runs as root.
- It ships `watchgod` but not `watchdog`, and no `psql`/`pg_dump`/`pg_restore`.
- `debugpy.listen` binds to `localhost` (`serverwsgi.py:316`), so publishing the
  port is not enough — hence the `socat` sidecar, which shares the app's network
  namespace. It stays attached to the namespace of the container it started
  with, so `restart` and `down` remove it.
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

**Edits have no effect** — look for `Started server` lines in
`./gnrdev logs <project>.app -f` after saving. None on Docker Desktop points to
inotify events not crossing the bind mount: see Autoreload.

**`Permission denied` writing inside `/home/genro/genropy`** — the framework
wrote somewhere in its own tree other than the `startup_data` directories the
entrypoint hands over. Add that path to the entrypoint's chown list.
