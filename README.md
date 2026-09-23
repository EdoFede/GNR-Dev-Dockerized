# GenroPy Dev Dockerized

_A Dockerized development environment for Genropy projects_

[![Italiano](https://img.shields.io/badge/lang-Italiano-1f6feb?style=flat-square)](README.it.md)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;[![License](https://img.shields.io/badge/license-Apache--2.0-6f42c1?style=flat-square)](LICENSE)&nbsp;![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-0aa344?style=flat-square)&nbsp;![Arch](https://img.shields.io/badge/arch-arm64%20%7C%20amd64-fd7e14?style=flat-square)&nbsp;![DB](https://img.shields.io/badge/db-PostgreSQL-336791?style=flat-square)

Run the Genropy framework and its runtime dependencies in containers while
keeping sources on the host, bind-mounted and edited with your usual tools.
Each project gets its own isolated stack (app + PostgreSQL), so several
projects can run in parallel without their Python dependencies colliding.

Nothing needs to be installed on the host except Docker.

## How it works

One Compose stack per project, all generated from a single parametric
`compose.project.yaml` plus a per-project `.env`. Adding a project means adding
an env file, not another YAML.

```
gnr-<project>
├── db     postgres, dedicated volume
└── app    gnr web daemon + gnr web serve (same container)
```

The daemon and the web server share a container by necessity: the site register
client checks the site daemon's PID with `psutil.pid_exists()`, which is
PID-namespace local. Each project runs its own daemon via `<sitedaemon/>`, so
there is no shared daemon coupling projects together.

## Setup

```bash
cp .env.example .env     # check source paths and HOST_UID / HOST_GID
```

`HOST_UID`/`HOST_GID` should match `id -u` / `id -g`. They matter: the daemon
writes state files into the bind-mounted site directory, and misaligned
ownership makes those files awkward to handle from the host.

## Daily use

```bash
./gnrdev new <project> [instance]   # create projects/<project>.env, allocate ports
./gnrdev up <project>               # start the stack
./gnrdev ls                         # projects and their status
./gnrdev logs <project> -f          # aggregated logs
./gnrdev down <project>             # stop the stack
```

`new` detects the instance automatically when a project has exactly one; with
several, it lists them and asks you to pick.

On first start `up` notices the database is empty and runs `gnr db migrate`
itself — no manual bootstrap step. Use `--no-dbmigrate` to skip it.

### Example: two projects side by side

```bash
$ ./gnrdev new sandbox sandboxpg
==> created projects/sandbox.env
    project  : sandbox
    instance : sandboxpg
    web      : http://localhost:9000
    debugpy  : 9100

$ ./gnrdev up sandbox
$ ./gnrdev new edodevel && ./gnrdev up edodevel

$ ./gnrdev ls
PROJECT            INSTANCE         STATUS    WEB PORT   DEBUG PORT  DB PORT  NETWORK        URL
edodevel           edodevel         running   9001       -           9201     -              http://localhost:9001
sandbox            sandboxpg        running   9000       -           9200     -              http://localhost:9000
```

Stacks are fully independent: stopping or breaking one leaves the others
untouched.

### Schema changes

```bash
./gnrdev dbcheck <project>      # show pending changes, apply nothing
./gnrdev dbmigrate <project>    # apply them
```

Both use `gnr db migrate`. Run `dbcheck` first on a project you don't know well:
the NG migrator catches discrepancies the legacy `db setup` silently ignored,
including ones caused by typos in the model.

### Other commands

```bash
./gnrdev rm <project>                 # remove containers, volumes and config
./gnrdev shell <project>              # bash in the app container
./gnrdev gnr <project> <args...>      # gnr CLI inside the container
./gnrdev psql <project>               # psql client
./gnrdev restart <project>            # restart the app service
./gnrdev rebuild <project>            # rebuild the image
```

`logs`, `shell` and `restart` accept `<project>.<service>` to target a single
container:

```bash
./gnrdev logs sandbox.app -f          # application only
./gnrdev logs sandbox.db              # database only
./gnrdev shell sandbox.db             # shell in the postgres container
./gnrdev restart sandbox.db           # restart just the database
```

Services: `app`, `db` (plus `init-perms`, `framework-src`).

Containers get a hostname matching their name, so the shell prompt tells you
where you are: `genro@gnr-sandbox-app`.

### Backup and restore

```bash
./gnrdev backup <project> [file] [--offline]
./gnrdev restore <project> <file> [--yes] [--online]
./gnrdev backups                             # list what has been taken
```

A backup is a single gzipped `pg_dumpall`, so it covers every database in the
project cluster — which matters for multidb instances, where each store is its
own database. Service databases and roles are filtered out: the cluster belongs
to the project and its role already exists, so replaying them would only produce
errors during the restore.

Without a filename the default is `backups/<project>_YYYY-mm-dd__HH-MM-SS.sql.gz`
(`.gz` is appended if you leave it off). `backups/` is git-ignored.

**Quiescing the stack.** A restore drops and recreates the databases, which open
connections would block, so by default it stops every service except the
database and restarts them when done. `--online` skips that — useful when
nothing is holding connections, at the risk of the restore failing.

A backup runs against the live stack by default. Pass `--offline` to stop the
other services first, for a dump taken with nothing writing to the database.
Either way the containers are restarted afterwards, including when the command
fails or is interrupted.

Restoring replaces the current content of the cluster, so it asks first;
`--yes` skips the prompt.

```bash
$ ./gnrdev backup sandbox
==> dumping the sandbox cluster
==> written backups/sandbox_2026-09-23__10-03-13.sql.gz (1.1M)

$ ./gnrdev backup sandbox --offline
==> stopping:app
==> dumping the sandbox cluster
==> restarting:app
==> written backups/sandbox_2026-09-23__10-05-26.sql.gz (1.1M)

$ ./gnrdev restore sandbox backups/sandbox_2026-09-23__10-03-13.sql.gz --yes
==> stopping:app
==> restoring into sandbox
==> restarting:app
==> restore complete
```

### Removing a project

```bash
./gnrdev rm <project>                 # asks for confirmation
./gnrdev rm <project> --keep-env      # drop containers, keep the config
./gnrdev rm <project> --yes           # no prompt
```

It lists what will go before asking. The database volume is included, so the
schema and its data are lost; sources on the host are never touched. With
`--keep-env` the project config survives and `up` recreates the stack from
scratch.

## Ports

Three parallel ranges, same offset per project, so the last digits tie a
project's web, debug and database ports together:

| Project | Web | Debug | Database |
|---|---|---|---|
| first | 9000 | 9100 | 9200 |
| second | 9001 | 9101 | 9201 |
| third | 9002 | 9102 | 9202 |

Bases are `GNR_PORT_WEB_BASE` / `GNR_PORT_DEBUG_BASE` / `GNR_PORT_DB_BASE` in
`.env`. `new` picks the first offset free in *all* ranges, skipping ports
already assigned to other projects or in use on the host. The values are plain entries in the project's
`.env` and can be edited by hand.

The web port is **identical inside and outside the container** — the server is
started with `-p ${GNR_PORT_WEB}` and mapped 1:1 — so the URL Genropy logs
(`Connect at http://127.0.0.1:9000`) is the one that actually works.

PostgreSQL is published so external clients can reach it; `GNR_PORT_DB=0` in a
project `.env` keeps it unpublished.

The database image defaults to `postgres:18` (`POSTGRES_TAG` per project).

## Talking between projects

By default each stack is isolated on its own network. To let projects reach each
other, put them on a shared Docker network:

```bash
./gnrdev new sandbox sandboxpg --network gnrdev # creates the network if needed
./gnrdev up sandbox
```

`new --network` writes `GNR_NETWORK` to the project `.env` and creates the
Docker network when it does not exist yet, so there is no separate setup step.

For an existing project, either set `GNR_NETWORK` in its `.env` or force a
network for a single run — the `.env` is left untouched:

```bash
./gnrdev up sandbox --network gnrdev
```

On that network every project answers to two stable aliases, on its **internal**
ports — nothing extra needs publishing to the host:

| Alias | Reaches |
|---|---|
| `<project>` | the app container, on `GNR_PORT_WEB` |
| `<project>-db` | its database, on 5432 |

So from `edodevel`, sandbox's API is `http://sandbox:9000` and its database is
`sandbox-db:5432`. Host access through the published port keeps working as
before.

```bash
$ ./gnrdev network list
NETWORK                  STATUS       PROJECTS
gnrdev                   available    edodevel, sandbox
isolated: infoit

$ ./gnrdev network create gnrdev      # only needed for a network no project declares yet
$ ./gnrdev network rm gnrdev          # detach projects first
```

`gnrdev ls` also shows each project's network:

```
PROJECT            INSTANCE         STATUS    WEB PORT   DEBUG PORT  DB PORT  NETWORK        URL
edodevel           edodevel         running   9001       -           9201     gnrdev         http://localhost:9001
sandbox            sandboxpg        running   9000       -           9200     gnrdev         http://localhost:9000
```

Leaving `GNR_NETWORK` empty keeps a project isolated.

## Remote debugging (GNR_PORT_DEBUG)

`GNR_PORT_DEBUG` is only used for IDE debugging. If you never attach a debugger,
the port sits unused and you can drop it from the project's `.env`.

It exists as a separate port because of how the framework starts debugpy:
`debugpy.listen(("localhost", 5678))` binds to the container's loopback, so
publishing 5678 directly would not be reachable from the host. A `socat` bridge
inside the container forwards 5679 → 5678, and `GNR_PORT_DEBUG` maps that 5679.

### When it's worth it

Reach for it when print-and-reload stops paying off: stepping through a
`@public_method` invoked from the client, inspecting a Bag whose structure isn't
obvious from logs, catching an exception raised deep in a table trigger or in a
`gnr db migrate` upgrade, or understanding why a resource resolves to the wrong
package across projects. For a quick check of a value, a log line is faster.

### How to use it

```bash
./gnrdev debug sandbox
```

This stops the supervised server, starts the socat bridge, and restarts
`gnr web serve` with `--debugpy` on the same web port. Then attach from your IDE
to the project's debug port. `gnrdev ls` shows the debug port in its DEBUG
column while a project runs this way, and `./gnrdev restart <project>` puts it
back under supervisor.

VS Code `launch.json` — the second mapping is only needed if you also step into
framework code:

```json
{
  "type": "debugpy", "request": "attach",
  "connect": { "host": "localhost", "port": 9100 },
  "pathMappings": [
    { "localRoot": "${workspaceFolder}",
      "remoteRoot": "/home/genro/genropy_projects/sandbox" },
    { "localRoot": "/path/to/genropy",
      "remoteRoot": "/home/genro/genropy" }
  ]
}
```

PyCharm: *Attach to process* → *Python Debug Server*, same host and port, with
equivalent path mappings.

Two things to know:

- **Autoreload is off while debugging.** The framework disables it under
  `--debugpy` (the reloader forks and would drop the attach). After editing,
  run `./gnrdev restart <project>` to get back to the supervised server with
  reload enabled.
- The debugger does not wait for you. Attach before triggering the code path you
  care about, or set the breakpoint and reproduce afterwards.

## Framework version

`GENROPY_TAG` in `.env` pins the official image tag (`latest`, `develop`, or a
version like `26.05.05`). After changing it: `./gnrdev rebuild <project>`.

To work on the framework itself, or to use a specific branch/commit:

```bash
./gnrdev up <project> --framework-src
```

This mounts the checkout at `HOST_GENROPY`, optionally moved to
`GNR_FRAMEWORK_REF`, and installs it editable with the `[developer,pgsql]`
profiles from the installation guide — framework edits take effect immediately.
It also gives you the dojo versions missing from the official image.

It builds a separate image (tagged `:fwsrc`) with the framework removed from
`site-packages`, which would otherwise shadow the mounted checkout. The
entrypoint verifies the checkout is really in use and fails if it is not.

## Cross-project dependencies

Declare them as usual in the instance config with
`pkgcode="project:package"`. The `genropy_projects` and `gnrextra_projects`
trees are mounted whole, so this normally works with no extra configuration.

`GNR_DEP_PROJECTS` in the project `.env` documents the relationship; Python
dependencies are resolved by `gnr app checkdep`, which runs at container start.

One caveat worth knowing: `project_path()` returns the *first* directory
matching a project name across the declared `<projects>` roots. If the same name
exists in more than one tree, order decides which wins — a package can be
reported missing while sitting on disk.

## Layout

```
compose.project.yaml     per-project stack (single parametric file)
compose.framework.yaml   override for framework-from-source
compose.network.yaml     override applied when GNR_NETWORK is set
docker/                  dev Dockerfile, entrypoint, supervisor config
gnrfolder/               .gnr config, mounted read-only into containers
projects/<name>.env      per-project config (not versioned)
gnrdev                   command wrapper
```

Implementation notes and framework constraints: `docs/troubleshooting.md`.

## License

Copyright (c) 2026 Edoardo Federici

Licensed under the Apache License 2.0 — the license Softwell uses for the
recent Genropy repositories. See [LICENSE](LICENSE).
