# locstreamer

A deliberately tiny iPhone app that records where you are all day and streams
it to a server that stores it in S3. No map, no graph: a list of lat/long.

- `ios/` — SwiftUI app (XcodeGen `project.yml`; run `xcodegen generate`).
  Phone-number + SMS code sign-in (same shape as Manas: the app never talks to
  the SMS provider, only to this API). Then Core Location runs continuously
  with the `location` background mode: ~100 m accuracy, 25 m distance filter,
  significant-change monitoring so iOS relaunches the app after it is killed,
  and a 5-minute heartbeat while standing still. Points are buffered on disk
  and uploaded every 60 s or every 25 points.
- `server/` — Vercel functions, deployed at https://locstreamer.vercel.app.
  Storage is one newline-delimited JSON object per uploaded batch in S3:
  `points/<phone digits>/<YYYY-MM-DD>/<first ts>-<rand>.jsonl`. No database.

## API

| Method | Path | Auth | Body / query |
| --- | --- | --- | --- |
| POST | `/api/otp/send` | none | `{ "phone": "+14155551234" }` → `{ method_id }` |
| POST | `/api/otp/verify` | none | `{ phone, method_id, code }` → `{ token, phone }` |
| POST | `/api/locations` | `Authorization: Bearer <token>` | `{ "points": [{ ts, lat, lon, acc?, spd? }] }` (`ts` = epoch ms) |
| GET | `/api/locations/<phone>` | `x-api-key: <READ_API_KEY>` or the phone's own Bearer token | `?from=YYYY-MM-DD&to=YYYY-MM-DD&format=csv` (UTC, default today) |

Example: everything recorded for a number today, as CSV:

```sh
curl -H "x-api-key: $READ_API_KEY" "https://locstreamer.vercel.app/api/locations/+14155551234?format=csv"
```

## Server env (Vercel project `locstreamer`)

`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (IAM user `locstreamer-api`,
scoped to the bucket), `AWS_REGION`, `S3_BUCKET`, `TOKEN_SECRET` (signs device
tokens), `READ_API_KEY` (read any phone), and the SMS provider: by default
`OTP_BRIDGE_URL` + `OTP_BRIDGE_ANON_KEY` point at the Manas `stytch-auth`
Supabase edge function, which sends the SMS through Stytch and whose session
is confirmed against Supabase's `/auth/v1/user` (so the Stytch secret stays in
Manas); set `STYTCH_PROJECT_ID` / `STYTCH_SECRET` instead to talk to Stytch
directly. Optional `DEV_PHONE` + `DEV_CODE` allow one number to sign in with a
fixed code and no SMS.

Deploy: pushes to `main` deploy automatically (Vercel Git integration, root
directory `server`); `cd server && vercel deploy --prod` also works.

## Ship to TestFlight

`scripts/ios-testflight.sh` fetches signing (`fastlane prep_signing`, App
Store Connect API key in `ios/fastlane/.asc.env`, gitignored), builds a signed
.ipa with `scripts/ios-build-ipa.sh` (swiftc + actool + codesign, no xcodebuild
build service, which hangs on this Mac) and uploads with `altool`. The App
Store Connect app record must exist first: `fastlane bootstrap` registers the
bundle id; the record itself needs an Apple ID web session once
(`fastlane spaceauth`, then `fastlane bootstrap_app`). The reusable version of
this pipeline is the `ios-testflight` skill in `~/.agent-skills`.
