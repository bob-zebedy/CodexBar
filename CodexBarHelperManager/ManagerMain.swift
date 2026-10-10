import Foundation
import ServiceManagement

@main
enum HelperManagerMain {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 2,
              let command = HelperManagement.Command(rawValue: arguments[1]) else {
            return
        }
        let service = SMAppService.daemon(plistName: CodexBarHelperIPC.daemonPlistName)
        var failure: NSError?
        do {
            switch command {
            case .status:
                break
            case .register:
                try service.register()
            case .unregister:
                try await service.unregister()
            }
        } catch {
            failure = error as NSError
        }
        let reply = HelperManagement.Reply(
            status: service.status.rawValue,
            errorDomain: failure?.domain,
            errorCode: failure?.code
        )
        if let data = try? JSONEncoder().encode(reply) {
            FileHandle.standardOutput.write(data)
        }
    }
}
