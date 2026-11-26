# Log for iPhone

Log is a GLP-1 and health tracker for iPhone. Version 2.0 is fully native: Today, Meds, Trends and Log are SwiftUI (`ios/App/LogNative`), Apple Health sync is native Swift, and the tab bar is a native `UITabBarController` (Liquid Glass on iOS 26). `www/` is only the browser-test target and fallback. Nothing in this folder holds a passcode, token or key. Keep it that way.

## Features

### Accounts and setup
- **Sign in** with a free email account, or Google once it's turned on in Supabase Auth (until then the app says so); the original passcode still works. Each account's rows are its own (`user_id` on every `log` table, enforced by the Edge Functions). Signing in on a phone that has the passcode links the original log to the account.
- **First run** for new accounts: about you, medications (tirzepatide, semaglutide, retatrutide, tesamorelin), optional Apple Health, food logging, daily calorie and protein targets.
- **Account sheet:** sign in or out, link the log, and the AI key used for meal logging and Ask.
- **Face ID** when you come back to the app; days follow your own time zone.
- **Offline:** the last data opens without a connection, and simple logs queue until you're back online.

### Today
- One day at a time: swipe, use the week strip or month picker to move between days.
- **Readiness** right under the weight: a gauge with the 0–10 score, a meter for HRV, resting heart rate and sleep showing better or worse than your normal, one line on what moved it most, and the last 7 days.
- **Weight hero:** current weight and trend, change since start, pace as lb a week and % of body weight.
- **Food:** a calorie and protein ring against your targets, **Log a meal** (describe it, your AI key estimates the macros, review, save), then the day's meals and macros.
- **Under-eating** card in the evening when the day is far below target.
- **Thinking about food?** one tap logs a passing thought, strong pull or craving; can start the hunger Live Activity.
- **Side effects** in one tap with severity.
- **Medication:** estimated drug level now, last dose, next dose from the plan (overdue when missed), next injection site.
- **Daily peptides** (tesamorelin): tonight's shot with one-tap logging on a rotating belly site.
- **Retatrutide switch** card around the switch date.
- **Off your normal:** flags a day when two or more recovery signals (resting HR, HRV, breathing rate, wrist temperature) are off your own 30-day normal.
- **Sleep** and **Body** (Apple Health) cards, the evening **check-in**, a **progress-photo prompt** after a new weigh-in ("New low" when it's the lowest yet), and a **Verdict** on how it's going.

### Meds
- **Next-dose card** at the top with one-tap logging when it's due.
- **Drug level** chart from a half-life model (tirzepatide 5 days, retatrutide 6), with the next planned shot drawn ahead.
- **Dose plan** from the titration sheet: next dose, vial to draw from, weeks at each step; a shot up to 3 days early counts for that week.
- **Injection sites** map with rotation, **titration** and **dosing history**, **protocol**, **vials** with supply runway, and daily **peptide regimens**.

### Trends
- **Summary:** tiles for weight, food, maintenance, medication and recovery that open their section.
- **Ask your data:** chat with your log in the app, answered by Bonsai 2 running on the phone, Apple Intelligence, or your own AI key (details below).
- **Weight:** smoothed trend line over weigh-ins, ranges 1M / 3M / 1Y / All / Since GLP-1, swipe back through history with the scale refitting to what's on screen, compare-with overlays (calories, steps, sleep, resting HR, HRV, food thoughts, food noise), a straight-line projection, goal line and dose markers. **Progress** (counted from your first GLP-1 shot, so years-old Apple Health weigh-ins don't count): % of the way to goal, lost and to go, pace (the same as the Weight card's), predicted goal date, 5 lb milestones (ticked on the first weigh-in at or under each, with an expected date for the rest), today's trend change, lowest trend, change over 1 week to all time. **Stall check**, **body composition** (BMI, body fat, lean mass, share of loss that was lean) and **progress photos**.
- **Food:** daily calories and protein against targets, **maintenance calories** (from food logs and weight trend, and from the Apple Watch), **protein target** hit rate, **food thoughts** by day and time.
- **Meds:** wear-off, the week after a shot, appetite by drug level, retatrutide vs tirzepatide, cycle recaps, feel report, side effects.
- **Body:** **Readiness** score (below), off your normal history, heart, everything else from Apple Health, measurements.
- **Training:** steps and workouts.
- **More:** weekly summary, pattern explorer, Earn It wall, prescriber export (CSV, print views and a 4-week coach pack).

### Log
- Apple Health sync status and backfill, today's check-in (ate / moved vs usual, how the dose feels, mood, food noise, energy, sleep), weigh-in with an optional progress photo, Earn It, reminders.
- More to log: dose (with site), side effect, measurement, vial, and a reconstitution calculator.

### Around the app
- **Widgets** (long-press the Home Screen › +, or the Lock Screen › Customize): **Weight trend** (trend, change since start, progress to goal; the medium size adds a 30-day sparkline, pace and goal date), **Readiness** (today's score as a gauge) and **Food today** (calories left and protein), each in Home Screen and Lock Screen sizes. Tapping one opens that screen. The app writes a small snapshot to the `group.com.pranaybop.log` app group whenever the data changes; the widgets only read it, so they show "Open the app" until it has run once. If your signing tool drops app groups, the widgets can't see the snapshot.
- **Milestones and weekly recap** (Log › Reminders): a notification when a weigh-in passes the next 5 lb mark or the goal, and Sunday at 6 PM with the week's trend change, pace and goal date.
- **Hunger Live Activity** on the Lock Screen and Dynamic Island: today's food thoughts on a timeline, calories left and drug level, with Passing / Strong / Craving buttons that log without opening the app.
- **Reminders** for shots, check-ins and weigh-ins, scheduled a day at a time and skipped once done.
- **Siri and Shortcuts:** "Log my weight in Log", "I'm thinking about food in Log".
- **Pull to refresh** on every tab (syncs the last 2 days from Apple Health first) and a background refresh.

## Progress photos

After a weigh-in, the Log tab offers an optional photo (camera or library). It’s resized to a JPEG and stored in the private `progress-photos` bucket. Trends → Weight scrolls the photos with their date and weight, and a photo can be deleted.

The bucket, its RLS policies, and the `log.progress_photos` columns are in `supabase/migrations/20261125_progress_photos.sql`. That migration has to be applied by hand, then the `log-dashboard` and `log-write` Edge Functions deployed. Until both are live, the rest of the app still loads and the photo step reports that it couldn’t save.

## Readiness

Trends → Body opens with a 0–10 readiness score (`LogCore/Readiness.swift`), worked out on the phone from what Apple Health sync already stores: overnight HRV 35%, resting heart rate 30%, sleep 25%, and the last 3 days' training load against the 4 weeks before 10%. Each signal is compared with your own last 4 weeks (median and spread), so 5 is a normal day for you. It lists the day's calories, weight trend and days since the last shot next to the score. No extra tables or Shortcuts: it reads `log.daily_health` and `log.workouts`.

## Ask your data

Trends → **Ask** answers questions about the log inside the app. Three choices:

- **Local model** (default once one is downloaded): an open model run on the phone's GPU with [MLX Swift](https://github.com/ml-explore/mlx-swift-lm) (`LogLocalAI`). Free, private, works offline. It starts from a two-week overview and calls lookup tools (`LogCore/AskTools.swift`: days, doses and side effects, meals, workouts, weekly averages, any Apple Health metric) for any other dates. Answers appear as they're written. When Ask opens, the downloaded model loads and reads the instructions once; every new conversation forks that session, so it doesn't read them again. Download it once from Hugging Face into Application Support/Models (not backed up); delete it from the same panel.
  - **Bonsai 2 4B** (PrismML, `prism-ml/Ternary-Bonsai-2-4B-mlx-2bit`, 1.9 GB): the default. Quick on an iPhone 15 Pro.
  - **Bonsai 2 9B** (`prism-ml/Ternary-Bonsai-2-9B-mlx-2bit`, 3.6 GB): a 9B Qwen 3.5–based model with ternary weights, the sharpest that fits an 8 GB phone, at about half the speed.
  - **Qwen 3.5 4B** (`mlx-community/Qwen3.5-4B-4bit`, 3.1 GB).

  These are the models from the Locally AI app's list that MLX Swift loads as-is. Thinking is off for quick answers (PrismML's non-thinking sampler). Before loading, the app checks there's enough free memory and suggests the 4B model if not; a memory warning unloads it.
- **Apple AI**: Apple Intelligence's on-device model (`FoundationModels`, iOS 26, with Apple Intelligence turned on). Free and private, but its context is small, so it sees two weeks.
- **Your key**: the key saved under Account › AI (the same one meal logging uses: OpenAI, Anthropic, Google or xAI), called straight from the phone. It gets the same two-week overview and the same lookup tools (each provider's own tool-calling format), so it can answer about any date. A ChatGPT, Claude or SuperGrok subscription doesn't include API access, so this is a key from the company's developer console, billed per question.

The snapshot sent to the model is built by `DataDigest` in `LogCore/AskData.swift`. Nothing about Ask goes through Supabase.

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
