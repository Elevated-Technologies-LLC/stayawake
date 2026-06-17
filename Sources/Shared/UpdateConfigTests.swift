import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct StayAwakeUpdateConfigTests {
    static func main() {
        expect(stayAwakeGitHubRepository(env: [:]) == defaultStayAwakeGitHubRepository, "default source repo should stay on stayawake")
        expect(stayAwakeUpdateRepository(env: [:]) == defaultStayAwakeUpdateRepository, "default update repo should use the public updates repo")
        expect(
            stayAwakeUpdateManifestURL(env: [:]).absoluteString
                == "https://github.com/Elevated-Technologies-LLC/stayawake-updates/releases/latest/download/stayawake-manifest.json",
            "default manifest URL should point at the updates repo"
        )
        expect(
            stayAwakeInstallerManifestURL(env: [:]).absoluteString
                == "https://github.com/Elevated-Technologies-LLC/stayawake-updates/releases/latest/download/stayawake-installer-manifest.json",
            "default installer manifest URL should point at the updates repo"
        )

        let customSourceEnv = [
            "STAYAWAKE_GITHUB_REPOSITORY": "example/source"
        ]
        expect(stayAwakeUpdateRepository(env: customSourceEnv) == "example/source", "custom source repo should double as update repo when no explicit override is set")

        let explicitEnv = [
            "STAYAWAKE_GITHUB_REPOSITORY": "example/source",
            "STAYAWAKE_UPDATE_REPOSITORY": "example/updates"
        ]
        expect(stayAwakeUpdateRepository(env: explicitEnv) == "example/updates", "explicit update repo should win")
        expect(
            stayAwakeUpdateManifestURL(env: explicitEnv).absoluteString
                == "https://github.com/example/updates/releases/latest/download/stayawake-manifest.json",
            "explicit update repo should shape manifest URL"
        )

        let assetBaseEnv = [
            "STAYAWAKE_UPDATE_ASSET_BASE_URL": "https://updates.example.invalid/stayawake/"
        ]
        expect(
            stayAwakeUpdateManifestURL(env: assetBaseEnv).absoluteString
                == "https://updates.example.invalid/stayawake/stayawake-manifest.json",
            "custom base URL should trim trailing slash"
        )
        expect(
            stayAwakeInstallerManifestURL(env: [
                "STAYAWAKE_INSTALLER_MANIFEST_URL": "https://mirror.example.invalid/stayawake/stayawake-installer-manifest.json"
            ]).absoluteString
                == "https://mirror.example.invalid/stayawake/stayawake-installer-manifest.json",
            "explicit installer manifest URL should be used as-is"
        )

        print("StayAwake update config tests passed")
    }
}
