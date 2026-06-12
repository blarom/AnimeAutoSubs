// Background service worker. Bridges between the content scripts and
// the AnimeAutoSubs Mac app's local HTTP server.
//
// Parallel design to the Safari extension's background.js, but the
// IPC layer uses fetch() to 127.0.0.1:8912 instead of native
// messaging. The HTTP server is provided by `LocalControlServer.swift`
// inside the Mac app and is shared with the Safari HTTP bridge.

const ext = (typeof browser !== "undefined") ? browser : chrome;

const SERVER_BASE = "http://127.0.0.1:8912";
const BROWSER_ID = "Chrome";
const POLL_INTERVAL_MS = 100;

// Track the latest state from any frame (popup reads it).
let lastState = { event: "init", paused: null, src: null, href: null };

// Per-tab map: tabId → frameId where a <video> was last reported. Lets
// us route commands to the iframe that actually contains the video,
// not the top frame. `tabs.sendMessage` without a frameId only reaches
// the top frame; on iframe-embedded video sites the top frame has no
// video and silently swallows the command.
const videoFrames = new Map();

// POST state to the Mac app. Tagged with `browser: "Chrome"` so the
// server routes it to the Chrome HTTP bridge specifically.
const sendStateToServer = (state) => {
    const body = Object.assign({ browser: BROWSER_ID }, state);
    fetch(SERVER_BASE + "/state", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
    }).catch(err => console.log("[bg] /state POST failed:", err));
};

// Dispatch a generic command to the active tab's video frame. `cmd`
// is the command name; `extras` is an object whose fields are merged
// into the message payload (e.g. {time: 123.45} for seek).
const dispatchToVideo = (cmd, extras) => {
    extras = extras || {};
    ext.tabs.query({ active: true, currentWindow: true }).then((tabs) => {
        if (!tabs[0]) {
            console.log("[bg] dispatchToVideo: no active tab");
            return;
        }
        const tabId = tabs[0].id;
        const frameId = videoFrames.get(tabId);
        const payload = Object.assign({ cmd }, extras);
        if (frameId !== undefined) {
            console.log("[bg] dispatch", cmd, "→ tab", tabId, "frame", frameId, extras);
            ext.tabs.sendMessage(tabId, payload, { frameId }).catch(err =>
                console.log("[bg] tabs.sendMessage(frameId) failed:", err)
            );
        } else {
            console.log("[bg] dispatch", cmd, "→ tab", tabId, "(no known video frame)", extras);
            ext.tabs.sendMessage(tabId, payload).catch(err =>
                console.log("[bg] tabs.sendMessage(top) failed:", err)
            );
        }
    });
};

// State events from content scripts. Track originating frame so future
// commands can be routed to it specifically, and forward to the Mac app.
ext.runtime.onMessage.addListener((msg, sender) => {
    if (msg && msg.event && sender.tab) {
        lastState = msg;
        if (videoFrames.get(sender.tab.id) !== sender.frameId) {
            console.log("[bg] video frame:", sender.tab.id, "→", sender.frameId, msg.href);
            videoFrames.set(sender.tab.id, sender.frameId);
        }
        sendStateToServer(msg);
    }
});

// Clean up the videoFrames map when a tab navigates or closes.
ext.tabs.onRemoved.addListener((tabId) => {
    videoFrames.delete(tabId);
});
ext.tabs.onUpdated.addListener((tabId, changeInfo) => {
    if (changeInfo.url) videoFrames.delete(tabId);
});

// Popup queries / commands.
ext.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg && msg.fromPopup === "getState") {
        sendResponse(lastState);
        return true;
    }
    if (msg && msg.fromPopup === "toggle") {
        console.log("[bg] popup → toggle");
        dispatchToVideo("toggle");
        sendResponse({ ok: true });
        return true;
    }
});

// Poll the Mac app for commands queued by the AppKit app at 10 Hz. The
// server returns `{}` if nothing is pending, otherwise the command
// object directly: `{id, command, time?, delta?, …}`.
setInterval(() => {
    fetch(SERVER_BASE + "/poll?browser=" + BROWSER_ID, { method: "GET" })
        .then(r => r.ok ? r.json() : null)
        .then(response => {
            if (response && typeof response.command === "string") {
                console.log("[bg] /poll → command:", response.command);
                const extras = {};
                if (typeof response.time === "number") extras.time = response.time;
                if (typeof response.delta === "number") extras.delta = response.delta;
                dispatchToVideo(response.command, extras);
            }
        })
        .catch(err => {
            // Server unreachable — likely the Mac app isn't running.
            // Logging would spam; swallow silently. Next tick retries.
        });
}, POLL_INTERVAL_MS);

console.log("[bg] background script loaded");

// Long-lived port from content scripts keeps this service worker alive.
ext.runtime.onConnect.addListener((port) => {
    if (port.name === "keepalive") {
        console.log("[bg] keepalive port connected");
        port.onDisconnect.addListener(() => {
            console.log("[bg] keepalive port disconnected");
        });
        port.onMessage.addListener((_msg) => {});
    }
});
