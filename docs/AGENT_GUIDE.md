# LocStreamer — location data API (for an AI agent)

LocStreamer records a phone's location continuously and stores it as a private,
per-phone history. This document is everything an automated agent needs to read
that history and act on it. No SDK required — plain HTTPS + JSON.

## Base

```
https://locstreamer.vercel.app
```

## Authentication for reading

Reads are authorized one of two ways:

1. **Read API key** (recommended for an agent): send header
   `x-api-key: <READ_API_KEY>`. This can read ANY phone's history. Treat the
   key as a secret; do not commit it or send it to third parties.
2. **The phone's own bearer token**: send `Authorization: Bearer <token>`,
   obtained by signing that phone in (see "Sign-in", rarely needed for an agent).

Set the key as an environment variable, e.g. `LOCSTREAMER_READ_KEY`, and the
target phone as `LOCSTREAMER_PHONE` (E.164, e.g. `+14155551234`).

## Read a location history — the endpoint an agent uses

```
GET /api/locations/<phone>?from=YYYY-MM-DD&to=YYYY-MM-DD[&format=csv]
```

- `<phone>` — E.164, URL-encoded (the leading `+` may be sent literally).
- `from`, `to` — **UTC** calendar dates, inclusive. Both default to **today**.
  `from` must be ≤ `to`; the range may span at most **93 days** per request.
- `format=csv` — returns CSV instead of JSON. Omit for JSON.

### JSON response

```json
{
  "phone": "+14155551234",
  "from": "2026-09-11",
  "to":   "2026-09-11",
  "count": 128,
  "points": [
    { "ts": 1789088982000, "lat": 37.7749, "lon": -122.4194, "acc": 12.5, "spd": 1.4 }
  ]
}
```

### A point

| field | meaning | notes |
| --- | --- | --- |
| `ts`  | timestamp | Unix epoch **milliseconds**, UTC |
| `lat` | latitude  | degrees, −90…90 |
| `lon` | longitude | degrees, −180…180 |
| `acc` | horizontal accuracy, metres | optional (present when the device reported it) |
| `spd` | speed, metres/second | optional |

Points come back **oldest-first** and are **de-duplicated by timestamp**.

### CSV response

Header row then one point per line:

```
ts,iso,lat,lon,acc,spd
1789088982000,2026-09-11T00:29:42.000Z,37.7749,-122.4194,12.5,1.4
```

## Examples

```sh
# Everything recorded today (JSON)
curl -H "x-api-key: $LOCSTREAMER_READ_KEY" \
  "https://locstreamer.vercel.app/api/locations/$LOCSTREAMER_PHONE"

# A date range as CSV (good for feeding a spreadsheet or a model)
curl -H "x-api-key: $LOCSTREAMER_READ_KEY" \
  "https://locstreamer.vercel.app/api/locations/$LOCSTREAMER_PHONE?from=2026-09-01&to=2026-09-11&format=csv"
```

```python
import os, requests
BASE = "https://locstreamer.vercel.app"
key  = os.environ["LOCSTREAMER_READ_KEY"]
phone = os.environ["LOCSTREAMER_PHONE"]

def history(from_=None, to=None):
    params = {}
    if from_: params["from"] = from_
    if to:    params["to"]   = to
    r = requests.get(f"{BASE}/api/locations/{phone}",
                     headers={"x-api-key": key}, params=params, timeout=30)
    r.raise_for_status()
    return r.json()["points"]   # [{ts, lat, lon, acc?, spd?}, ...] oldest-first

# e.g. where was I today?
for p in history():
    print(p["ts"], p["lat"], p["lon"])
```

## Things an agent can build on this

- **Daily summary / timeline** — pull today's points, cluster stops, name places.
- **Geofence / arrival alerts** — poll the latest point, compare to a target
  coordinate (haversine), notify on enter/exit.
- **Commute & time-at-place stats** — pull a date range, group by dwell.
- **Export** — CSV for a notebook, a sheet, or a training set.

## Constraints & notes

- Dates are **UTC**. A point's local day may differ from its UTC day near midnight.
- Data granularity: the app records at ~100 m / 25 m-distance-filter accuracy and
  a heartbeat while stationary, so expect roughly a point every minute or two when
  moving, sparser when still. Gaps happen when the phone has no signal or the app
  was force-quit (iOS relaunches it on significant movement).
- Reads are the caller's own view of stored data. Writing (uploading points) is
  done by the iOS app with a device token; an agent normally only reads.
- The write side and full API: see the repository `README.md`.

## Direct S3 access (optional, advanced)

The raw objects live in a private S3 bucket, one newline-delimited-JSON file per
uploaded batch:

```
s3://<S3_BUCKET>/points/<phone digits>/<YYYY-MM-DD>/<first ts ms>-<random>.jsonl
```

Each line is one point object (same schema as above). Reading via the HTTPS API
above is simpler and is the recommended path; use S3 directly only for bulk
export with AWS credentials that can read the bucket.
