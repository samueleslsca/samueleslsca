#if os(macOS)
import Foundation
import NetScopeCore

// `NetScopePro --self-test` runs the real system tools once and prints what the parsers extracted.
// Used to validate parsers against genuine macOS output (CI, or a user's Mac) without launching the UI.
if CommandLine.arguments.contains("--self-test") {
    SelfTest.run()
    exit(0)
}
NetScopeProApp.main()
#else
print("NetScope Pro est une application macOS. Sur cette plateforme, seul le module NetScopeCore est disponible (swift test).")
#endif
