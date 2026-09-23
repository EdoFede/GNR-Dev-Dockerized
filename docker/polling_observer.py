"""Force watchdog to use the PollingObserver.

Werkzeug picks its reloader with reloader_type="auto", hardcoded in
gnr/web/serverwsgi.py:411, which lands on InotifyObserver. inotify events do not
cross the host->container bind mount on macOS, so the reloader would watch
forever without seeing an edit; polling compares mtimes, which are correct.

Enabled by GNR_FORCE_POLLING=1 (set in the compose file).
"""
import os

if os.environ.get("GNR_FORCE_POLLING") == "1":
    try:
        import watchdog.observers
        from watchdog.observers.polling import PollingObserver

        timeout = float(os.environ.get("GNR_POLLING_INTERVAL", "1.0"))

        class _TunedPollingObserver(PollingObserver):
            def __init__(self, *args, **kwargs):
                kwargs.setdefault("timeout", timeout)
                super().__init__(*args, **kwargs)

        # Werkzeug does `from watchdog.observers import Observer` when it builds
        # the reloader, so replacing the attribute is enough.
        watchdog.observers.Observer = _TunedPollingObserver
    except Exception:  # pragma: no cover - must never block startup
        pass
