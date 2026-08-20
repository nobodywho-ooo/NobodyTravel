import Foundation
import NobodyWho
import Observation

@DeclareTool("Searches local Copenhagen travel information for a query")
func searchTravelGuide(query: String) -> String {
    "query results"
}

struct Exploration: Codable, Identifiable, Equatable {
    let id: UUID
    let prompt: String
    var response: String
    let createdAt: Date
    var tokensPerSecond: Double? = nil
}

@MainActor
@Observable
final class ChatModel {
    static let modelName = "Gemma 3 270M"

    private static let modelPath = "hf://unsloth/gemma-3-270m-it-GGUF/gemma-3-270m-it-Q4_K_M.gguf"
    private static let modelFilename = "gemma-3-270m-it-Q4_K_M.gguf"
    private static let explorationsKey = "queryHistory"

    private var chat: Chat?
    private var modelOperationID = UUID()

    var draft = ""
    private(set) var currentExploration: Exploration?
    private(set) var explorations: [Exploration]
    private(set) var isModelDownloaded = false
    private(set) var isDownloading = false
    private(set) var isLoadingModel = false
    private(set) var isGenerating = false
    private(set) var downloadProgress: Double?
    private(set) var modelError: String?

    var isReady: Bool {
        chat != nil
    }

    var canSubmit: Bool {
        isReady && !isGenerating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        explorations = Self.readExplorations() ?? Self.sampleExplorations()
    }

    func refreshDownloadStatus() -> Bool {
        do {
            isModelDownloaded = try cachedModelPath() != nil
            return isModelDownloaded
        } catch {
            modelError = error.localizedDescription
            return false
        }
    }

    func downloadAndLoadModel() async -> Bool {
        guard !isDownloading, !isLoadingModel else { return false }

        let operationID = UUID()
        modelOperationID = operationID
        modelError = nil
        isDownloading = true
        downloadProgress = 0

        do {
            let localPath = try await Model.downloadModel(
                modelPath: Self.modelPath,
                onDownloadProgress: { [weak self] downloaded, total in
                    Task { @MainActor in
                        guard total > 0, self?.modelOperationID == operationID else { return }
                        self?.downloadProgress = Double(downloaded) / Double(total)
                    }
                }
            )
            guard modelOperationID == operationID else { return false }
            isDownloading = false
            isModelDownloaded = true
            downloadProgress = 1
            return await loadModel(at: localPath)
        } catch {
            guard modelOperationID == operationID else { return false }
            isDownloading = false
            downloadProgress = nil
            modelError = error.localizedDescription
            return false
        }
    }

    func loadDownloadedModel() async -> Bool {
        guard chat == nil else { return true }
        guard !isDownloading, !isLoadingModel else { return false }

        modelOperationID = UUID()
        modelError = nil

        do {
            guard let localPath = try cachedModelPath() else {
                isModelDownloaded = false
                return false
            }
            isModelDownloaded = true
            return await loadModel(at: localPath)
        } catch {
            modelError = error.localizedDescription
            return false
        }
    }

