#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Garmin Forerunner → Strava Auto-Sync
# One-click installer: downloads, installs, sets up, authorizes.
# ============================================================

INSTALL_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/garmin-strava-sync"
SYSTEMD_DIR="$HOME/.config/systemd/user"
UDEV_RULE="/etc/udev/rules.d/99-garmin-strava.rules"
CLIENT="$INSTALL_DIR/garmin-client"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║  Garmin Forerunner → Strava Client   ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# --- Step 1: Create venv with fitparse and write garmin-client ---
echo "[1/5] Installing garmin-client..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

VENV_DIR="$CONFIG_DIR/venv"
echo "  Creating Python environment..."
if ! python3 -m venv "$VENV_DIR" 2>/dev/null; then
    echo "  python3-venv not installed. Installing..."
    PY_MINOR=$(python3 -c 'import sys;print(sys.version_info.minor)')
    if command -v pkexec &>/dev/null; then
        pkexec apt install -y "python3.${PY_MINOR}-venv" 2>/dev/null || pkexec apt install -y python3-venv 2>/dev/null
    elif command -v sudo &>/dev/null; then
        sudo apt install -y "python3.${PY_MINOR}-venv" 2>/dev/null || sudo apt install -y python3-venv 2>/dev/null
    fi
    python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install -q fitparse
echo "  Python environment ready"

# Write the script with venv shebang, then the rest as literal
echo "#!${VENV_DIR}/bin/python3" > "$CLIENT"
cat >> "$CLIENT" << 'CLIENTEOF'
"""Garmin Forerunner client — auto-sync activities to Strava."""

import argparse
import fcntl
import http.server
import json
import os
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import webbrowser
from datetime import datetime
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "garmin-strava-sync"
CONFIG_FILE = CONFIG_DIR / "config.json"
UPLOADED_FILE = CONFIG_DIR / "uploaded.txt"
LOG_FILE = CONFIG_DIR / "sync.log"

STRAVA_AUTH_URL = "https://www.strava.com/oauth/authorize"
STRAVA_TOKEN_URL = "https://www.strava.com/oauth/token"
STRAVA_UPLOAD_URL = "https://www.strava.com/api/v3/uploads"
REDIRECT_PORT = 5839
REDIRECT_URI = f"http://localhost:{REDIRECT_PORT}/callback"

DEFAULT_CLIENT_ID = os.environ.get("STRAVA_CLIENT_ID", "")
DEFAULT_CLIENT_SECRET = os.environ.get("STRAVA_CLIENT_SECRET", "")

# FIT sport enum -> (strava type, custom name or None for Strava default)
SPORT_MAP = {
    "cycling": ("ride", None),
    "running": ("run", None),
    "walking": ("walk", None),
    "training": ("weight_training", "Weights"),
    "cardio_training": ("weight_training", "Weights"),
}

GARMIN_MOUNT_PATHS = [
    Path("/media") / os.environ.get("USER", "user") / "GARMIN",
    Path("/run/media") / os.environ.get("USER", "user") / "GARMIN",
    Path("/mnt/GARMIN"),
]


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def load_config():
    if CONFIG_FILE.exists():
        return json.loads(CONFIG_FILE.read_text())
    return {}


def save_config(cfg):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))


def load_uploaded():
    if UPLOADED_FILE.exists():
        return set(UPLOADED_FILE.read_text().strip().splitlines())
    return set()


def mark_uploaded(filename):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(UPLOADED_FILE, "a") as f:
        f.write(filename + "\n")


