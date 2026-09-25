#!/bin/bash
# Entrypoint of the "app" container, mounted from docker/ into the official
# image (nothing is built).
#
#   0. runtime user          -> host uid/gid, then drop root
#   1. clear sitedaemon.xml  -> stale PIDs after an unclean stop
#   2. Python dependencies   -> incremental, hash-stamped
#  2b. framework from source -> local/git mode only
#   3. check {GNR_*} vars    -> fail fast instead of a broken config
#
# The database is not waited for here: compose starts app only once the db
# healthcheck (pg_isready) passes.
set -euo pipefail

log() { echo "[entrypoint] $*"; }
fail() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# --- 0. runtime user ------------------------------------------------------------
# The official image runs as root. We run as the host uid/gid instead, so files
# written into the bind mounts (instance tmp files, sitedaemon.xml, ...) belong
# to the host user on Linux; on macOS the runtime maps ownership anyway.
#
# A passwd entry is added rather than renumbering `genro`: `usermod -u` chowns
# the whole home, copying the framework tree into every container layer. Only
# what the user must write to is handed over: the home directory itself and the
# pylibs volume.
# The container layer survives restarts, so every step is idempotent.
if [ "$(id -u)" = "0" ]; then
    uid="${HOST_UID:-0}"
    gid="${HOST_GID:-${uid}}"
    if [ "$uid" != "0" ]; then
        getent group "$gid" >/dev/null || groupadd -g "$gid" gnrdev
        getent passwd "$uid" >/dev/null \
            || useradd -M -o -u "$uid" -g "$gid" -d /home/genro -s /bin/bash gnrdev
        chown "$uid:$gid" /home/genro
        # The volume may hold files of another owner: seeded from the image's
        # .local on creation, or written under a previous HOST_UID. pip --user
        # needs all of it; only the mismatching entries are touched, so a
        # volume already in order costs one scan.
        find /home/genro/.local \( ! -user "$uid" -o ! -group "$gid" \) \
            -exec chown -h "$uid:$gid" {} +
        # Loading a package's startup data unpacks startup_data.gz into a .pik
        # next to it, i.e. inside the framework tree. Only those directories
        # of the image copy are handed over: a mounted checkout (local/git
        # mode) is never chowned, it already belongs to the right user.
        if ! mountpoint -q /home/genro/genropy; then
            find /home/genro/genropy/projects -name startup_data.gz 2>/dev/null \
                | while read -r f; do
                    d="$(dirname "$f")"
                    [ "$(stat -c %u "$d")" = "$uid" ] || chown "$uid:$gid" "$d"
                done
        fi
        # stdout/stderr are root-owned 0600 pipes: supervisord reopens them by
        # path (/dev/stdout) and would get EACCES once root is dropped.
        chown "$uid" "/proc/$$/fd/1" "/proc/$$/fd/2" 2>/dev/null || true
        log "running as $(getent passwd "$uid" | cut -d: -f1) (${uid}:${gid})"
        exec setpriv --reuid="$uid" --regid="$gid" --init-groups "$0" "$@"
    fi
    log "WARNING: HOST_UID is unset or 0, running as root"
fi

: "${GNR_PROJECT:?GNR_PROJECT is not set}"
: "${GNR_INSTANCE:?GNR_INSTANCE is not set}"

PROJECT_ROOT="/home/genro/genropy_projects/${GNR_PROJECT}"
INSTANCE_ROOT="${PROJECT_ROOT}/instances/${GNR_INSTANCE}"

# --- 1. clear sitedaemon state --------------------------------------------------
# sitedaemon.xml holds the PID that wrote it. After an unclean stop the file
# survives in the bind mount, but PIDs restart from 1 in the new container:
# pid_exists() can return a FALSE POSITIVE and the client then talks to a dead
# Pyro URI.
for sitedir in "${INSTANCE_ROOT}/site" "${PROJECT_ROOT}/sites/${GNR_INSTANCE}"; do
    if [ -f "${sitedir}/sitedaemon.xml" ]; then
        log "removing stale sitedaemon.xml in ${sitedir}"
        rm -f "${sitedir}/sitedaemon.xml"
    fi
done

