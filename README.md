# cellosig for iPhone

Native SwiftUI client for the cellosig relay. It speaks the same protocol as
the Android app byte for byte (X3DH + Double Ratchet, sealed sender, CSv2
attachments, padded JSON payloads), so iPhones and Androids message each other
through the same relay.

- `Core/` — Swift package `CellosigCore`: the protocol, built on CryptoKit
  (X25519, Ed25519, HKDF-SHA256, HMAC-SHA256, AES-256-GCM). No UI, no storage.
- `App/` — the iOS app: Keychain-backed vault for keys and sessions, SQLite
  message store, relay WebSocket client, SwiftUI screens.
- `Interop/interop.mjs` — Node implementation (the relay test bot's code) used
  by CI to check Swift ↔ Node compatibility in both directions.
- `project.yml` — XcodeGen spec; CI generates the Xcode project.

Not audited. Same caveat as the Android client.

## Builds (GitHub Actions, macOS)

Every push runs:
1. **core** — Node encrypts test messages, `swift test` decrypts them and
   produces its own, Node decrypts those.
2. **app** — unsigned simulator build (catches compile errors).

**TestFlight**: Actions → ios → Run workflow → tick *Sign and upload to
TestFlight*. Needs these repository secrets:

| Secret | Where it comes from |
|---|---|
| `APPLE_TEAM_ID` | developer.apple.com → Membership → Team ID |
| `ASC_KEY_ID` | App Store Connect → Users and Access → Integrations → App Store Connect API → new key (role **Admin**, needed for automatic signing) |
| `ASC_ISSUER_ID` | same page, "Issuer ID" |
| `ASC_KEY_P8` | the downloaded `AuthKey_XXXX.p8` file's contents |

Once, in App Store Connect: create the app (bundle ID `com.cellosig.app`,
registered automatically by the first signed build or by hand under
Certificates, IDs & Profiles with the App Groups capability
`group.com.cellosig.app`).

Each TestFlight build asks the export-compliance question (the app uses its
own end-to-end encryption); answer it in App Store Connect.

## Not yet on iPhone

Push notifications (relay → APNs, needs an APNs key), calls, Tor/onion
routing, relay auto-discovery (enter the current relay address at sign-up),
stickers/voice notes/reminders, app lock.
