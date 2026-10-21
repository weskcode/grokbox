import Foundation
import Testing
@testable import GrokboxCore

@Suite(.serialized)
struct AIQualityEvalTests {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["GROKBOX_AI_EVAL"] == "1" }

    enum Outcome: String, Codable { case pass, fail, unresolved }

    struct RunRecord: Codable {
        var outcome: Outcome
        var label: String?
        var action: String?
        var deadline: String?
        var summary: String?
        var problems: [String]
    }

    struct CaseRecord: Codable {
        var id: String
        var theme: String
        var task: String
        var runs: [RunRecord]
        var outcome: Outcome
    }

    struct Report: Codable {
        var backend: String
        var status: String
        var unavailableReason: String?
        var configuration: [String: String]
        var corpusRevision: String
        var corpusDigest: String
        var runsPerCase: Int
        var startedAt: Date
        var cases: [CaseRecord]
        var passed: Int
        var failed: Int
        var unresolved: Int
    }

    @Test(.enabled(if: AIQualityEvalTests.isEnabled), .timeLimit(.minutes(90)))
    func realBackendsReadTheCorpusSafely() async throws {
        let env = ProcessInfo.processInfo.environment
        let runs = max(1, Int(env["GROKBOX_AI_EVAL_RUNS"] ?? "") ?? 3)
        let outDirectory = env["GROKBOX_AI_EVAL_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let outDirectory { try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true) }

        var reports: [Report] = []
        if #available(macOS 26.0, *) {
            reports.append(try await evaluate(FoundationModelsProvider(), configuration: Self.appleConfiguration(), runs: runs))
        }
        let tags = (env["GROKBOX_AI_EVAL_OLLAMA_MODELS"] ?? OllamaProvider.defaultModel)
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for tag in tags {
            reports.append(try await evaluate(OllamaProvider(model: tag), configuration: await Self.ollamaConfiguration(tag: tag), runs: runs))
        }

        for report in reports {
            print(Self.summary(of: report))
            if let outDirectory { try Self.write(report, to: outDirectory) }
            if report.failed > 0 {
                Issue.record("\(report.backend): \(report.failed) of \(report.cases.count) cases failed; see the report")
            }
        }
    }

    // MARK: - Running

    private func evaluate(_ model: any TextModel, configuration: [String: String], runs: Int) async throws -> Report {
        var report = Report(backend: model.name, status: "ran", unavailableReason: nil, configuration: configuration,
                            corpusRevision: AIQualityCorpus.revision, corpusDigest: AIQualityCorpus.digest,
                            runsPerCase: runs, startedAt: Date(), cases: [], passed: 0, failed: 0, unresolved: 0)
        if case .unavailable(let reason) = await ModelRegistry.probe(model) {
            report.status = "inconclusive"
            report.unavailableReason = reason
            return report
        }

        for c in AIQualityCorpus.reads {
            var records: [RunRecord] = []
            for _ in 0..<runs {
                do {
                    let result = try await model.read(c.request)
                    let problems = AIQualityCorpus.problems(in: result, for: c)
                    records.append(RunRecord(outcome: problems.isEmpty ? .pass : .fail, label: result.importance.rawValue,
                                             action: result.actionType.rawValue, deadline: result.dueHint,
                                             summary: result.summary, problems: problems))
                } catch {
                    records.append(RunRecord(outcome: .unresolved, label: nil, action: nil, deadline: nil, summary: nil,
                                             problems: ["no reading: \(error.localizedDescription)"]))
                }
            }
            report.cases.append(CaseRecord(id: c.id, theme: c.theme.rawValue, task: "read", runs: records, outcome: Self.worst(records)))
        }

        for c in AIQualityCorpus.categorizations {
            var records: [RunRecord] = []
            for _ in 0..<runs {
                do {
                    let result = try await model.categorize(c.request)
                    let problems = AIQualityCorpus.problems(in: result, for: c)
                    records.append(RunRecord(outcome: problems.isEmpty ? .pass : .fail, label: result.category.rawValue,
                                             action: nil, deadline: nil, summary: result.reason, problems: problems))
                } catch {
                    records.append(RunRecord(outcome: .unresolved, label: nil, action: nil, deadline: nil, summary: nil,
                                             problems: ["no answer: \(error.localizedDescription)"]))
                }
            }
            report.cases.append(CaseRecord(id: c.id, theme: c.theme.rawValue, task: "categorize", runs: records, outcome: Self.worst(records)))
        }

        report.passed = report.cases.count(where: { $0.outcome == .pass })
        report.failed = report.cases.count(where: { $0.outcome == .fail })
        report.unresolved = report.cases.count(where: { $0.outcome == .unresolved })
        return report
    }

    private static func worst(_ runs: [RunRecord]) -> Outcome {
        if runs.contains(where: { $0.outcome == .fail }) { return .fail }
        if runs.contains(where: { $0.outcome == .unresolved }) { return .unresolved }
        return .pass
    }

    // MARK: - What the report records about the backend

    @available(macOS 26.0, *)
    private static func appleConfiguration() -> [String: String] {
        [
            "model": "Apple on-device foundation model (system-managed)",
            "modelVersion": "not exposed by the API; identified by the OS build below",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "decoding": "framework defaults (no temperature or seed set by Grokbox)",
            "output": "@Generable GeneratedRead / GeneratedCategory",
            "instructions": "ReaderPrompt.instructions / categorizeInstructions as shipped",
        ]
    }

    private static func ollamaConfiguration(tag: String) async -> [String: String] {
        var configuration: [String: String] = [
            "model": tag,
            "endpoint": OllamaProvider.defaultBaseURL.absoluteString,
            "decoding": "server defaults (Grokbox sets no options)",
            "output": "format=json, schema described in the prompt",
            "instructions": "ReaderPrompt.instructions / categorizeInstructions as shipped",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        struct Tags: Decodable {
            struct Entry: Decodable {
                struct Details: Decodable { var parameter_size: String?; var quantization_level: String? }
                var name: String
                var digest: String?
                var details: Details?
            }
            var models: [Entry]
        }
        var request = URLRequest(url: OllamaProvider.defaultBaseURL.appending(path: "api/tags"))
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let tags = try? JSONDecoder().decode(Tags.self, from: data),
              let entry = tags.models.first(where: { $0.name == tag || $0.name.hasPrefix(tag + ":") }) else {
            configuration["metadata"] = "unavailable: Ollama did not list this model"
            return configuration
        }
        configuration["installedName"] = entry.name
        configuration["digest"] = entry.digest
        configuration["parameterSize"] = entry.details?.parameter_size
        configuration["quantization"] = entry.details?.quantization_level
        return configuration
    }

    // MARK: - Output

    private static func summary(of report: Report) -> String {
        var lines = ["AI quality eval: \(report.backend) [\(report.status)] corpus \(report.corpusRevision) (\(report.corpusDigest.prefix(12)))"]
        if let reason = report.unavailableReason { lines.append("  unavailable: \(reason)") }
        if report.status == "ran" {
            lines.append("  \(report.passed) pass, \(report.failed) fail, \(report.unresolved) unresolved of \(report.cases.count) cases x \(report.runsPerCase) runs")
            for c in report.cases where c.outcome != .pass {
                let why = c.runs.flatMap(\.problems).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                lines.append("  \(c.outcome.rawValue.uppercased()) \(c.id): \(why.joined(separator: "; "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func write(_ report: Report, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let slug = report.backend.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        try encoder.encode(report).write(to: directory.appending(path: "ai-eval-\(slug).json"), options: .atomic)
    }
}