def notify(title, body):
    try:
        subprocess.run(
            ["notify-send", "-i", "emblem-synchronizing", title, body],
            timeout=5,
            capture_output=True,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass


# --- Strava OAuth ---


def oauth_setup(cfg):
    client_id = cfg.get("client_id") or DEFAULT_CLIENT_ID
    client_secret = cfg.get("client_secret") or DEFAULT_CLIENT_SECRET

    if not client_id:
        print("Enter your Strava API credentials (see README for setup):")
        client_id = input("  Client ID: ").strip()
    if not client_secret:
        client_secret = input("  Client Secret: ").strip()

    if not client_id or not client_secret:
        print("Error: Strava API credentials required.")
        print("Create an app at https://www.strava.com/settings/api")
        sys.exit(1)

    cfg["client_id"] = client_id
    cfg["client_secret"] = client_secret
    save_config(cfg)

    params = urllib.parse.urlencode({
        "client_id": client_id,
        "redirect_uri": REDIRECT_URI,
        "response_type": "code",
        "scope": "activity:write,activity:read",
    })
    auth_url = f"{STRAVA_AUTH_URL}?{params}"

    print("\nOpening browser for Strava authorization...")
    print(f"If it doesn't open, go to:\n{auth_url}\n")
    webbrowser.open(auth_url)

    auth_code = None

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            nonlocal auth_code
            query = urllib.parse.urlparse(self.path).query
            params = urllib.parse.parse_qs(query)
            auth_code = params.get("code", [None])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(
                b"<html><body style='font-family:system-ui;text-align:center;padding:60px'>"
                b"<h2>Authorized! You can close this tab.</h2>"
                b"<p>Your Garmin watch will now auto-sync to Strava.</p>"
                b"</body></html>"
            )

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("localhost", REDIRECT_PORT), Handler)
    server.timeout = 120
    print("Waiting for authorization...")
    server.handle_request()

    if not auth_code:
        print("Authorization failed — no code received.")
        sys.exit(1)

    data = urllib.parse.urlencode({
        "client_id": client_id,
        "client_secret": client_secret,
        "code": auth_code,
        "grant_type": "authorization_code",
    }).encode()

    req = urllib.request.Request(STRAVA_TOKEN_URL, data=data, method="POST")
    with urllib.request.urlopen(req) as resp:
        tokens = json.loads(resp.read())

    cfg["access_token"] = tokens["access_token"]
    cfg["refresh_token"] = tokens["refresh_token"]
    cfg["expires_at"] = tokens["expires_at"]
    cfg["setup_done"] = True
    save_config(cfg)
    print("Authorization successful!")
    notify("Garmin Strava Sync", "Connected to Strava! Plug in your watch to auto-sync activities.")
    return cfg


def ensure_token(cfg):
    if not cfg.get("refresh_token"):
        cfg = oauth_setup(cfg)
        return cfg

    if time.time() >= cfg.get("expires_at", 0) - 60:
        log("Refreshing Strava access token...")
        data = urllib.parse.urlencode({
            "client_id": cfg["client_id"],
            "client_secret": cfg["client_secret"],
            "grant_type": "refresh_token",
            "refresh_token": cfg["refresh_token"],
        }).encode()

        req = urllib.request.Request(STRAVA_TOKEN_URL, data=data, method="POST")
        with urllib.request.urlopen(req) as resp:
            tokens = json.loads(resp.read())

        cfg["access_token"] = tokens["access_token"]
        cfg["refresh_token"] = tokens["refresh_token"]
        cfg["expires_at"] = tokens["expires_at"]
        save_config(cfg)

    return cfg


# --- FIT parsing ---


def parse_fit_sport(filepath):
    SPORT_NAMES = {
        0: "generic", 1: "running", 2: "cycling", 3: "transition",
        4: "fitness_equipment", 5: "swimming", 10: "training",
        11: "walking", 12: "cross_country_skiing", 13: "alpine_skiing",
        14: "snowboarding", 15: "rowing", 16: "mountaineering",
        17: "hiking", 18: "multisport", 19: "paddling",
    }
    try:
        try:
            import fitparse
            fitfile = fitparse.FitFile(str(filepath))
            for msg in fitfile.get_messages("session"):
                fields = {f.name: f.value for f in msg.fields}
                sport = fields.get("sport")
                sub_sport = fields.get("sub_sport")
                if sport:
                    return str(sport), str(sub_sport) if sub_sport else None
        except ImportError:
            pass

        with open(filepath, "rb") as f:
            data = f.read()
        for i in range(len(data) - 20):
            if data[i : i + 4] == b"\x00\x12\x00\x00":
                for j in range(i, min(i + 200, len(data))):
                    if data[j] in SPORT_NAMES and data[j] != 0:
                        return SPORT_NAMES[data[j]], None
        return None, None
    except Exception:
        return None, None


