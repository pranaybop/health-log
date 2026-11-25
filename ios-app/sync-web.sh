#!/bin/sh
# Copy the app (ios-app/www) into the Xcode project's bundled folder (ios/App/App/public).
# Run it after changing anything in www/ if you build from Xcode; the GitHub workflow runs it itself.
set -e
cd "$(dirname "$0")"
PUB=ios/App/App/public
find "$PUB" -mindepth 1 -maxdepth 1 ! -name cordova.js ! -name cordova_plugins.js -exec rm -rf {} +
cp -R www/. "$PUB/"
echo "Copied www/ into $PUB"
