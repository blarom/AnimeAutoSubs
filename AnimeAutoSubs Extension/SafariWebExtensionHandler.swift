//
//  SafariWebExtensionHandler.swift
//  AnimeAutoSubs Extension
//

import SafariServices
import os.log

/// App Group identifier — must match the one configured in both targets'
/// "Signing & Capabilities" tab. Both processes read/write to the same
/// container directory via `containerURL(forSecurityApplicationGroupIdentifier:)`,
/// which (unlike `UserDefaults(suiteName:)`) gives identical paths to
/// sandboxed and non-sandboxed processes with the same App Group.
private let appGroupID = "group.com.barlr.AnimeAutoSubs"
private let commandFileName = "command.json"
private let stateFileName = "state.json"

@available(macOS 11.0, *)
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private var commandURL: URL? {
        containerURL?.appendingPathComponent(commandFileName)
    }

    private var stateURL: URL? {
        containerURL?.appendingPathComponent(stateFileName)
    }

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        var responseBody: [String: Any] = [:]

        if let msg = message, let type = msg["type"] as? String {
            switch type {
            case "state":
                if let state = msg["state"] as? [String: Any] {
                    writeState(state)
                }
                responseBody = ["ok": true]

            case "poll":
                if let cmdDict = readAndClearCommand() {
                    os_log(.default, "[handler] command → %{public}@", String(describing: cmdDict))
                    responseBody = cmdDict
                } else {
                    responseBody = [:]
                }

            default:
                os_log(.error, "[handler] unknown message type: %{public}@", type)
                responseBody = ["error": "unknown type"]
            }
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: responseBody]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    // MARK: - File IO

    private func writeState(_ state: [String: Any]) {
        guard let url = stateURL else {
            os_log(.error, "[handler] no container URL — App Group entitlement missing?")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            os_log(.error, "[handler] failed to write state.json: %{public}@", String(describing: error))
        }
    }

    /// Reads `command.json`, returns the embedded command dict (`command`
    /// string plus any extras like `time` or `delta`), and deletes the
    /// file so the same command isn't processed twice. The id field is
    /// preserved only for logging.
    private func readAndClearCommand() -> [String: Any]? {
        guard let url = commandURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let id = dict["id"] as? String {
            os_log(.default, "[handler] consumed command id=%{public}@", id)
        }
        return dict
    }
}
