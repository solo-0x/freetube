import Foundation
import Observation

@available(iOS 17.0, *)
@Observable
@MainActor
final class AccountViewModel {
    private(set) var info: AccountInfo?
    private(set) var isLoading: Bool = false
    var errorState: ErrorState?
    private(set) var sessionRejected = false

    private let service: any AccountServicing
    private let session: SessionManager

    init(
        service: any AccountServicing = AccountService(),
        session: SessionManager = .shared
    ) {
        self.service = service
        self.session = session
    }

    func load() async {
        guard !isLoading else { return }
        guard case .loggedIn = AuthState.shared.status else {
            info = nil
            sessionRejected = false
            return
        }
        isLoading = true
        sessionRejected = false
        errorState = nil
        defer { isLoading = false }
        do {
            info = try await service.fetchAccountInfo()
        } catch YouTubeServiceError.notAuthenticated {
            info = nil
            sessionRejected = true
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func signOut() async {
        await session.signOut()
        await LoginCoordinator.clearWebData()
        info = nil
    }
}
