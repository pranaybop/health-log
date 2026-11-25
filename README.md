# Log

A live health dashboard that reads Pranay's `log` schema in Supabase through a read-only Edge Function (`log-dashboard`).

The static app is meant to be opened with an access token in the URL hash (`#k=...`), which stays in the browser and is sent to the function as the `x-log-token` header. Do not put the token in this repo, in query strings, or in chat that is not private.

The page fetches on load, refreshes every 60 seconds, and has a manual refresh control. Estimated tirzepatide level uses a 5-day half-life model and is not a lab measurement.

Meal macros may be estimates. Times display in America/Chicago.
