// Runs in every frame (manifest: all_frames: true), so cross-origin
// iframes that hold the actual <video> get observed too.
//
// Identical in shape to the Safari extension's content.js — the only
// portable difference is the runtime namespace (Chrome only exposes
// `chrome.*`; Safari exposes both). We bind `ext` once and use it
// throughout so the same file could be copied into the Safari bundle
// unchanged.
const ext = (typeof browser !== "undefined") ? browser : chrome;

const log = (msg) => console.log("[anime-ext content]", msg);

const findVideo = () => document.querySelector("video");

const reportState = (event) => {
    const v = findVideo();
    const payload = {
        event,
        paused: v ? v.paused : null,
        src: v ? v.currentSrc : null,
        href: location.href,
        currentTime: v ? v.currentTime : null,
        duration: v && isFinite(v.duration) ? v.duration : null,
    };
    ext.runtime.sendMessage(payload).catch(() => {});
    log(payload);
};

// `timeupdate` fires natively at ~4 Hz during playback. Throttle to a
// minimum 250 ms gap in case a player implementation fires more often.
let lastTimeUpdateAt = 0;
const onTimeUpdate = () => {
    const now = Date.now();
    if (now - lastTimeUpdateAt < 250) return;
    lastTimeUpdateAt = now;
    reportState("timeupdate");
};

const observe = (v) => {
    if (v.dataset.animeAutoSubObserved) return;
    v.dataset.animeAutoSubObserved = "true";
    v.addEventListener("play",           () => reportState("play"));
    v.addEventListener("pause",          () => reportState("pause"));
    v.addEventListener("seeked",         () => reportState("seeked"));
    v.addEventListener("durationchange", () => reportState("durationchange"));
    v.addEventListener("timeupdate",     onTimeUpdate);
    reportState("found");
};

const initial = findVideo();
if (initial) observe(initial);

// Catch lazy-loaded video elements.
new MutationObserver(() => {
    const v = findVideo();
    if (v && !v.dataset.animeAutoSubObserved) observe(v);
}).observe(document, { childList: true, subtree: true });

// Commands from background.js. Five command types:
//   toggle - flip the current state
//   play   - resume if paused (no-op if already playing)
//   pause  - pause if playing (no-op if already paused)
//   seek   - jump to msg.time (seconds, absolute)
//   skip   - advance/rewind by msg.delta (seconds, signed)
ext.runtime.onMessage.addListener((msg) => {
    if (!msg || !msg.cmd) return;
    const v = findVideo();
    if (!v) { log(`${msg.cmd}: no video in this frame`); return; }
    switch (msg.cmd) {
        case "toggle":
            v.paused ? v.play() : v.pause();
            log(`toggle: ${v.paused ? "→play" : "→pause"}`);
            break;
        case "play":
            if (v.paused) { v.play(); log("play"); }
            else { log("play (already playing, no-op)"); }
            break;
        case "pause":
            if (!v.paused) { v.pause(); log("pause"); }
            else { log("pause (already paused, no-op)"); }
            break;
        case "seek":
            if (typeof msg.time === "number" && isFinite(msg.time)) {
                const dur = isFinite(v.duration) ? v.duration : Number.POSITIVE_INFINITY;
                const target = Math.max(0, Math.min(dur, msg.time));
                v.currentTime = target;
                log(`seek: → ${target.toFixed(2)}s`);
            }
            break;
        case "skip":
            if (typeof msg.delta === "number" && isFinite(msg.delta)) {
                const dur = isFinite(v.duration) ? v.duration : Number.POSITIVE_INFINITY;
                const target = Math.max(0, Math.min(dur, v.currentTime + msg.delta));
                v.currentTime = target;
                log(`skip: ${msg.delta > 0 ? "+" : ""}${msg.delta}s → ${target.toFixed(2)}s`);
            }
            break;
        default:
            log(`unknown cmd: ${msg.cmd}`);
    }
});

log(`loaded in frame ${location.href}`);

// Keep the background service worker alive by maintaining a long-lived
// port. MV3 service workers get terminated after ~30 s of inactivity,
// which would kill our setInterval-based poll loop and make Play/Pause
// from the app feel sluggish. As long as a content script holds a port
// open, the worker stays resident.
const KEEPALIVE_NAME = "keepalive";
const KEEPALIVE_PING_INTERVAL_MS = 20_000;
let keepAlivePort = null;
const ensureKeepAlivePort = () => {
    try {
        keepAlivePort = ext.runtime.connect({ name: KEEPALIVE_NAME });
        keepAlivePort.onDisconnect.addListener(() => {
            // Reading lastError inside the disconnect callback consumes
            // it so Chrome doesn't log an "Unchecked runtime.lastError"
            // warning when the port is torn down because the page was
            // moved into the back/forward cache.
            void ext.runtime.lastError;
            keepAlivePort = null;
            setTimeout(ensureKeepAlivePort, 1000);
        });
    } catch (e) {
        setTimeout(ensureKeepAlivePort, 1000);
    }
};
ensureKeepAlivePort();
setInterval(() => {
    if (keepAlivePort) {
        try { keepAlivePort.postMessage({ ping: Date.now() }); } catch (e) {}
    }
}, KEEPALIVE_PING_INTERVAL_MS);
