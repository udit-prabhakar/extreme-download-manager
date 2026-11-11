import SwiftUI

if CommandLine.arguments.dropFirst().first == "--browser-native-host" {
    Task { @MainActor in exit(await BrowserNativeHost.run()) }
    dispatchMain()
} else if CommandLine.arguments.contains("--engine-self-test") {
    Task { @MainActor in await EngineSelfTest.run() }
    dispatchMain()
} else {
    ExtremeDownloadManagerApp.main()
}
