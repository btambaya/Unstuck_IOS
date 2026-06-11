# Building Unstuck for TestFlight

Steps for the App Store Connect / TestFlight upload under Ahmad's own Apple
Developer team (`M9ULD6M5Z3`, active since 2026-06-11 — the earlier friend's-team
handoff plan is obsolete). The app record for `io.unstucknow.app` must exist in
App Store Connect before upload (Apps → "+" → New App). Note: the app *name*
"Unstuck Now" may still be claimed by the abandoned record on the friend's team
(Apple ID 6777491816) — have him delete that record, or pick a different name.

> **Automated alternative (no manual Xcode steps):** if you can get an **App Store
> Connect API key** for the team (App Store Connect → Users and Access → Integrations
> → Keys → generate a key with App Manager role → download the `.p8`, note the **Key ID**
> + **Issuer ID**), the upload can be scripted instead — `xcodebuild archive` +
> `-exportArchive -exportOptionsPlist ExportOptions.plist` (already set to team
> `M9ULD6M5Z3`, `method app-store-connect`) + `xcrun altool --upload-app` /
> `notarytool`-style auth with the key. Put the `.p8` in `~/.appstoreconnect/private_keys/`.
> This is the preferred path for repeat uploads; the manual steps below are the
> one-time fallback.

## 0. Prerequisites
- macOS + **Xcode 26.x** (signed into your Apple ID under **Xcode → Settings →
  Accounts**, with your paid Developer team).
- **xcodegen** (`brew install xcodegen`) — the `.xcodeproj` is generated from
  `project.yml`.

## 1. Get the code
```sh
git clone https://github.com/btambaya/Unstuck_IOS.git
cd Unstuck_IOS
```

## 2. Add the Supabase key (NOT in git — supplied separately)
Create `App/Secrets.xcconfig` with the value you were sent:
```
SUPABASE_ANON_KEY = <paste the anon key here>
```
(Without it the app boots to a "Setup" screen instead of login. It's the public
Supabase anon/publishable key — same one the Android app ships.)

## 3. Generate + open the project
```sh
xcodegen generate
open Unstuck.xcodeproj
```

## 4. Signing (both targets)
In Xcode, select the **Unstuck** project → for the **Unstuck** target AND the
**UnstuckWidgets** target → **Signing & Capabilities**:
- ✅ Automatically manage signing
- **Team** → your team
- If a **Fix Issue** appears, click it (registers the bundle IDs +
  `group.io.unstucknow.app` App Group on your team — needs Admin/Account
  Holder, which you are).

Bundle IDs: app `io.unstucknow.app`, widget `io.unstucknow.app.widgets`.

## 5. Archive + upload
- Top bar destination → **Any iOS Device (arm64)**.
- **Product → Archive** (~2–4 min).
- In the Organizer → **Distribute App → TestFlight (Internal Testing) → Upload**
  → keep automatic-signing defaults → **Upload**.
- It appears in **App Store Connect → Unstuck Now → TestFlight** after ~5–15 min
  of processing; then add internal testers.

## Notes
- Verified green: `swift test` 263/0; app + widget build + launch on the simulator.
- Push notifications (APNs) are intentionally NOT enabled in this first build —
  no `aps-environment` entitlement — so it uploads without APNs setup. Re-add
  `aps-environment = production` once an APNs key is configured.
- App version/build is `0.1.0 (1)` (App/Info.plist). Bump `CFBundleVersion` for
  each new TestFlight upload.
