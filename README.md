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

## Features

Everything the Android app does for messaging (sealed sender, safety numbers,
groups, files, polls, reactions, disappearing messages, profiles, requests,
blocking) plus:

- **Calls**: WebRTC voice (`App/Calls/CallManager.swift`), SDP only inside the
  E2E channel, TURN-only when the relay offers TURN. CallKit shows them on the
  lock screen; the relay wakes a closed app with a VoIP push (the caller's app
  flags the offer with `call: true`).
- **Push**: the notification extension fetches and decrypts; the relay's push
  carries no sender or content. Needs an APNs key on the relay
  (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_PATH`) — the same key sends VoIP pushes.
- Voice notes, stickers (built-in emoji pack), animated GIFs, reminders
  (`TimeParser` finds times like "tomorrow at 5"), App lock (Face ID / passcode).
- Pictures from others are decoded scaled down (≤1600 px, GIFs ≤50 frames).
- **Edit / delete for everyone** (payloads `edit` and `unsend`, target = message
  id; Android 0.3.5+ shows them, older Android ignores them). Your own messages,
  within 24 h; receivers accept them only from the original sender.
- **Search** across chats and messages; tapping a hit opens the chat at it.
- **Widget** (`Widget/`, Home and Lock Screen) and **Share to cellosig**
  (`ShareExt/`). Neither can read keys or messages: the app writes
  `widget.json` / `share-targets.json` into the App Group (chat contents only
  when notification previews are on and App lock is off), and the share
  extension queues files in `inbox/` for the app to encrypt and send
  (`App/Bridge/ExtensionBridge.swift`). Sideloaded builds discover the App
  Group name from the provisioning profile (`Shared/AppGroup.swift`).
- Themes (light/dark/system), accent colour, chat wallpapers (presets or a photo).
- Disappearing-message timer in the chat header.

Sideload artifacts: `cellosig-sideload.ipa` (no extensions) and
`cellosig-sideload-widgets.ipa` (widget + share; App Group
`group.com.cellosig.sideload`; uses all 3 of a free Apple ID's app slots).

## Not on iPhone

- Tor/onion routing and the onion-based relay lookup: the app follows the
  relay through signed pushes instead (enter the current address at sign-up).
- Calls with ordinary phone numbers (the relay's PSTN bridge) — Android only.
