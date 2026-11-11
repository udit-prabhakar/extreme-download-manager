import SwiftUI

if CommandLine.arguments.contains("--engine-self-test") {
    Task { @MainActor in await EngineSelfTest.run() }
    dispatchMain()
} else {
    ExtremeDownloadManagerApp.main()
}
