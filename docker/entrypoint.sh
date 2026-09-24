#!/bin/bash
# Entrypoint of the "app" container, mounted from docker/ into the official
# image (nothing is built).
#
#   0. runtime user          -> host uid/gid, then drop root
#   1. clear sitedaemon.xml  -> stale PIDs after an unclean stop
#   2. Python dependencies   -> incremental, hash-stamped
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
# the two directories the user must write to are chowned, not recursively.
# The container layer survives restarts, so every step is idempotent.
if [ "$(id -u)" = "0" ]; then
    uid="${HOST_UID:-0}"
    gid="${HOST_GID:-${uid}}"
    if [ "$uid" != "0" ]; then
        getent group "$gid" >/dev/null || groupadd -g "$gid" gnrdev
        getent passwd "$uid" >/dev/null \
            || useradd -M -o -u "$uid" -g "$gid" -d /home/genro -s /bin/bash gnrdev
        chown "$uid:$gid" /home/genro /home/genro/.local
        # Loading a package's startup data unpacks startup_data.gz into a .pik
        # next to it, i.e. inside the framework tree. Only those directories
        # are handed over; ones already owned (a mounted checkout) are skipped.
        find /home/genro/genropy/projects -name startup_data.gz 2>/dev/null \
            | while read -r f; do
                d="$(dirname "$f")"
                [ "$(stat -c %u "$d")" = "$uid" ] || chown "$uid:$gid" "$d"
            done
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
    HASH="$( { find /home/genro/genropy_projects /home/genro/gnrextra_projects \
                    -maxdepth 4 -name requirements.txt -exec cat {} + 2>/dev/null || true; \
               ls /usr/local/lib/python3.11/site-packages; \
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

# --- 2b. editable framework (local or git mode) ---------------------------------
# The image ships gnr/ inside /usr/local/.../site-packages. That copy comes
# FIRST on sys.path, so an editable install alone is not enough: pip would
# report the checkout while `import gnr` still loads the image copy. The
# directory has to go.
#
# Profiles follow the installation guide: [developer,pgsql]. --no-deps is not
# used, so the extras resolve; the heavy native deps are already in the image
# and pip leaves them alone.
FW_SRC=/home/genro/framework/gnrpy
if [ "${GNR_FRAMEWORK_EDITABLE:-0}" = "1" ]; then
    if [ ! -f "${FW_SRC}/pyproject.toml" ]; then
        fail "GNR_FRAMEWORK_EDITABLE=1 but ${FW_SRC}/pyproject.toml is missing (check the framework mount)"
    fi
    # The image copy of gnr/ is removed at build time (see Dockerfile.dev):
    # site-packages is not writable by the genro user, so it cannot be done here.

    # Stamped on the checkout path: a different mount must reinstall.
    STAMP_FW="/home/genro/.local/.fw-editable"
    want="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$FW_SRC")"
    if [ "$(cat "${STAMP_FW}" 2>/dev/null || true)" != "$want" ]; then
        log "installing the framework editable from the mounted checkout"
        if pip install --user --quiet -e "${FW_SRC}[developer,pgsql]"; then
            mkdir -p "$(dirname "${STAMP_FW}")" && echo "$want" > "${STAMP_FW}"
        else
            fail "editable install of the framework failed"
        fi
    else
        log "framework already editable"
    fi

    # Verify it actually took: pip can report the checkout while the import
    # still resolves elsewhere.
    actual=$(python3 -c 'import gnr,os;print(os.path.realpath(os.path.dirname(gnr.__file__)))' 2>/dev/null || true)
    case "$actual" in
        /home/genro/framework/*) log "framework in use: ${actual}" ;;
        *) fail "framework still loaded from ${actual:-unknown}, not from the mounted checkout" ;;
    esac
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