# --- 2. Python dependencies of the instance -------------------------------------
# `gnr app checkdep` resolves the requirements of the packages ACTUALLY enabled
# in the instance (gnrapp.py:1037), wherever they live — including packages
# inside the image (gnrcore:email -> mail-parser), which scanning the mounted
# projects alone would miss. The hash stamp skips the work when nothing changed.
# The packages the image ships are part of it: a different image (after a pull,
# or a GENROPY_TAG change) can drop or add one, so it must re-check.
if [ "${GNR_SKIP_CHECKDEP:-0}" != "1" ]; then
    STAMP="/home/genro/.local/.req-stamp"
    # Asked to the interpreter the app runs on: the image may carry more than
    # one Python under /usr/local/lib, and a new tag may move to another one.
    PY_SITE="$(python3 -c 'import sysconfig; print(sysconfig.get_path("purelib"))' 2>/dev/null || true)"
    HASH="$( { find /home/genro/genropy_projects /home/genro/gnrextra_projects \
                    -maxdepth 4 -name requirements.txt -exec cat {} + 2>/dev/null || true; \
               python3 --version 2>&1 || true; \
               { [ -n "${PY_SITE}" ] && ls "${PY_SITE}" 2>/dev/null; } || true; \
               echo "${GNR_INSTANCE}"; } | sha256sum | cut -d' ' -f1)"
    if [ "${HASH}" != "$(cat "${STAMP}" 2>/dev/null || true)" ]; then
        log "checking the Python dependencies of the instance"
        if gnr app checkdep -i -n "${GNR_INSTANCE}" 2>&1 | sed 's/^/[checkdep] /'; then
            mkdir -p "$(dirname "${STAMP}")" && echo "${HASH}" > "${STAMP}"
        else
            warn_rc=$?
            log "WARNING: checkdep exited ${warn_rc}; the instance may not start"
        fi
    else
        log "dependencies unchanged, skipping"
    fi
fi

# --- 2b. framework from source (local or git mode) -----------------------------
# The checkout is mounted over /home/genro/genropy, so the static assets
# declared in environment.xml (dojo, gnrjs, resources) come from it with no
# path change. For the Python code, compose puts its gnrpy/ first on
# PYTHONPATH, ahead of the copy the image installs into site-packages.
#
# The editable install is still done, into the pylibs volume: it brings in the
# dependencies the checkout declares (profiles [developer,pgsql], as in the
# installation guide) and the metadata (version, entry points) matching it.
# Stamped on pyproject.toml, so a ref with different dependencies reinstalls.
FW_SRC=/home/genro/genropy/gnrpy
STAMP_FW="/home/genro/.local/.fw-editable"
if [ "${GNR_FRAMEWORK_EDITABLE:-0}" = "1" ]; then
    if [ ! -f "${FW_SRC}/pyproject.toml" ]; then
        fail "GNR_FRAMEWORK_EDITABLE=1 but ${FW_SRC}/pyproject.toml is missing (check the framework mount)"
    fi
    want="$(sha256sum "${FW_SRC}/pyproject.toml" | cut -d' ' -f1)"
    if [ "$(cat "${STAMP_FW}" 2>/dev/null || true)" != "$want" ]; then
        log "installing the framework editable from the mounted checkout"
        # Without PYTHONPATH: it would show pip the egg-info setuptools leaves in
        # gnrpy/ as one more installed genropy, and pip then tries to remove
        # the image's copy (Permission denied on /usr/local/bin/gnr).
        if env -u PYTHONPATH pip install --user --quiet -e "${FW_SRC}[developer,pgsql]"; then
            echo "$want" > "${STAMP_FW}"
        else
            fail "editable install of the framework failed"
        fi
    else
        log "framework dependencies unchanged"
    fi

    # Verify it actually took: the import must resolve into the mount.
    actual=$(python3 -c 'import gnr,os;print(os.path.realpath(os.path.dirname(gnr.__file__)))' 2>/dev/null || true)
    case "$actual" in
        "${FW_SRC}"/*) log "framework in use: ${actual}" ;;
        *) fail "framework loaded from ${actual:-unknown}, not from the mounted checkout" ;;
    esac
elif [ -f "${STAMP_FW}" ]; then
    # Back to the image framework: the editable install left in pylibs would
    # shadow the image's metadata (user site comes before site-packages).
    log "removing the editable framework left by a previous source mode"
    env -u PYTHONPATH pip uninstall --quiet -y genropy >/dev/null 2>&1 || true
    rm -f "${STAMP_FW}"
fi

# --- 3. fail fast on missing placeholders ---------------------------------------
# getGnrConfig() interpolates {GNR_*} from os.environ; a missing one fails
# obscurely later, so check up front.
missing=""
for var in $(grep -rhoE '\{GNR_[A-Z_]+\}' /home/genro/.gnr 2>/dev/null \
             | tr -d '{}' | sort -u); do
    if [ -z "$(eval "echo \${${var}:-}")" ]; then
        missing="${missing} ${var}"
    fi
done
[ -n "${missing}" ] && fail "config requires these undefined variables:${missing}"

# --- start ----------------------------------------------------------------------
if [ ! -d "${INSTANCE_ROOT}" ]; then
    fail "instance not found: ${INSTANCE_ROOT} (check GNR_PROJECT/GNR_INSTANCE and the bind mounts)"
fi

log "project=${GNR_PROJECT} instance=${GNR_INSTANCE}"
log "starting: $*"
exec "$@"
