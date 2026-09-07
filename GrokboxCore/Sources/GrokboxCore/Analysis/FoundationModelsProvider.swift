import Foundation
import FoundationModels

/// Apple's on-device language model (macOS 26+).
///
/// Runs entirely on the Neural Engine. No network, no install, no daemon.
/// Requires Apple Intelligence to be enabled in System Settings.
@available(macOS 26.0, *)
public struct FoundationModelsProvider: TextModel {
    public let name = "Apple on-device model"

    public init() {}

    public func availability() async -> ModelAvailability {
        // Off the main actor on purpose: the availability getter blocks its
        // calling thread on an XPC reply that is delivered via the main run
        // loop. Called on the main thread inside a GUI app, it deadlocks.
        await Task.detached(priority: .utility) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return ModelAvailability.available
            case .unavailable(let reason):
                return ModelAvailability.unavailable(reason: Self.describe(reason))
            }
        }.value
    }

    public func read(_ request: ReadRequest) async throws -> ReadResult {
        // A fresh session per message: the on-device context window is small,
        // and each email is independent of the last.
        let session = LanguageModelSession(instructions: ReaderPrompt.instructions)
        let response: LanguageModelSession.Response<GeneratedRead>
        do {
            response = try await session.respond(to: request.rendered, generating: GeneratedRead.self)
        } catch let error as LanguageModelSession.GenerationError {
            throw ModelError.generation(Self.describe(error))
        }
        let generated = response.content
        let due = generated.due.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReadResult(
            summary: generated.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            importance: generated.importance.importance,
            reason: generated.reason,
            actionType: generated.action.actionType,
            dueHint: due.isEmpty || due.lowercased() == "none" ? nil : due,
            isQuick: generated.quick
        )
    }

    public func categorize(_ request: CategorizeRequest) async throws -> CategorizeResult {
        let session = LanguageModelSession(instructions: ReaderPrompt.categorizeInstructions)
        let response: LanguageModelSession.Response<GeneratedCategory>
        do {
            response = try await session.respond(to: request.rendered, generating: GeneratedCategory.self)
        } catch let error as LanguageModelSession.GenerationError {
            throw ModelError.generation(Self.describe(error))
        }
        return CategorizeResult(category: response.content.kind.category, reason: response.content.reason)
    }

    /// The framework's own descriptions are opaque ("error -1"). Say what
    /// happened in words a person can act on.
    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize: "the message was too long for the on-device model"
        case .assetsUnavailable: "the on-device model's assets are not available on this device (simulators usually cannot run it; a real device can)"
        case .guardrailViolation: "the on-device model declined this message (safety guardrail)"
        case .unsupportedGuide: "the on-device model rejected the output format"
        case .unsupportedLanguageOrLocale: "the on-device model does not support this language"
        case .decodingFailure: "the on-device model produced an unreadable answer"
        case .rateLimited: "the on-device model is rate-limited right now"
        case .concurrentRequests: "the on-device model was asked to do two things at once"
        case .refusal: "the on-device model refused this message"
        @unknown default: "the on-device model failed (\(error))"
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            "This Mac does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is turned off. Enable it in System Settings."
        case .modelNotReady:
            "The on-device model is still downloading."
        @unknown default:
            "The on-device model is unavailable."
        }
    }
}

/// A model failure with a sentence attached.
public enum ModelError: Error, LocalizedError {
    case generation(String)
    public var errorDescription: String? {
        switch self { case .generation(let why): why }
    }
}

@available(macOS 26.0, *)
@Generable
struct GeneratedRead {
    @Guide(description: "One plain sentence under 20 words: what the message is about and what, if anything, the reader must do.")
    var summary: String

    @Guide(description: "needsYou if a reply, deadline, bill, appointment, or decision is required. worthKnowing for real information needing no action. noise for marketing, newsletters, and automated notifications.")
    var importance: GeneratedImportance

    @Guide(description: "Under 10 words: why that importance.")
    var reason: String

    @Guide(description: "What the reader must do: reply, pay, attend, review, decide, or none.")
    var action: GeneratedAction

    @Guide(description: "The deadline phrase exactly as written in the message, e.g. 'by Friday' or 'the 28th'. Empty string if the message states no deadline. Never invent one.")
    var due: String

    @Guide(description: "true if the action takes under two minutes: a yes/no reply, confirming attendance, accepting an invitation, paying a known bill. false for reviews, documents, decisions needing thought, or anything with no action.")
    var quick: Bool
}

@available(macOS 26.0, *)
@Generable
struct GeneratedCategory {
    @Guide(description: "person, transactional, notification, newsletter, or promotion.")
    var kind: GeneratedKind
    @Guide(description: "Under 8 words: the evidence.")
    var reason: String
}

@available(macOS 26.0, *)
@Generable
enum GeneratedKind {
    case person, transactional, notification, newsletter, promotion

    var category: SenderCategory {
        switch self {
        case .person: .person
        case .transactional: .transactional
        case .notification: .notification
        case .newsletter: .newsletter
        case .promotion: .promotion
        }
    }
}

@available(macOS 26.0, *)
@Generable
enum GeneratedAction {
    case reply, pay, attend, review, decide, none

    var actionType: ActionType {
        switch self {
        case .reply: .reply
        case .pay: .pay
        case .attend: .attend
        case .review: .review
        case .decide: .decide
        case .none: .none
        }
    }
}

@available(macOS 26.0, *)
@Generable
enum GeneratedImportance {
    case needsYou
    case worthKnowing
    case noise

    var importance: Importance {
        switch self {
        case .needsYou: .needsYou
        case .worthKnowing: .worthKnowing
        case .noise: .noise
        }
    }
}
