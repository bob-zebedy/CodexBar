import ServiceManagement
import Testing

struct LoginItemSettingsTests {
    @Test(arguments: [SMAppService.Status.enabled, .requiresApproval, .notRegistered])
    func successfulRegistrationUsesActualAuthorization(_ result: SMAppService.Status) {
        var status: SMAppService.Status = .notRegistered
        let settings = LoginItemSettings(
            readStatus: { status },
            register: { status = result },
            unregister: { status = .notRegistered }
        )
        settings.setEnabled(true)
        #expect(settings.isEnabled == (result == .enabled))
        #expect(settings.requiresApproval == (result == .requiresApproval))
        #expect(settings.errorMessage == nil)
        settings.setEnabled(false)
        #expect(!settings.isEnabled)
        #expect(!settings.requiresApproval)
    }

    @Test(arguments: [false, true])
    func failedChangeUsesSystemState(_ enabled: Bool) {
        enum Failure: Error { case rejected }
        let status: SMAppService.Status = enabled ? .notRegistered : .enabled
        let settings = LoginItemSettings(
            readStatus: { status },
            register: { throw Failure.rejected },
            unregister: { throw Failure.rejected }
        )
        settings.refresh()

        settings.setEnabled(enabled)

        #expect(settings.isEnabled == !enabled)
        #expect(settings.errorMessage != nil)
    }

    @Test func refreshFollowsExternalChangesAndDoesNotTreatApprovalAsEnabled() {
        var status: SMAppService.Status = .notRegistered
        let settings = LoginItemSettings(
            readStatus: { status },
            register: { Issue.record("Refresh must not register the login item") },
            unregister: { Issue.record("Refresh must not unregister the login item") }
        )

        for state: SMAppService.Status in [.notRegistered, .enabled, .requiresApproval, .enabled, .notFound] {
            status = state
            settings.refresh()
            #expect(settings.isEnabled == (state == .enabled))
            #expect(settings.requiresApproval == (state == .requiresApproval))
        }
    }

    @Test func registrationErrorWhileAwaitingApprovalUsesAuthorizationStatus() {
        var status: SMAppService.Status = .notRegistered
        let settings = LoginItemSettings(
            readStatus: { status },
            register: {
                status = .requiresApproval
                throw NSError(domain: SMAppServiceErrorDomain, code: 1)
            },
            unregister: { status = .notRegistered }
        )

        settings.setEnabled(true)
        #expect(!settings.isEnabled)
        #expect(settings.requiresApproval)
        #expect(settings.errorMessage == nil)

        status = .enabled
        settings.refresh()
        #expect(settings.isEnabled)
        #expect(!settings.requiresApproval)
        #expect(settings.errorMessage == nil)
    }

    @Test func externalAuthorizationClearsPreviousRegistrationFailure() {
        var status: SMAppService.Status = .notRegistered
        let settings = LoginItemSettings(
            readStatus: { status },
            register: { throw NSError(domain: SMAppServiceErrorDomain, code: 1) },
            unregister: { status = .notRegistered }
        )

        settings.setEnabled(true)
        #expect(settings.errorMessage != nil)

        status = .enabled
        settings.refresh()
        #expect(settings.isEnabled)
        #expect(settings.errorMessage == nil)
    }
}
