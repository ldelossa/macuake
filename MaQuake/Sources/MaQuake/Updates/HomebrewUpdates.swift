/// This fork is updated only through its checksum-pinned Homebrew cask.
/// Keeping this policy stateless leaves existing user update preferences intact.
enum HomebrewUpdates {
    static let cask = "ldelossa/macuake/macuake"
    static let installCommand = "brew install --cask \(cask)"
    static let upgradeCommand = "brew upgrade --cask \(cask)"
}
