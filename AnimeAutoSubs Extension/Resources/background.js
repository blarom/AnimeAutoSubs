// Track latest state from any frame (used by the popup and the AppKit app).
let lastState = { event: "init", paused: null, src: null, href: null };

// Per-tab map: tabId → frameId where a <video> was last reported. Lets us
// route commands to the iframe that actually contains the video, not the
// top frame. `browser.tabs.sendMessage` without a frameId only reaches the
// top frame; on iframe-embedded video sites (animepahe, animekizz) the
// top frame has no video and silently swallows the command.
const videoFrames = new Map();

const sendStateToNative = (state) => {
    browser.runtime.sendNativeMessage("application.id", { type: "state", state })
        .catch(err => console.log("[bg] native state send failed:", err));
};

// Dispatch a generic command to the active tab's video frame. `cmd` is
// the command name ("toggle" | "play" | "pause" | "seek" | "skip");
// `extras` is an optional object whose fields are merged into the
// message payload sent to content.js (e.g. {time: 123.45} for seek,
// {delta: -10} for skip). Falls back to the top frame if we haven't
// yet observed which frame owns the video.
const dispatchToVideo = (cmd, extras = {}) => {
    browser.tabs.query({ active: true, currentWindow: true }).then((tabs) => {
        if (!tabs[0]) {
            console.log("[bg] dispatchToVideo: no active tab");
            return;
        }
        const tabId = tabs[0].id;
        const frameId = videoFrames.get(tabId);
        const payload = Object.assign({ cmd }, extras);
        if (frameId !== undefined) {
            console.log("[bg] dispatch", cmd, "→ tab", tabId, "frame", frameId, extras);
            browser.tabs.sendMessage(tabId, payload, { frameId }).catch(err =>
                console.log("[bg] tabs.sendMessage(frameId) failed:", err)
            );
        } else {
            console.log("[bg] dispatch", cmd, "→ tab", tabId, "(no known video frame)", extras);
            browser.tabs.sendMessage(tabId, payload).catch(err =>
                console.log("[bg] tabs.sendMessage(top) failed:", err)
            );
        }
    });
};

// State events from content scripts. Track the originating frame so future
// commands can be routed to it specifically.
browser.runtime.onMessage.addListener((msg, sender) => {
    if (msg && msg.event && sender.tab) {
        lastState = msg;
        if (videoFrames.get(sender.tab.id) !== sender.frameId) {
            console.log("[bg] video frame:", sender.tab.id, "→", sender.frameId, msg.href);
            videoFrames.set(sender.tab.id, sender.frameId);
        }
        console.log("[bg] state from content:", msg);
        sendStateToNative(msg);
    }
});

// Clean up the videoFrames map when a tab navigates or closes.
browser.tabs.onRemoved.addListener((tabId) => {
    videoFrames.delete(tabId);
});
browser.tabs.onUpdated.addListener((tabId, changeInfo) => {
    if (changeInfo.url) videoFrames.delete(tabId);
});

// Popup queries / commands.
browser.runtime.onMessage.addListener((msg, sender, sendResponse) => {
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

// Poll the native handler for commands queued by the AppKit app at 10 Hz.
// 100 ms is fast enough that dialog Play/Pause feels responsive (~250 ms
// total round-trip including the bridge's state echo) and the file read
// is cheap (≤ 100 bytes from the App Group container).
//
// Commands are pass-through: the file contains "toggle" / "play" / "pause"
// and we forward to the video. Future-proofs us against any direct command
// the coordinator might want to send (e.g. seek, set volume).
setInterval(() => {
    browser.runtime.sendNativeMessage("application.id", { type: "poll" })
        .then(response => {
            if (response && typeof response.command === "string") {
                console.log("[bg] native poll → command:", response.command);
                // Forward extra fields (seek time, skip delta) as part of
                // the message payload so content.js gets them as msg.time
                // / msg.delta.
                const extras = {};
                if (typeof response.time === "number") extras.time = response.time;
                if (typeof response.delta === "number") extras.delta = response.delta;
                dispatchToVideo(response.command, extras);
            }
        })
        .catch(err => console.log("[bg] native poll failed:", err));
}, 100);

console.log("[bg] background script loaded");

// Long-lived port from content scripts keeps this background script alive.
// MV3 service workers in Safari/Chrome get terminated after ~30 s without
// activity, which kills our setInterval polling. As long as at least one
// content script has an open port, the worker stays resident.
browser.runtime.onConnect.addListener((port) => {
    if (port.name === "keepalive") {
        console.log("[bg] keepalive port connected");
        port.onDisconnect.addListener(() => {
            console.log("[bg] keepalive port disconnected");
        });
        // We don't need to do anything with the ping messages — the
        // mere existence of an open port is what keeps us alive. Drain
        // them so they don't accumulate.
        port.onMessage.addListener((_msg) => {});
    }
});
