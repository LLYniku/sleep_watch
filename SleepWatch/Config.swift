import Foundation

enum AppConfig {
    // Fill these before running on a real watch.
    static let githubOwner = "GITHUB_OWNER_REPLACE_ME"
    static let githubRepo = "REPOSITORY_REPLACE_ME"
    static let githubBranch = "main"

    // Use a fine-grained GitHub token with Actions read/write and Contents read-only access to this repo.
    // Do not put the OpenAI API key here. The OpenAI key belongs in GitHub Secrets.
    static let githubToken = "GITHUB_TOKEN_REPLACE_ME"

    static let reportEncryptionKey = "BASE64_32_BYTE_KEY_REPLACE_ME"

    static let morningHour = 9
    static let morningMinute = 0
}
