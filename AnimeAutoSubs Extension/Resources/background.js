// Track latest state from any frame (used by the popup and the AppKit app).
let lastState = { event: "init", paused: null, src: null, href: null };

// Per-tab map: tabId → frameId where a <video> was last reported. Lets us
// route commands to the iframe that actually contains the video, not the
// top frame. `browser.tabs.sendMessage` without a frameId only reaches the
// top frame; on iframe-embedded video sites (animepahe, animekizz) the
// top frame has no video and silently swallows the command.
const videoFrames = new Map();

// The Safari extension supports two parallel IPC transports with the
// Mac app: legacy file-IPC via the native messaging handler, and the
// newer HTTP server at 127.0.0.1:8912 (same server Chrome uses). The
// extension always dual-sends state on both channels and dual-polls
// commands from both channels — the Mac side decides which transport
// is active for the current broadcast based on the user's preference
// and only produces commands via the active one. No dedupe needed.
//
// Once HTTP is proven across all browsers, the native-messaging path
// can be deleted (along with SafariWebExtensionHandler.swift, the App
// Group entitlement, and the related Swift bridge).
const HTTP_SERVER_BASE = "http://127.0.0.1:8912";
const BROWSER_ID = "Safari";

const sendStateToNative = (state) => {
    browser.runtime.sendNativeMessage("application.id", { type: "state", state })
        .catch(err => console.log("[bg] native state send failed:", err));
};

const sendStateToHTTP = (state) => {
    const body = Object.assign({ browser: BROWSER_ID }, state);
    fetch(HTTP_SERVER_BASE + "/state", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
    }).catch(_ => {
        // Server unreachable — Mac app isn't running, or HTTP bridge
        // isn't enabled. Native messaging path still works; don't spam.
    });
};

const broadcastState = (state) => {
    sendStateToNative(state);
    sendStateToHTTP(state);
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
        broadcastState(msg);
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

// Poll both transports at 10 Hz. The Mac app only produces commands
// via the active transport (per the safariTransport setting), so at
// most one of the two polls returns a command on any given tick.
// Whichever returns first dispatches; the other returns empty.
const dispatchPolledCommand = (response, source) => {
    if (response && typeof response.command === "string") {
        console.log("[bg]", source, "poll → command:", response.command);
        const extras = {};
        if (typeof response.time === "number") extras.time = response.time;
        if (typeof response.delta === "number") extras.delta = response.delta;
        dispatchToVideo(response.command, extras);
    }
};

setInterval(() => {
    // Native messaging (file IPC) path.
    browser.runtime.sendNativeMessage("application.id", { type: "poll" })
        .then(response => dispatchPolledCommand(response, "native"))
        .catch(err => console.log("[bg] native poll failed:", err));

    // HTTP path.
    fetch(HTTP_SERVER_BASE + "/poll?browser=" + BROWSER_ID, { method: "GET" })
        .then(r => r.ok ? r.json() : null)
        .then(response => dispatchPolledCommand(response, "http"))
        .catch(_ => {
            // Server unreachable — Mac app off, or HTTP path disabled.
            // Native path covers us; don't spam logs.
        });
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
