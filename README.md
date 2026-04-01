# Garmin Forerunner → Strava Auto-Sync

One-click installer that automatically syncs activities from your Garmin Forerunner watch to Strava every time you plug it in via USB. No Garmin Connect needed.

Tested with **Forerunner 35** on Ubuntu/Debian. Should work with any Garmin watch that mounts as USB mass storage.

## How it works

```
Plug in watch → udev detects USB → systemd runs sync → activities uploaded → desktop notification
```

- Reads `.FIT` activity files directly from the watch
- Detects sport type (cycling, running, walking, gym/cardio)
- Uploads to Strava via API with correct activity type
- Renames gym/cardio activities to "Weights"
- Checks Strava for duplicates before uploading — safe to install on multiple machines
- Shows a desktop notification on every sync

## Prerequisites

### 1. Create a Strava API Application

1. Go to [https://www.strava.com/settings/api](https://www.strava.com/settings/api)
2. Create a new application:
   - **Application Name:** anything (e.g. "Garmin Sync")
   - **Website:** anything (e.g. your website or `http://localhost`)
   - **Authorization Callback Domain:** `localhost`
3. Note your **Client ID** and **Client Secret**

### 2. Requirements

- Linux (Ubuntu/Debian tested)
- Python 3
- Garmin watch that mounts as USB mass storage

## Install

```bash
git clone https://github.com/yourusername/garmin-strava-sync.git
cd garmin-strava-sync
chmod +x install.sh
./install.sh
```

Or with environment variables (to skip the prompt):

```bash
STRAVA_CLIENT_ID=12345 STRAVA_CLIENT_SECRET=abc123 ./install.sh
```

The installer will:

1. Create a Python venv and install dependencies
2. Install `garmin-client` to `~/.local/bin/`
3. Mark existing watch activities as already uploaded
4. Set up a systemd service + udev rule for auto-sync on USB plug-in
5. Open your browser to authorize with Strava

That's it. Plug in your watch and it just works.

## Activity mapping

| Watch sport | Strava type | Name |
|---|---|---|
| Cycling | Ride | *(Strava default)* |
| Running | Run | *(Strava default)* |
| Walking | Walk | *(Strava default)* |
| Cardio / Training | Weight Training | Weights |

You can customize the mapping by editing the `SPORT_MAP` dictionary in `~/.local/bin/garmin-client`.

## Manual commands

```bash
garmin-client sync      # Sync now (watch must be plugged in)
garmin-client status    # Show sync status and watch info
garmin-client setup     # Re-authorize with Strava
```

## What gets installed

| File | Purpose |
|---|---|
| `~/.local/bin/garmin-client` | Main sync script |
| `~/.config/garmin-strava-sync/venv/` | Python venv with fitparse |
| `~/.config/garmin-strava-sync/config.json` | Strava tokens (local only) |
| `~/.config/garmin-strava-sync/uploaded.txt` | Local upload history |
| `~/.config/garmin-strava-sync/sync.log` | Sync log |
| `~/.config/systemd/user/garmin-strava-sync.service` | Systemd service |
| `/etc/udev/rules.d/99-garmin-strava.rules` | USB auto-detect rule |

## How duplicate detection works

Each uploaded file is tracked locally in `uploaded.txt`. On a fresh install (new machine), the installer marks all existing watch activities as uploaded. As a safety net, the sync also checks the Strava API for activities with matching timestamps before uploading — so you'll never get duplicates even if `uploaded.txt` is empty.

## Tested watches

- Forerunner 35

Should work with any Garmin watch that mounts as USB mass storage (Forerunner 235, 245, 645, vivoactive, etc.). If you test it with another model, please open an issue or PR.

## License

MIT
