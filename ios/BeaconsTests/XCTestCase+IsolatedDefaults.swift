import XCTest

extension XCTestCase {
    /// A throwaway UserDefaults suite, empty now and removed when the current test ends, so a
    /// test never reads or writes the install's own store.
    func isolatedDefaults() -> UserDefaults {
        let name = "tech.beacons.tests.\(type(of: self)).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
