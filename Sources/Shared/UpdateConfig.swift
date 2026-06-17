import Foundation

let defaultStayAwakeGitHubRepository = "Elevated-Technologies-LLC/stayawake"
let defaultStayAwakeUpdateRepository = "Elevated-Technologies-LLC/stayawake-updates"

private func cleanStayAwakeValue(_ value: String?) -> String? {
    let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func cleanStayAwakeBaseURL(_ value: String?) -> String? {
    guard let trimmed = cleanStayAwakeValue(value) else {
        return nil
    }
    return trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
}

func stayAwakeGitHubRepository(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    cleanStayAwakeValue(env["STAYAWAKE_GITHUB_REPOSITORY"])
    ?? cleanStayAwakeValue(env["STAYAWAKE_GITHUB_REPO"])
    ?? defaultStayAwakeGitHubRepository
}

func stayAwakeUpdateRepository(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let explicit = cleanStayAwakeValue(env["STAYAWAKE_UPDATE_REPOSITORY"])
        ?? cleanStayAwakeValue(env["STAYAWAKE_UPDATE_REPO"]) {
        return explicit
    }
    let repository = stayAwakeGitHubRepository(env: env)
    if repository == defaultStayAwakeGitHubRepository {
        return defaultStayAwakeUpdateRepository
    }
    return repository
}

func stayAwakeUpdateAssetBaseURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    let baseURL = cleanStayAwakeBaseURL(env["STAYAWAKE_UPDATE_ASSET_BASE_URL"])
    ?? "https://github.com/\(stayAwakeUpdateRepository(env: env))/releases/latest/download"
    guard let url = URL(string: baseURL) else {
        fatalError("Invalid StayAwake update asset base URL: \(baseURL)")
    }
    return url
}

func stayAwakeUpdateManifestURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if let explicit = cleanStayAwakeValue(env["STAYAWAKE_UPDATE_MANIFEST_URL"]) {
        guard let url = URL(string: explicit) else {
            fatalError("Invalid StayAwake update manifest URL: \(explicit)")
        }
        return url
    }
    return stayAwakeUpdateAssetBaseURL(env: env).appendingPathComponent("stayawake-manifest.json")
}

func stayAwakeInstallerManifestURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if let explicit = cleanStayAwakeValue(env["STAYAWAKE_INSTALLER_MANIFEST_URL"]) {
        guard let url = URL(string: explicit) else {
            fatalError("Invalid StayAwake installer manifest URL: \(explicit)")
        }
        return url
    }
    return stayAwakeUpdateAssetBaseURL(env: env).appendingPathComponent("stayawake-installer-manifest.json")
}
