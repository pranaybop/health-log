# Log for iPhone

A native iPhone app shell (Capacitor 8) for the Log dashboard. The app loads the live site at https://pranaybop.github.io/health-log/, so:

- every change pushed to `main` shows up the next time the app opens, with no rebuild;
- requests come from the GitHub Pages origin, so the Edge Functions' CORS rules work unchanged;
- the passcode is entered once on the app's lock screen and kept in the app's own storage, separate from Safari's.

Rebuild only when something in `ios-app/` changes (icon, name, native plugins).

Nothing in this folder holds a passcode, token or key. Keep it that way.

## Get an .ipa without Xcode

Every push that changes `ios-app/` runs the **iPhone app (.ipa)** workflow on GitHub's Mac runners (or run it by hand from the Actions tab). It builds an unsigned `Log.ipa` and keeps it for 30 days under the run's **Artifacts** (sign in to GitHub to download; it arrives zipped).

To put it on your iPhone, use a sideloading tool on a Mac or PC, which signs it with your Apple ID:

- **Sideloadly** (Mac or Windows): plug in the iPhone, drop `Log.ipa` in, sign in with your Apple ID, Start.
- **AltStore** (AltServer on the Mac mini): re-signs the app over Wi-Fi every few days so it doesn't lapse.

Then on the iPhone turn on **Settings > Privacy & Security > Developer Mode** and trust your Apple ID under **Settings > General > VPN & Device Management**. With a free Apple ID the app has to be re-signed every 7 days (AltStore does this for you). Whether Apple Health access survives signing with a free Apple ID isn't guaranteed; if Health sync can't get permission, the rest of the app still works, and building from Xcode with your Apple ID is the fallback.

## Build from Xcode instead

## What you need

- A Mac with Xcode installed (from the App Store) and Node.js.
- Your iPhone and a USB-C cable (or the same Wi-Fi network after the first run).
- An Apple ID. A free one works; see "How long it lasts" below.

## Build and install

1. On the Mac, get the repo (GitHub Desktop or `git clone https://github.com/pranaybop/health-log.git`) and open `ios-app/ios/App/App.xcodeproj` in Xcode. No npm step is needed: Capacitor comes in through Swift Package Manager, and the generated config and web files are committed. Run `npm install && npx cap sync ios` only after changing `capacitor.config.json` or `www/`.

2. In Xcode, select the **App** target, open **Signing & Capabilities**, and pick your Apple ID under **Team** (add it in Xcode Settings > Accounts if it isn't listed). If Xcode says the bundle identifier is taken, change `com.pranaybop.log` to something unique, such as `com.yourname.log`.
3. Plug in the iPhone, choose it as the run destination at the top of the window, and press Run (⌘R).
4. The first time only, on the iPhone:
   - turn on **Settings > Privacy & Security > Developer Mode** and restart when asked;
   - trust your certificate under **Settings > General > VPN & Device Management**.
5. Open **Log** from the home screen and enter your passcode.

## How long it lasts

- **Free Apple ID:** the app stops opening after 7 days. Connect the phone and press Run in Xcode again to renew it. Your passcode and settings stay.
- **Paid Apple Developer account:** installs last a year, and **Product > Archive** then **Distribute App** can export an `.ipa` file or send the app to TestFlight.

## What's in here

| Path | Purpose |
| --- | --- |
| `capacitor.config.json` | App id and name, the live URL, and `offline.html` for when there's no connection |
| `www/` | Fallback pages bundled in the app (offline screen, redirect) |
| `ios/App` | The Xcode project: icon, launch screen, iPhone-only, portrait-only |

## Apple Health sync

The app reads steps, distance, active calories, exercise minutes, stand hours, resting heart rate, HRV, VO2 max, sleep, weigh-ins, body fat and workouts through [`@capgo/capacitor-health`](https://github.com/Cap-go/capacitor-health) (pulled in by Swift Package Manager from its `8.13.0` tag) and sends them to the `health_sync` action. Lean mass is worked out from each body-fat reading and the weigh-in taken with it.

- iOS asks for permission the first time; change it later in **Settings > Health > Data Access & Devices > Log**.
- The app catches up on the last 3 days when it opens (at most every 30 minutes). **Sync Apple Health** on Today's Body card pulls 7 days; the Apple Health card on the Log tab pulls 30.
- The project already has the HealthKit entitlement (`App/App.entitlements`) and the permission text in `Info.plist`. If Xcode complains about the HealthKit capability when signing, open **Signing & Capabilities** and add **HealthKit** with the + button so Xcode registers it for your team.