def parse_fit_start_time(filepath):
    try:
        import fitparse
        fitfile = fitparse.FitFile(str(filepath))
        for msg in fitfile.get_messages("session"):
            fields = {f.name: f.value for f in msg.fields}
            ts = fields.get("start_time")
            if ts:
                return ts
    except (ImportError, Exception):
        pass
    return None


# --- Strava duplicate check ---


def activity_exists_on_strava(cfg, start_time):
    """Check if an activity with this start time already exists on Strava."""
    if not start_time:
        return False
    try:
        import calendar
        ts = int(calendar.timegm(start_time.timetuple()))  # treat naive datetime as UTC
        params = urllib.parse.urlencode({"after": ts - 300, "before": ts + 300, "per_page": 5})
        req = urllib.request.Request(
            f"https://www.strava.com/api/v3/athlete/activities?{params}",
            headers={"Authorization": f"Bearer {cfg['access_token']}"},
        )
        with urllib.request.urlopen(req) as resp:
            activities = json.loads(resp.read())
        return len(activities) > 0
    except Exception:
        return False


# --- Strava upload ---


def upload_to_strava(cfg, filepath, sport, sub_sport):
    strava_type, name = SPORT_MAP.get(sport, (None, None))
    if sub_sport and not strava_type:
        strava_type, name = SPORT_MAP.get(sub_sport, (None, None))
    if not strava_type:
        strava_type = "workout"

    filename = os.path.basename(filepath)
    boundary = "----GarminStravaSync" + str(int(time.time()))
    body = b""

    body += f"--{boundary}\r\n".encode()
    body += b'Content-Disposition: form-data; name="data_type"\r\n\r\n'
    body += b"fit\r\n"

    body += f"--{boundary}\r\n".encode()
    body += b'Content-Disposition: form-data; name="activity_type"\r\n\r\n'
    body += f"{strava_type}\r\n".encode()

    if name:
        body += f"--{boundary}\r\n".encode()
        body += b'Content-Disposition: form-data; name="name"\r\n\r\n'
        body += f"{name}\r\n".encode()

    with open(filepath, "rb") as f:
        file_data = f.read()

    body += f"--{boundary}\r\n".encode()
    body += f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode()
    body += b"Content-Type: application/octet-stream\r\n\r\n"
    body += file_data
    body += b"\r\n"
    body += f"--{boundary}--\r\n".encode()

    req = urllib.request.Request(
        STRAVA_UPLOAD_URL,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {cfg['access_token']}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )

    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read())
            upload_id = result.get("id_str", result.get("id", "?"))
            error = result.get("error")
            if error:
                return False, f"Upload error: {error}"

            # If activity needs renaming, poll for activity ID and update
            if name:
                activity_id = result.get("activity_id")
                if not activity_id:
                    for _ in range(10):
                        time.sleep(2)
                        try:
                            poll_req = urllib.request.Request(
                                f"https://www.strava.com/api/v3/uploads/{upload_id}",
                                headers={"Authorization": f"Bearer {cfg['access_token']}"},
                            )
                            with urllib.request.urlopen(poll_req) as poll_resp:
                                poll = json.loads(poll_resp.read())
                            activity_id = poll.get("activity_id")
                            if activity_id:
                                break
                        except Exception:
                            pass

                if activity_id:
                    update_data = urllib.parse.urlencode({"name": name}).encode()
                    update_req = urllib.request.Request(
                        f"https://www.strava.com/api/v3/activities/{activity_id}",
                        data=update_data,
                        method="PUT",
                        headers={"Authorization": f"Bearer {cfg['access_token']}"},
                    )
                    try:
                        with urllib.request.urlopen(update_req) as _:
                            pass
                    except Exception:
                        pass

            return True, f"Uploaded {filename} as {strava_type}, upload_id={upload_id}"
    except urllib.error.HTTPError as e:
        error_body = e.read().decode(errors="replace")
        return False, f"HTTP {e.code}: {error_body}"


# --- Watch detection ---


def find_garmin_mount():
    for p in GARMIN_MOUNT_PATHS:
        activity_dir = p / "GARMIN" / "ACTIVITY"
        try:
            if activity_dir.is_dir():
                list(activity_dir.iterdir())  # verify we can actually read it
                return p
        except (PermissionError, OSError):
            continue
    return None


def wait_for_garmin(timeout=30):
    for _ in range(timeout * 2):
        mount = find_garmin_mount()
        if mount:
            return mount
        time.sleep(0.5)
    return None


