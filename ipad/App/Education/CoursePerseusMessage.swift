import Foundation
import CoreFoundation

/// Validates the bridge boundary. Scores are supplied by the pinned official scorer.
enum CoursePerseusMessage {
    case ready
    case loaded
    case state(json: String, hints: Int)
    case result(json: String, hints: Int, type: String, earned: Double?, total: Double?, message: String?)
    case error(String)

    static func decode(_ body: Any, itemID: String) throws -> Self {
        guard let body = body as? [String: Any], let type = body["type"] as? String else { throw invalid }
        if type == "ready" { return .ready }
        if type == "error", let message = body["message"] as? String, message.utf8.count <= 64 * 1_024 { return .error(message) }
        guard body["itemId"] as? String == itemID else { throw invalid }
        if type == "loaded" { return .loaded }
        guard let state = body["answerState"] as? [String: Any], JSONSerialization.isValidJSONObject(state),
              let number = body["hintsVisible"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              (0...10_000).contains(number.doubleValue) else { throw invalid }
        let hints = number.intValue
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        guard data.count <= 1_024 * 1_024, let json = String(data: data, encoding: .utf8) else { throw invalid }
        if type == "state" { return .state(json: json, hints: hints) }
        guard type == "result", let score = body["score"] as? [String: Any],
              let scoreType = score["type"] as? String, ["points", "invalid"].contains(scoreType) else { throw invalid }
        let message = score["message"] as? String
        guard (score["message"] == nil || score["message"] is NSNull || message != nil),
              (message?.utf8.count ?? 0) <= 64 * 1_024 else { throw invalid }
        if scoreType == "invalid" { return .result(json: json, hints: hints, type: scoreType, earned: nil, total: nil, message: message) }
        guard let earned = score["earned"] as? NSNumber, let total = score["total"] as? NSNumber,
              CFGetTypeID(earned) != CFBooleanGetTypeID(), CFGetTypeID(total) != CFBooleanGetTypeID(),
              earned.doubleValue.isFinite, total.doubleValue.isFinite, total.doubleValue >= 0,
              earned.doubleValue >= 0, earned.doubleValue <= total.doubleValue else { throw invalid }
        return .result(json: json, hints: hints, type: scoreType, earned: earned.doubleValue, total: total.doubleValue, message: message)
    }
    private static var invalid: CourseError { .invalid("The exercise renderer returned invalid progress data.") }
}
