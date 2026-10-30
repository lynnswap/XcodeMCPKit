import Foundation
import Testing
@testable import XcodeMCPNativeRuntime
import XcodeMCPWire

@Suite
struct NativeApplicationLaunchTests {
    @Test(arguments: [false, true]) func onlyASuccessfulLaunchCanContinue(failed: Bool) {
        let output = JSONValue.object([
            "buildErrors": .array(failed ? [.string("build failed")] : []),
            "processIdentifier": .number(.int(42)),
        ])
        #expect(NativeApplicationLaunch.processIdentifier(in: .succeeded(output)) == (failed ? nil : 42))
        #expect(NativeApplicationLaunch.processIdentifier(in: .failed) == nil)
    }

    @Test(arguments: [Int64(0), -1, Int64(Int32.max) + 1]) func invalidLaunchPIDsDoNotChangeCleanup(pid: Int64) {
        #expect(NativeApplicationLaunch.processIdentifier(in: .succeeded(.object([
            "buildErrors": .array([]), "processIdentifier": .number(.int(pid)),
        ]))) == nil)
    }

    @Test func onlyAStoppedUntracedAppInTheSelectedSimulatorCanResume() {
        let device = UUID()
        var process = NativeApplicationLaunch.ProcessSnapshot(
            executable: "/a/custom/device/set/\(device)/data/Containers/Bundle/Application/\(UUID())/Fixture.app/Fixture",
            startedSeconds: 10, startedMicroseconds: 0, stopped: true, traced: false)
        #expect(process.canResume(in: device))
        #expect(!process.canResume(in: UUID()))
        process.traced = true
        #expect(!process.canResume(in: device))
        process.traced = false
        process.stopped = false
        #expect(!process.canResume(in: device))
        process.stopped = true
        process.executable = "/Applications/Fixture.app/Contents/MacOS/Fixture"
        #expect(!process.canResume(in: device))
    }
}
