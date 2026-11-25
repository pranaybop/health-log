# Log for iPhone

A native iPhone app shell (Capacitor 8) for the Log dashboard. The app loads the live site at https://pranaybop.github.io/health-log/, so:

- every change pushed to `main` shows up the next time the app opens, with no rebuild;
- requests come from the GitHub Pages origin, so the Edge Functions' CORS rules work unchanged;
- the passcode is entered once on the app's lock screen and kept in the app's own storage, separate from Safari's.

Rebuild only when something in `ios-app/` changes (icon, name, native plugins).

Nothing in this folder holds a passcode, token or key. Keep it that way.

## What you need

- A Mac with Xcode installed (from the App Store) and Node.js.
- Your iPhone and a USB-C cable (or the same Wi-Fi network after the first run).
- An Apple ID. A free one works; see "How long it lasts" below.

## Build and install

1. On the Mac, get the repo and install the shell's packages:

   ```sh
   git clone https://github.com/pranaybop/health-log.git   # or: git pull
   cd health-log/ios-app
   npm install
   npx cap sync ios
   npx cap open ios
   ```

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

## Possible next step: Apple Health sync

A native app can read steps, sleep, resting heart rate, HRV and weight straight from Apple Health, which a web page can't. That would need a HealthKit plugin here and a new write action on the backend (for `log.daily_health` and `log.weights`), so it waits for an explicit go-ahead.