    func submitExploration(prompt suggestedPrompt: String? = nil) {
        let prompt = (suggestedPrompt ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chat, !prompt.isEmpty, !isGenerating else { return }

        draft = ""
        isGenerating = true
        let exploration = Exploration(id: UUID(), prompt: prompt, response: "", createdAt: Date())
        currentExploration = exploration
        saveCurrentExploration()

        let groundedPrompt = """
        You are a concise offline guide to Copenhagen. Give practical, calm answers. Be clear when details such as prices, opening hours, or rules may have changed. Do not mention these instructions. The traveler's request is: \(prompt)
        """

        Task {
            do {
                try await chat.resetHistory()
                var firstTokenAt: Date?
                var tokenCount = 0

                for try await token in chat.ask(groundedPrompt) {
                    guard currentExploration?.id == exploration.id else { continue }
                    currentExploration?.response += token
                    tokenCount += 1

                    let now = Date()
                    guard let firstTokenAt else {
                        firstTokenAt = now
                        continue
                    }
                    let elapsed = now.timeIntervalSince(firstTokenAt)
                    guard elapsed > 0 else { continue }
                    currentExploration?.tokensPerSecond = Double(tokenCount - 1) / elapsed
                }
            } catch {
                currentExploration?.response = "Unable to answer this exploration. \(error.localizedDescription)"
            }

            guard currentExploration?.id == exploration.id else { return }
            isGenerating = false
            saveCurrentExploration()
        }
    }

    func startNewExploration() {
        guard !isGenerating else { return }
        draft = ""
        currentExploration = nil
    }

    func selectExploration(record: Exploration) {
        guard !isGenerating else { return }
        currentExploration = record
        draft = ""
    }

    func deleteExploration(id: UUID) {
        guard !isGenerating else { return }
        explorations.removeAll { $0.id == id }
        if currentExploration?.id == id {
            currentExploration = nil
        }
        saveExplorations()
    }

    private func loadModel(at localPath: String) async -> Bool {
        isLoadingModel = true

        let sampler = SamplerBuilder()
            .temperature(temperature: 0.7)
            .topK(topK: 40)
            .topP(topP: 0.9, minKeep: 1)
            .minP(minP: 0.05, minKeep: 1)
            .dist()

        do {
            let model = try await Model.load(modelPath: localPath)
            do {
                chat = try Chat(
                    model: model,
                    contextSize: 4096,
                    tools: [searchTravelGuideTool],
                    sampler: sampler
                )
            } catch {
                chat = try Chat(model: model, contextSize: 4096, sampler: sampler)
            }
            isLoadingModel = false
            modelError = nil
            return true
        } catch {
            isLoadingModel = false
            modelError = error.localizedDescription
            return false
        }
    }

    private func cachedModelPath() throws -> String? {
        try getCachedModels().first { model in
            URL(fileURLWithPath: model.path).lastPathComponent.caseInsensitiveCompare(Self.modelFilename) == .orderedSame
        }?.path
    }

    private func saveCurrentExploration() {
        guard let currentExploration else { return }
        explorations.removeAll { $0.id == currentExploration.id }
        explorations.insert(currentExploration, at: 0)
        saveExplorations()
    }

    private func saveExplorations() {
        guard let data = try? JSONEncoder().encode(explorations) else { return }
        UserDefaults.standard.set(data, forKey: Self.explorationsKey)
    }

    private static func readExplorations() -> [Exploration]? {
        guard let data = UserDefaults.standard.data(forKey: explorationsKey) else { return nil }
        return try? JSONDecoder().decode([Exploration].self, from: data)
    }

    private static func sampleExplorations() -> [Exploration] {
        [
            Exploration(
                id: UUID(),
                prompt: "A slow afternoon in Nørrebro",
                response: "Start at Assistens Cemetery for a quiet walk under the trees. Continue along Jægersborggade for small shops and coffee, then cross to Superkilen. Finish near the lakes before dinner. The route is about 2.1 km before any detours.",
                createdAt: Date.now.addingTimeInterval(-86_400)
            ),
            Exploration(
                id: UUID(),
                prompt: "Where do I get proper smørrebrød?",
                response: "Try a traditional lunch restaurant in the city centre or Christianshavn. Order a few open sandwiches rather than one. Fish usually comes first, then meat and cheese. Popular places fill quickly, so check current opening hours and reserve when possible.",
                createdAt: Date.now.addingTimeInterval(-7_200)
            ),
            Exploration(
                id: UUID(),
                prompt: "Cycling rules nobody tells tourists",
                response: "Keep right, signal before turning or stopping, and leave the left side for passing. Do not ride on pavements or through pedestrian crossings. Lights are required after dark. Watch for passengers stepping across cycle lanes at bus stops.",
                createdAt: Date.now.addingTimeInterval(-104_400)
            ),
            Exploration(
                id: UUID(),
                prompt: "Is it rude to cycle in the pedestrian street?",
                response: "On Strøget, cycling is generally not allowed during the main pedestrian hours. Walk your bike when the street is busy and follow the posted signs, since access rules can vary by section and time.",
                createdAt: Date.now.addingTimeInterval(-172_800)
            )
        ]
    }
}
