import Foundation
import TokenStatCore

extension CoreChecks {
    static func gatewayChecks() throws {
        let text = #"""
        model_provider = "corp"
        model = "example-model"
        api_key = "fixture-secret-do-not-copy"
        [model_providers.corp]
        base_url = "https://gateway.example/airoute"
        wire_api = "responses"
        experimental_bearer_token = "fixture-private-token"
        [model_providers.local]
        base_url = 'http://localhost:1234/v1'
        wire_api = "chat"
        """#
        let found = GatewayDiscovery.codexCandidates(text, source: "fixture")
        check(found.count == 2 && found.first?.isActive == true, "discover active provider first")
        check(found.first?.endpoint == "https://gateway.example/airoute/responses", "preserve enterprise base path without inventing v1")
        check(found.first?.model == "example-model" && found.last?.model == "", "model belongs to selected provider only")
        check(GatewayDiscovery.originKey(found.first!.endpoint) == "https://gateway.example:443",
            "route verification reduces a provider endpoint to its credential-free origin")
        check(GatewayDiscovery.originKey("https://user:password@gateway.example/v1") == nil,
            "route origin matching rejects embedded credentials")
        var config = AppConfiguration(); config.endpoint = found[0].endpoint
        let mappedResponses = try config.upstreamURL(for: "/v1/responses")
        check(mappedResponses.absoluteString == "https://gateway.example/airoute/responses", "Responses proxy preserves non-v1 upstream")
        let mappedChat = try config.upstreamURL(for: "/v1/chat/completions")
        check(mappedChat.path == "/airoute/chat/completions", "Chat mapping preserves non-v1 upstream")
        _ = try config.validated()
        let profile = text + "\n[profiles.work]\nmodel_provider = \"local\"\nmodel = \"profile-model\"\n"
        let selected = GatewayDiscovery.codexCandidates("profile = \"work\"\n" + profile, source: "fixture")
        check(selected.first?.provider == "local" && selected.first?.model == "profile-model", "active profile overrides root model and provider")
        let bad = ["https://user:password@example.com/v1", "https://example.com/v1?api_key=fixture", "https://example.com/v1#fixture", "file:///tmp/config", "https://example.com/%0a/v1"]
        for url in bad {
            check(GatewayDiscovery.candidate(baseURL: url, provider: "fixture", source: "fixture") == nil, "reject credential-bearing or invalid discovery URL")
        }
        let duplicate = text + "\n[model_providers.corp]\nbase_url = \"https://other.example/v1\"\n"
        check(!GatewayDiscovery.codexCandidates(duplicate, source: "fixture").contains { $0.provider == "corp" }, "ambiguous duplicate base URL not imported")
        let embedded = "instructions = \"\"\"\n[model_providers.fake]\nbase_url = \"https://fake.example/v1\"\n\"\"\"\n" + text
        check(GatewayDiscovery.codexCandidates(embedded, source: "fixture").count == 2, "multiline instruction content never becomes provider config")
        let env = GatewayDiscovery.environmentCandidates(["OPENAI_BASE_URL":"https://example.com/v1", "OPENAI_API_KEY":"fixture-secret", "OLLAMA_HOST":"127.0.0.1:11434"])
        check(env.count == 2 && env.last?.endpoint == "http://127.0.0.1:11434/api/chat", "allowlisted environment discovery and native Ollama endpoint")
        let encoded = try JSONEncoder().encode(found + env)
        let output = String(decoding: encoded, as: UTF8.self)
        check(!output.contains("fixture-secret") && !output.contains("private-token") && !output.contains("api_key"), "candidate model contains no authentication fields")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.toml")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let disk = GatewayDiscovery.readCodexConfig(at: file, source: "fixture")
        check(disk.count == 2, "bounded local file discovery")
        try String(repeating: "a", count: 1_048_577).write(to: file, atomically: true, encoding: .utf8)
        check(GatewayDiscovery.readCodexConfig(at: file, source: "fixture").isEmpty, "oversized discovery file refused")
    }
}
