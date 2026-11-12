import SwiftUI

if CommandLine.arguments.dropFirst().first == "--browser-native-host" {
    Task { @MainActor in exit(await BrowserNativeHost.run()) }
    dispatchMain()
} else if CommandLine.arguments.contains("--engine-self-test") {
    #if DEBUG
    Task { @MainActor in await EngineSelfTest.run() }
    dispatchMain()
    #else
    fputs("Integration self-tests are available only in debug builds.\n", stderr)
    exit(64)
    #endif
} else {
    ExtremeDownloadManagerApp.main()
}
