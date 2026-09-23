#!/bin/bash
# Entrypoint of the "app" container.
#
#   1. clear sitedaemon.xml  -> stale PIDs after an unclean stop
#   2. wait for the database -> depends_on does not mean PG accepts connections
#   3. Python dependencies   -> incremental, hash-stamped
#   4. check {GNR_*} vars    -> fail fast instead of a broken config
set -euo pipefail

log() { echo "[entrypoint] $*"; }
fail() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

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

# --- 2. wait for the database ---------------------------------------------------
if [ "${GNR_DB_IMPLEMENTATION:-postgres}" = "postgres" ] && [ -n "${GNR_DB_HOST:-}" ]; then
    log "waiting for postgres on ${GNR_DB_HOST}:${GNR_DB_PORT:-5432}"
    for i in $(seq 1 60); do
        if pg_isready -h "${GNR_DB_HOST}" -p "${GNR_DB_PORT:-5432}" \
                      -U "${GNR_DB_USER:-genro}" -q 2>/dev/null; then
            log "postgres ready"
            break
        fi
        [ "$i" = "60" ] && fail "postgres unreachable after 60 attempts"
        sleep 1
    done
fi

# --- 3. Python dependencies of the instance -------------------------------------
# `gnr app checkdep` resolves the requirements of the packages ACTUALLY enabled
# in the instance (gnrapp.py:1037), wherever they live — including packages
# inside the image (gnrcore:email -> mail-parser), which scanning the mounted
# projects alone would miss. The hash stamp skips the work when nothing changed.
if [ "${GNR_SKIP_CHECKDEP:-0}" != "1" ]; then
    STAMP="/home/genro/.local/.req-stamp"
    HASH="$( { find /home/genro/genropy_projects /home/genro/gnrextra_projects \
                    -maxdepth 4 -name requirements.txt -exec cat {} + 2>/dev/null || true; \
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

# --- 3b. editable framework (only with --framework-src) -------------------------
# The image installs gnrpy non-editable, so without this Python would ignore the
# mounted checkout.
if [ "${GNR_FRAMEWORK_EDITABLE:-0}" = "1" ]; then
    if [ -f /home/genro/genropy/gnrpy/pyproject.toml ]; then
        STAMP_FW="/home/genro/.local/.fw-editable"
        if [ ! -f "${STAMP_FW}" ]; then
            log "installing the framework editable from the mounted checkout"
            pip install --user --quiet --no-deps -e /home/genro/genropy/gnrpy \
                && touch "${STAMP_FW}" \
                || log "WARNING: editable install failed, using the image framework"
        else
            log "framework already editable"
        fi
    else
        log "WARNING: GNR_FRAMEWORK_EDITABLE=1 but gnrpy/pyproject.toml is not in the mount"
    fi
fi

# --- 4. fail fast on missing placeholders ---------------------------------------
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
