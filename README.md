# Pocket — Privacy-first budget app

Reads your PayPal and Google Pay notifications, extracts the transaction,
and gives you a clean monthly dashboard. No bank linking, no Plaid, no
cloud sync of your financial data — your transactions stay on the phone,
and the optional backup blob lives in your own Cloudflare R2 bucket.

## Repo layout

One GitHub repo, three runtime environments:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Mac (your dev box)                                                   │
│  ─────────────────                                                    │
│  • Full repo checkout (server/ + lib/ + android/ + everything)       │
│  • Builds the mobile APK:  flutter build apk --release               │
│  • Pushes server to VM:    ./server/tool/deploy.sh                  │
│  • Builds go OUT from here to phone and VM                           │
└──────────────────────────────────────────────────────────────────────┘
            │                                              │
            │ adb install -r app-release.apk               │ rsync + systemctl restart
            ▼                                              ▼
┌──────────────────────────┐                ┌──────────────────────────────────┐
│  Phone (Android)         │                │  VM (Oracle Linux)               │
│  ──────────────          │                │  ────────────────                │
│  • Runs the Flutter app  │  ◄─HTTPS──►   │  • Runs ONLY the Dart server    │
│  • APK contains:         │   pocket.      │  • /opt/pocket/server/ is a     │
│    - Flutter code        │   karmacode    │    partial copy (server/ only)  │
│    - google-services.json│   .online      │  • Does NOT have lib/ or        │
│      baked in at build   │                │    android/ — doesn't need them │
│    - SERVER_URL baked in │                │  • /opt/pocket/server/.gcp/     │
│  • No source access to   │                │    holds the FCM service account│
│    the repo              │                │    JSON (server-side credential)│
└──────────────────────────┘                └──────────────────────────────────┘
```

The mobile app code never lives on the VM — it only exists as a compiled
APK on the phone. The server code never runs on the phone — it only
exists as compiled Dart on the VM. Git is the single source of truth
for both.

## Where each credential lives

| Credential | Mac | Git | VM | Phone |
|---|---|---|---|---|
| `android/app/google-services.json` (Firebase Android SDK) | ✓ untracked | ✗ (gitignored) | ✗ | ✓ baked into APK |
| `server/.env` (JWT secrets, OAuth, FCM path) | ✓ untracked | ✗ (gitignored) | ✓ preserved by deploy.sh | ✗ |
| `server/.gcp/pocket-server-key.json` (FCM service account, server-side) | ✗ | ✗ | ✓ only | ✗ |
| `secrets/fcm-service-account.json` (local copy on Mac for reference) | ✓ | ✗ | ✗ | ✗ |

The Firebase **API key** (`AIzaSy...`) in `google-services.json` is consumed by the
Android Firebase SDK at runtime. The VM uses a different FCM credential
(the server-side service-account JSON) — different credential system,
unaffected by API-key rotation.

## Where the data lives

- **Transactions + budgets + alerts**: on the phone (SQLite, source of truth)
- **Backup blob**: encrypted ZIP in your R2 bucket (`pocket-backups/<sub>/<timestamp>.zip`)
- **Per-user config** (backup prefs, budget prefs, filter rules, timezone):
  server Postgres (`accounts` table) — the phone hydrates this on sign-in
- **FCM push payloads** (live notifications): Pub/Sub push relay →
  Postgres envelope store → FCM publish to the device's FCM token

## Building

```bash
# Server
cd server && dart pub get && dart test

# Mobile — APK
flutter build apk --release \
  --dart-define=SERVER_URL=https://pocket.karmacode.online
# APK lands at build/app/outputs/flutter-apk/app-release.apk
```

## Deploying

```bash
./server/tool/deploy.sh   # rsync server/ → VM, restart pocket-server.service
```

`deploy.sh` is idempotent and preserves the VM's `.env` secrets across
runs. See `server/OPERATIONS.md` for the full ops runbook (crons, sign-out
lifecycle, hard-delete paths).

## Installing on the device

```bash
# Safe upgrade — preserves app data
adb install -r build/app/outputs/flutter-apk/app-release.apk

# Clean install — wipes local SQLite (transactions, budgets, on-device
# account row). Recoverable by signing in and pulling from R2 backup.
adb uninstall com.limitless.pocket
adb install    build/app/outputs/flutter-apk/app-release.apk
```

**Never use `flutter install`** — it uninstalls first and silently wipes
SQLite. Always use `adb install -r` from
`/opt/homebrew/share/android-commandlinetools/platform-tools/adb`.

## Why both halves live in one repo

The mobile app and the server share types and contracts end-to-end —
`Budget`, `AccountRecord`, `Envelope`, the `(name, startDate)` match key,
the apiToken shape, etc. Keeping them in one repo with one source of
truth means a contract change is one commit, not a coordinated
release across two repos.
