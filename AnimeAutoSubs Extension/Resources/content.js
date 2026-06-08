// Runs in every frame (manifest: all_frames: true), so cross-origin
// iframes that hold the actual <video> get observed too.

const log = (msg) => console.log("[anime-ext content]", msg);

const findVideo = () => document.querySelector("video");

const reportState = (event) => {
    const v = findVideo();
    const payload = {
        event,
        paused: v ? v.paused : null,
        src: v ? v.currentSrc : null,
        href: location.href,
    };
    browser.runtime.sendMessage(payload).catch(() => {});
    log(payload);
};

const observe = (v) => {
    if (v.dataset.animeAutoSubObserved) return;
    v.dataset.animeAutoSubObserved = "true";
    v.addEventListener("play",  () => reportState("play"));
    v.addEventListener("pause", () => reportState("pause"));
    reportState("found");
};

const initial = findVideo();
if (initial) observe(initial);

// Catch lazy-loaded video elements.
new MutationObserver(() => {
    const v = findVideo();
    if (v && !v.dataset.animeAutoSubObserved) observe(v);
}).observe(document, { childList: true, subtree: true });

// Commands from background.js. Three command types:
//   toggle - flip the current state
//   play   - resume if paused (no-op if already playing)
//   pause  - pause if playing (no-op if already paused)
// The background script tracks which frame owns the video and routes
// commands to it via tabs.sendMessage(..., {frameId}).
browser.runtime.onMessage.addListener((msg) => {
    if (!msg || !msg.cmd) return;
    const v = findVideo();
    if (!v) { log(`${msg.cmd}: no video in this frame`); return; }
    switch (msg.cmd) {
        case "toggle":
            v.paused ? v.play() : v.pause();
            log(`toggle: ${v.paused ? "→play" : "→pause"}`);
            break;
        case "play":
            if (v.paused) {
                v.play();
                log("play");
            } else {
                log("play (already playing, no-op)");
            }
            break;
        case "pause":
            if (!v.paused) {
                v.pause();
                log("pause");
            } else {
                log("pause (already paused, no-op)");
            }
            break;
        default:
            log(`unknown cmd: ${msg.cmd}`);
    }
});

log(`loaded in frame ${location.href}`);

// Keep the background service worker alive by maintaining a long-lived
// port. Safari (like Chrome MV3) suspends the background script after
// ~30 s of inactivity, which stops our 10 Hz polling for app→source
// commands and makes the dialog Play/Pause button feel sluggish (~10 s
// to respond). Opening a port and pinging it periodically keeps the
// worker resident as long as a content script is loaded somewhere.
// Re-opens if Safari drops the port (which it does on suspension).
const KEEPALIVE_NAME = "keepalive";
const KEEPALIVE_PING_INTERVAL_MS = 20_000;
let keepAlivePort = null;
const ensureKeepAlivePort = () => {
    try {
        keepAlivePort = browser.runtime.connect({ name: KEEPALIVE_NAME });
        keepAlivePort.onDisconnect.addListener(() => {
            keepAlivePort = null;
            setTimeout(ensureKeepAlivePort, 1000);
        });
    } catch (e) {
        // Extension context lost (rare); retry shortly.
        setTimeout(ensureKeepAlivePort, 1000);
    }
};
ensureKeepAlivePort();
setInterval(() => {
    if (keepAlivePort) {
        try { keepAlivePort.postMessage({ ping: Date.now() }); } catch (e) {}
    }
}, KEEPALIVE_PING_INTERVAL_MS);
