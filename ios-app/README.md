# Log for iPhone

The Log app (Capacitor 8). Since Nov 25, 2026 the app's files are built into the app itself, from `www/`, and new work ships only here; the website is frozen.

- The app opens from its own files, so it starts offline and doesn't depend on the website.
- API calls go through the app's native HTTP (`CapacitorHttp`), so the Edge Functions' CORS rules don't apply to it and didn't need changing.
- The passcode is entered once on the app's lock screen and kept in the app's own storage. The first version with built-in files (1.1) starts with fresh storage: enter the passcode again, and the Apple Health history backfill runs once more (it only fills in what's missing).

Nothing in this folder holds a passcode, token or key. Keep it that way.

## Making changes

1. Edit the files in `www/`.
2. Run the tests: `cd ../tests && npm test` (see the root README).
3. Run `sh sync-web.sh` to copy `www/` into the Xcode project (`ios/App/App/public`). The workflow does this itself, but the copy is committed so building straight from Xcode works, and the tests check the two match.
4. For a release you want to tell apart, bump `VERSION` (for example `1.1` to `1.2`). The build number goes up by one on every build by itself.

## Versions

Each build is **version** (from `VERSION`) plus **build** (the workflow's run number): `Log 1.1 (build 14)`. It's set as the app's version in iOS (**Settings > General > iPhone Storage > Log** shows it), in the file name (`Log-1.1-14.ipa`), the artifact name (`Log-1.1-build-14`), and at the bottom of the app's Log tab with the build date.

## Get an .ipa without Xcode

Every push that changes `ios-app/` runs the **iPhone app (.ipa)** workflow (or run it by hand from the Actions tab). It runs the tests, then builds on GitHub's Mac runners an unsigned `Log-<version>-<build>.ipa` and keeps it for 30 days under the run's **Artifacts** (sign in to GitHub to download; it arrives zipped).

To put it on your iPhone, use a sideloading tool on a Mac or PC, which signs it with your Apple ID:

- **Sideloadly** (Mac or Windows): plug in the iPhone, drop the `.ipa` in, sign in with your Apple ID, Start.
- **AltStore** (AltServer on the Mac mini): re-signs the app over Wi-Fi every few days so it doesn't lapse.

Then on the iPhone turn on **Settings > Privacy & Security > Developer Mode** and trust your Apple ID under **Settings > General > VPN & Device Management**. With a free Apple ID the app has to be re-signed every 7 days (AltStore does this for you). Whether Apple Health access survives signing with a free Apple ID isn't guaranteed; if Health sync can't get permission, the rest of the app still works, and building from Xcode with your Apple ID is the fallback.

## Build from Xcode instead

## What you need

- A Mac with Xcode installed (from the App Store) and Node.js.
- Your iPhone and a USB-C cable (or the same Wi-Fi network after the first run).
- An Apple ID. A free one works; see "How long it lasts" below.

## Build and install

1. On the Mac, get the repo (GitHub Desktop or `git clone https://github.com/pranaybop/health-log.git`), run `sh ios-app/sync-web.sh`, and open `ios-app/ios/App/App.xcodeproj` in Xcode. No npm step is needed: Capacitor comes in through Swift Package Manager, and the config and web files are committed. A build from Xcode shows as "development copy" on the Log tab; set the version under the App target's **General** tab if you want one. Run `npm install && npx cap sync ios` only after changing native plugins.

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
| `capacitor.config.json` | App id and name, native HTTP on (the copy the app reads is `ios/App/App/capacitor.config.json`) |
| `www/` | The app: HTML, scripts, styles and icons |
| `sync-web.sh` | Copies `www/` into `ios/App/App/public`, which is what gets built into the app |
| `VERSION` | The app version; the build number comes from the workflow run |
| `ios/App` | The Xcode project: icon, launch screen, iPhone-only, portrait-only |

## Apple Health sync

The app reads everything [`@capgo/capacitor-health`](https://github.com/Cap-go/capacitor-health) supports on iPhone (pulled in by Swift Package Manager from its `8.13.0` tag): steps, distance, active and resting energy, exercise minutes, stand hours, flights, cycling, resting and all-day heart rate, HRV, VO2 max, breathing rate, blood oxygen, blood pressure, glucose, body, basal and sleeping wrist temperature, sleep and sleep stages, mindful minutes, State of Mind, water, dietary energy, height, weigh-ins, body fat and workouts.

- Daily totals go to `health_sync` (`log.daily_health`), weigh-ins, body fat (with lean mass worked out from the weigh-in taken with it) and workouts too. Everything else goes to `health_metrics` (`log.health_metrics`) and shows on Trends under **More from Apple Health**.
- The plugin can only aggregate steps, distance, active energy, water, dietary energy, heart rate and resting heart rate. Everything else is read as samples; for things both the iPhone and the Watch count (flights, exercise minutes, resting energy), a day's total is the larger of the two, never the sum. Sleep is credited to the morning you woke up and comes from the source with the most sleep that night.
- iOS asks for permission the first time; change it later in **Settings > Health > Data Access & Devices > Log**.
- When the app opens it catches up on the last 3 days (at most every 30 minutes; 30 days the first time), then keeps backfilling history from yesterday back to 2015 or until a year turns up nothing. Backfill sends metrics, weigh-ins, body fat and workouts only; older daily totals came from the Health export and aren't touched. Its place is saved on the phone (`log.healthBackfill`), so it carries on next launch. **Backfill again** on the Log tab's Apple Health card starts over.
- **Sync Apple Health** on Today's Body card pulls 7 days; the Apple Health card on the Log tab pulls 30. Pulling down from the top of any tab syncs the last 2 days and refreshes.
- The project already has the HealthKit entitlement (`App/App.entitlements`) and the permission text in `Info.plist`. If Xcode complains about the HealthKit capability when signing, open **Signing & Capabilities** and add **HealthKit** with the + button so Xcode registers it for your team.
