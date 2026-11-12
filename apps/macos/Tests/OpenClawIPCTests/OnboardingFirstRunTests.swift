import Foundation
import Testing
@testable import OpenClaw

@MainActor
struct OnboardingFirstRunTests {
    @Test func `automatic setup only selects a completely fresh installation`() {
        #expect(OnboardingFirstRun.isFresh(
            isUnconfigured: true, onboardingSeen: false, onboardingVersion: 0,
            configExists: false, hasRemoteSettings: false))
        #expect(!OnboardingFirstRun.isFresh(
            isUnconfigured: false, onboardingSeen: false, onboardingVersion: 0,
            configExists: false, hasRemoteSettings: false))
        for existing in 0..<4 {
            #expect(!OnboardingFirstRun.isFresh(
                isUnconfigured: true, onboardingSeen: existing == 0, onboardingVersion: existing == 1 ? 1 : 0,
                configExists: existing == 2, hasRemoteSettings: existing == 3))
        }
    }

    @Test func `first run presents each step before work and completes only after the dashboard loads`() async {
        var effects: [String] = []
        let fallback = await OnboardingFirstRun.run(
            reportProgress: { effects.append("show \($0)") },
            selectLocal: { effects.append("local") },
            prepareRuntime: { effects.append("runtime") },
            startGateway: { effects.append("start") },
            supportsAutomaticSetup: { effects.append("capability")
                return true
            },
            openDashboard: {
                #expect(!effects.contains("complete"))
                effects.append("dashboard loaded")
            },
            markComplete: { effects.append("complete") })
        #expect(fallback == nil)
        #expect(effects == [
            "show preparingRuntime", "local", "runtime", "show startingGateway", "start", "capability",
            "show openingDashboard", "dashboard loaded", "complete",
        ])
    }

    @Test(arguments: 0..<5)
    func `failures preserve unfinished onboarding and return to the relevant manual page`(failureStep: Int) async {
        struct Failure: LocalizedError {
            var errorDescription: String? {
                "Fixture setup failure"
            }
        }
        var completed = false
        var dashboardOpened = false
        let check: (Int) throws -> Void = { step in
            if step == failureStep { throw Failure() }
        }
        let fallback = await OnboardingFirstRun.run(
            selectLocal: { try check(0) },
            prepareRuntime: { try check(1) },
            startGateway: { try check(2) },
            supportsAutomaticSetup: { try check(3)
                return true
            },
            openDashboard: { try check(4)
                dashboardOpened = true
            },
            markComplete: { completed = true })
        #expect(!completed)
        #expect(!dashboardOpened)
        let expectedPages: [OnboardingFirstRun.Page] = [.connection, .runtime, .runtime, .connection, .aiSetup]
        #expect(fallback == .init(page: expectedPages[failureStep], message: "Fixture setup failure"))
    }

    @Test func `opening manual setup cancels the automatic handoff before completion`() async {
        let task = Task {
            var completed = false
            let fallback = await OnboardingFirstRun.run(
                selectLocal: {}, prepareRuntime: {}, startGateway: {},
                supportsAutomaticSetup: { true },
                openDashboard: { withUnsafeCurrentTask { $0?.cancel() } },
                markComplete: { completed = true })
            #expect(!completed)
            #expect(fallback?.page == .aiSetup)
        }
        await task.value
    }

    @Test func `older Gateways retain manual AI setup without a dashboard handoff`() async {
        var handoff = false
        var completed = false
        let fallback = await OnboardingFirstRun.run(
            selectLocal: {}, prepareRuntime: {}, startGateway: {},
            supportsAutomaticSetup: { false },
            openDashboard: { handoff = true },
            markComplete: { completed = true })
        #expect(fallback == .init(page: .aiSetup, message: nil))
        #expect(!handoff)
        #expect(!completed)
    }

    @Test func `joined claw finishes an unfinished first run into its dashboard`() {
        // Regression: a Mac joined over OpenClaw ID reopened setup on the AI page, whose
        // admin-only Gateway check its member key cannot pass, and Next stayed disabled.
        var events: [String] = []
        let applied = OnboardingFirstRun.finishJoinedClaw(
            joinedClaw: true,
            onboardingSeen: false,
            markComplete: { events.append("complete") },
            openDashboard: { events.append("dashboard") })
        #expect(applied)
        #expect(events == ["complete", "dashboard"])

        events = []
        #expect(OnboardingFirstRun.finishJoinedClaw(
            joinedClaw: true,
            onboardingSeen: true,
            markComplete: { events.append("complete") },
            openDashboard: { events.append("dashboard") }))
        #expect(events.isEmpty)
        #expect(!OnboardingFirstRun.finishJoinedClaw(
            joinedClaw: false,
            onboardingSeen: false,
            markComplete: { events.append("complete") },
            openDashboard: { events.append("dashboard") }))
        #expect(events.isEmpty)
    }

    @Test func `joined claw is only the remote primary the OpenClaw ID route serves`() {
        let serves: (URL) -> Bool = { $0.host == "claw.example" }
        #expect(MacOpenClawIDJoinCompletion.primaryIsJoinedClaw(
            mode: .remote, remoteUrl: "wss://claw.example", serves: serves))
        #expect(!MacOpenClawIDJoinCompletion.primaryIsJoinedClaw(
            mode: .remote, remoteUrl: "wss://other.example", serves: serves))
        #expect(!MacOpenClawIDJoinCompletion.primaryIsJoinedClaw(
            mode: .local, remoteUrl: "wss://claw.example", serves: serves))
    }

    @Test func `joined claw onboarding has no AI setup page`() {
        let aiSetup = OnboardingFirstRun.Page.aiSetup.rawValue
        #expect(!OnboardingView.pageOrder(for: .remote, requiresCLIInstall: false, joinedClaw: true)
            .contains(aiSetup))
        #expect(OnboardingView.pageOrder(for: .remote, requiresCLIInstall: false).contains(aiSetup))
    }

    @Test func `superseded dashboard open reads as reconnecting with OpenClaw ID guidance`() {
        // Regression: a joined Mac showed "Swift.CancellationError error 1" and SSH tunnel advice.
        let superseded = DashboardManager.failureCopy(error: CancellationError(), joinedClaw: true)
        #expect(superseded.title == "Reconnecting to the Gateway")
        #expect(!superseded.message.contains("CancellationError"))
        #expect(!superseded.detail.contains("Reset Remote Tunnel"))
        #expect(superseded.detail.contains("OpenClaw ID"))
        let failed = DashboardManager.failureCopy(error: URLError(.timedOut), joinedClaw: false)
        #expect(failed.title == "Dashboard unavailable")
        #expect(failed.detail.contains("Reset Remote Tunnel"))
    }

    @Test func `joining a claw closes setup before switching the primary, then opens the dashboard`() async {
        var events: [String] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            MacOpenClawIDJoinCompletion.finish(
                claw: "claw.example",
                markOnboardingComplete: { events.append("complete") },
                closeOnboarding: { events.append("close") },
                selectPrimary: { events.append("primary:\($0)") },
                refreshEndpoint: { events.append("refresh") },
                openDashboard: {
                    events.append("dashboard")
                    done.resume()
                })
        }
        #expect(events == ["complete", "close", "primary:claw.example", "refresh", "dashboard"])
    }
}
