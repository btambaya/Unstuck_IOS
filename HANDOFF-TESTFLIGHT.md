# Building Unstuck for TestFlight (handoff)

Quick steps for the person doing the App Store Connect / TestFlight upload from
their own Mac + Apple Developer account (account holder of team that owns the
`tech.csalliance.unstuck` app record — App "Unstuck Now", Apple ID 6777491816).

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
  `group.tech.csalliance.unstuck` App Group on your team — needs Admin/Account
  Holder, which you are).

Bundle IDs: app `tech.csalliance.unstuck`, widget `tech.csalliance.unstuck.widgets`.

## 5. Archive + upload
- Top bar destination → **Any iOS Device (arm64)**.
- **Product → Archive** (~2–4 min).
- In the Organizer → **Distribute App → TestFlight (Internal Testing) → Upload**
  → keep automatic-signing defaults → **Upload**.
- It appears in **App Store Connect → Unstuck Now → TestFlight** after ~5–15 min
  of processing; then add internal testers.

## Notes
- Verified green: `swift test` 217/0; app + widget build + launch on the simulator.
- Push notifications (APNs) are intentionally NOT enabled in this first build —
  no `aps-environment` entitlement — so it uploads without APNs setup. Re-add
  `aps-environment = production` once an APNs key is configured.
- App version/build is `0.1.0 (1)` (App/Info.plist). Bump `CFBundleVersion` for
  each new TestFlight upload.
