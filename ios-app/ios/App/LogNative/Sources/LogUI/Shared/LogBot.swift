import Foundation

/// Meal logging opens the Log bot in the Grok Bot app. There is no in-app model.
/// The address lives here only.
enum LogBot {
    static let urlString = "grokbot://app/v1/agent?id=81acb34c-2ba4-4bde-aa1b-98e865272965"

    static var url: URL? { URL(string: urlString) }

    /// Shown when the system can't open the link, usually because Grok Bot isn't installed.
    static let unavailableMessage = "Grok Bot isn’t installed."
}
