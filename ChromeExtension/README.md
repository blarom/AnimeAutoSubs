# AnimeAutoSubs — Chrome / Chromium extension

Companion extension that gives the macOS app direct control of the
source `<video>` element when the user broadcasts a Chrome / Brave /
Edge / Arc / Vivaldi / Opera window.

## Install (developer mode, until Web Store distribution lands)

1. Make sure AnimeAutoSubs.app is running (it provides the local HTTP
   server on `127.0.0.1:8912` that this extension talks to).
2. Open `chrome://extensions` (or `brave://extensions`, etc.).
3. Toggle **Developer mode** on (top-right).
4. Click **Load unpacked** and pick this `ChromeExtension/` folder.
5. Pin the extension to the toolbar so the popup is easy to reach.

The extension does nothing visible until you start a broadcast against
a browser window. After that, dialog Play/Pause, the scrub slider, and
the ±10/30 s skip buttons in the broadcast window all route through
this extension to the source video.

## Architecture (matches the Safari extension)

- `content.js` runs in every frame, observes the first `<video>` it
  finds, and reports play / pause / seek / timeupdate / durationchange
  events to the background service worker.
- `background.js` POSTs those events to `http://127.0.0.1:8912/state`
  (tagged with `browser: "Chrome"`) and polls
  `/poll?browser=Chrome` at 10 Hz for commands queued by the app.
  When a command arrives, it dispatches it to the right frame via
  `tabs.sendMessage`.
- `popup.html` / `popup.js` is the toolbar UI — shows the last observed
  state and offers a manual Toggle button.

The Mac app's `HTTPExtensionBridge(browserName: "Chrome", server: ...)`
is the other end of this conversation. See
`LocalControlServer.swift` for the wire protocol.
