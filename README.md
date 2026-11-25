# Log

A live health dashboard that reads the `log` schema in Supabase through a read-only Edge Function (`log-dashboard`).

Open https://pranaybop.github.io/health-log/ and enter your passcode. This device stores it in localStorage until you tap Lock. The older `#k=` access-token link still works.

The page fetches on load, refreshes every 60 seconds, and has a manual refresh control. Estimated tirzepatide level uses a 5-day half-life model and is not a lab measurement.

Meal macros may be estimates. Times display in America/Chicago.

Do not put passcodes, access tokens, or other secrets in this repo.