# --- Commands ---


def cmd_sync(args):
    lock_file = CONFIG_DIR / "sync.lock"
    # Skip if another sync ran in the last 30 seconds
    try:
        if lock_file.exists() and time.time() - lock_file.stat().st_mtime < 30:
            sys.exit(0)
    except OSError:
        pass
    lock_fd = open(lock_file, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(0)  # another sync is already running
    lock_file.touch()

    cfg = load_config()
    if not cfg.get("client_id"):
        print("Not configured yet. Run: garmin-client setup")
        sys.exit(1)

    mount = find_garmin_mount()
    if not mount:
        log("Garmin watch not found. Waiting up to 30 seconds...")
        mount = wait_for_garmin(30)

    if not mount:
        log("Garmin watch not connected or not mounted.")
        notify("Garmin Sync", "Watch not found")
        sys.exit(1)

    log(f"Found watch at {mount}")

    # First connection notification
    if not cfg.get("first_sync_done"):
        notify("Garmin Watch Detected", "Watch connected! Syncing activities to Strava...")
        cfg["first_sync_done"] = True
        save_config(cfg)

    cfg = ensure_token(cfg)

    activity_dir = mount / "GARMIN" / "ACTIVITY"
    uploaded = load_uploaded()

    fit_files = sorted(activity_dir.glob("*.FIT"))
    new_files = [f for f in fit_files if f.name not in uploaded]

    if not new_files:
        log("No new activities to upload.")
        notify("Garmin Sync", "No new activities")
        return

    log(f"Found {len(new_files)} new activity file(s)")

    results = []
    for fit_file in new_files:
        sport, sub_sport = parse_fit_sport(fit_file)
        start_time = parse_fit_start_time(fit_file)
        time_str = start_time.strftime("%d %b %H:%M") if start_time else "?"

        # Check Strava for duplicate before uploading
        if activity_exists_on_strava(cfg, start_time):
            log(f"Skipping {fit_file.name} ({time_str}): already on Strava")
            mark_uploaded(fit_file.name)
            continue

        log(f"Uploading {fit_file.name}: sport={sport} sub_sport={sub_sport} time={time_str}")

        success, msg = upload_to_strava(cfg, fit_file, sport, sub_sport)
        log(f"  {msg}")

        if success:
            mark_uploaded(fit_file.name)
            strava_type, _name = SPORT_MAP.get(sport, ("workout", None))
            results.append(strava_type)
        else:
            results.append(f"FAILED: {fit_file.name}")

    if not results:
        log("No new activities to upload (all already on Strava).")
        notify("Garmin Sync", "No new activities")
        return

    summary = f"Synced {len(results)} activities: {', '.join(results)}"
    log(summary)
    notify("Garmin Sync Complete", summary)


def cmd_setup(args):
    cfg = load_config()
    cfg = oauth_setup(cfg)
    print("\nSetup complete! Plug in your watch and activities will auto-sync.")
    print("Or run: garmin-client sync")


def cmd_status(args):
    cfg = load_config()
    uploaded = load_uploaded()

    print("Garmin Strava Sync")
    print("=" * 40)

    if cfg.get("client_id"):
        print(f"Strava app:    configured (client_id: {cfg['client_id'][:8]}...)")
    else:
        print("Strava app:    NOT configured — run: garmin-client setup")

    if cfg.get("refresh_token"):
        expires = datetime.fromtimestamp(cfg.get("expires_at", 0))
        print(f"Auth token:    valid (expires {expires})")
    else:
        print("Auth token:    NOT authorized — run: garmin-client setup")

    print(f"Uploaded:      {len(uploaded)} activities")

    mount = find_garmin_mount()
    if mount:
        activity_dir = mount / "GARMIN" / "ACTIVITY"
        fit_files = list(activity_dir.glob("*.FIT"))
        new = [f for f in fit_files if f.name not in uploaded]
        print(f"Watch:         connected at {mount}")
        print(f"Activities:    {len(fit_files)} on watch, {len(new)} not yet uploaded")
    else:
        print("Watch:         not connected")

    if LOG_FILE.exists():
        lines = LOG_FILE.read_text().strip().splitlines()
        if lines:
            print(f"\nLast log entry:")
            print(f"  {lines[-1]}")


def main():
    parser = argparse.ArgumentParser(
        prog="garmin-client",
        description="Garmin Forerunner → Strava sync client",
    )
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("setup", help="Configure Strava API credentials and authorize")
    sub.add_parser("sync", help="Sync new activities to Strava")
    sub.add_parser("status", help="Show sync status and watch info")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(0)

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    if args.command == "setup":
        cmd_setup(args)
    elif args.command == "sync":
        cmd_sync(args)
    elif args.command == "status":
        cmd_status(args)


if __name__ == "__main__":
    main()
CLIENTEOF

chmod +x "$CLIENT"
echo "  Installed to $CLIENT"

# --- Step 2: Mark existing activities as uploaded ---
echo "[2/5] Checking for existing activities..."
MARKED=0
for mount_path in "/media/$USER/GARMIN" "/run/media/$USER/GARMIN" "/mnt/GARMIN"; do
    if [ -d "$mount_path/GARMIN/ACTIVITY" ]; then
        for f in "$mount_path/GARMIN/ACTIVITY/"*.FIT; do
            [ -f "$f" ] || continue
            fname=$(basename "$f")
            if ! grep -qxF "$fname" "$CONFIG_DIR/uploaded.txt" 2>/dev/null; then
                echo "$fname" >> "$CONFIG_DIR/uploaded.txt"
                MARKED=$((MARKED + 1))
            fi
        done
        echo "  Marked $MARKED existing activities as already uploaded"
        break
    fi
done
if [ "$MARKED" -eq 0 ]; then
    echo "  No watch connected — all new activities will sync on first plug-in"
fi

# --- Step 3: Install systemd user service ---
echo "[3/5] Installing systemd sync service..."
mkdir -p "$SYSTEMD_DIR"
cat > "$SYSTEMD_DIR/garmin-strava-sync.service" << SVCEOF
[Unit]
Description=Garmin Forerunner Strava Sync

[Service]
Type=oneshot
ExecStart=$CLIENT sync
Environment=DISPLAY=:0
Environment=WAYLAND_DISPLAY=wayland-0
SVCEOF
systemctl --user daemon-reload
echo "  Systemd service installed"

# --- Step 4: Install udev rule ---
echo "[4/5] Installing auto-sync trigger (requires authentication)..."

RULE='ACTION=="add", SUBSYSTEM=="block", ENV{ID_VENDOR_ID}=="091e", TAG+="systemd", ENV{SYSTEMD_USER_WANTS}="garmin-strava-sync.service"'

if command -v pkexec &>/dev/null; then
    echo "$RULE" | pkexec tee "$UDEV_RULE" > /dev/null 2>&1 && \
    pkexec udevadm control --reload-rules 2>/dev/null && \
    echo "  udev rule installed" || \
    echo "  WARNING: Could not install udev rule. Run 'garmin-client sync' manually."
elif command -v sudo &>/dev/null; then
    echo "$RULE" | sudo tee "$UDEV_RULE" > /dev/null 2>&1 && \
    sudo udevadm control --reload-rules 2>/dev/null && \
    echo "  udev rule installed" || \
    echo "  WARNING: Could not install udev rule. Run 'garmin-client sync' manually."
else
    echo "  WARNING: No sudo/pkexec. Run 'garmin-client sync' manually after plugging in."
fi

# --- Step 5: Authorize with Strava ---
echo "[5/5] Strava authorization..."

if [ -f "$CONFIG_DIR/config.json" ] && python3 -c "
import json, time
cfg = json.load(open('$CONFIG_DIR/config.json'))
assert cfg.get('refresh_token')
" 2>/dev/null; then
    echo "  Already authorized — skipping"
else
    echo ""
    echo "  Opening browser for Strava authorization..."
    echo "  Click 'Authorize' and you're done."
    echo ""
    "$CLIENT" setup
fi

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║            All done!                 ║"
echo "  ║                                      ║"
echo "  ║  Plug in your watch → auto-syncs     ║"
echo "  ║  to Strava with a notification.      ║"
echo "  ║                                      ║"
echo "  ║  Manual: garmin-client sync          ║"
echo "  ║  Status: garmin-client status        ║"
echo "  ╚══════════════════════════════════════╝"
echo ""
