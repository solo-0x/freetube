import Foundation
import Combine
import WebKit
import OSLog

/// Captures cookies from the login web view and verifies them with YouTube before saving.
@available(iOS 17.0, *)
@MainActor
final class LoginCoordinator: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    enum State: Equatable {
        case idle, loading, awaitingCredentials, verifying, succeeded
        case failed(String)
    }
    @Published private(set) var state: State = .idle
    private var captureTask: Task<Void, Never>?
    private weak var loginWebView: WKWebView?
    private weak var observedCookieStore: WKHTTPCookieStore?
    private let session = SessionManager.shared
    private let service = AccountService()
    private var generation = 0
    private var lastFailure = ""
    private var presentNames: Set<String> = []

    static let startURL: URL = {
        var components = URLComponents(string: "https://accounts.google.com/ServiceLogin")!
        components.queryItems = [
            URLQueryItem(name: "service", value: "youtube"),
            URLQueryItem(name: "continue", value: "https://www.youtube.com/signin?action_handle_signin=true&next=%2F")
        ]
        return components.url!
    }()
    static let youTubeLandingURL = URL(string: "https://www.youtube.com/")!

    func observe(_ webView: WKWebView) {
        loginWebView = webView
        observedCookieStore = webView.configuration.websiteDataStore.httpCookieStore
        observedCookieStore?.add(self)
        state = .awaitingCredentials
    }

    func stopObserving() {
        generation += 1
        captureTask?.cancel()
        captureTask = nil
        observedCookieStore?.remove(self)
        observedCookieStore = nil
        loginWebView = nil
    }

    func resetState() {
        generation += 1
        captureTask?.cancel()
        captureTask = nil
        state = .awaitingCredentials
        lastFailure = ""
        loginWebView?.load(URLRequest(url: Self.startURL))
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            guard let self, let view = self.loginWebView else { return }
            self.handleNavigation(to: view.url, in: view)
        }
    }

    func handleNavigation(to url: URL?, in webView: WKWebView) {
        guard state != .succeeded, let host = url?.host?.lowercased() else { return }
        if case .failed = state { return }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            beginCapture(from: webView)
        } else if host == "myaccount.google.com" {
            webView.load(URLRequest(url: Self.youTubeLandingURL))
        }
    }

    /// User-driven verification never assumes that merely opening youtube.com means signed in.
    func completeLogin() {
        guard let view = loginWebView else { return }
        generation += 1
        captureTask?.cancel()
        captureTask = nil
        beginCapture(from: view, explicit: true)
    }

    private func beginCapture(from webView: WKWebView, explicit: Bool = false) {
        guard captureTask == nil, state != .succeeded else { return }
        let ticket = generation
        captureTask = Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            defer { if self.generation == ticket { self.captureTask = nil } }
            var lastCandidate: String?
            var attempts = 0
            // Waiting for credentials must leave the web page interactive.
            for _ in 0..<(explicit ? 3 : 60) {
                guard !Task.isCancelled, self.generation == ticket else { return }
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                guard !Task.isCancelled, self.generation == ticket else { return }
                self.presentNames = Set(cookies.filter {
                    let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return domain == "youtube.com" || domain == "www.youtube.com"
                }.map(\.name))
                if let header = CookieStore.shared.makeHeader(from: cookies, requireLegacySet: false) {
                    if lastCandidate != header { lastCandidate = header; attempts = 0 }
                    if attempts >= 3 {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        continue
                    }
                    attempts += 1
                    self.state = .verifying
                    do {
                        _ = try await self.service.validateSession(header: header)
                        guard !Task.isCancelled, self.generation == ticket else { return }
                        // Persist only a server-validated candidate, preserving the old session on failure.
                        do { try await self.session.signIn(with: header) }
                        catch {
                            self.state = .failed("登录已验证，但无法保存到钥匙串：\(error)")
                            return
                        }
                        self.state = .succeeded
                        return
                    } catch {
                        guard !Task.isCancelled, self.generation == ticket else { return }
                        if case YouTubeServiceError.notAuthenticated = error {
                            self.lastFailure = "YouTube 未认可当前会话，请在网页中完成登录后点击“完成登录”。"
                        } else {
                            self.lastFailure = "账号验证请求失败：\(error.localizedDescription)"
                        }
                        self.state = .awaitingCredentials
                    }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
            guard !Task.isCancelled, self.generation == ticket else { return }
            if explicit {
                let absent = CookieStore.requiredCookieNames.subtracting(self.presentNames).sorted().joined(separator: ", ")
                let detail = self.lastFailure.isEmpty ? "尚未读取到可验证的 YouTube 登录凭据。请确认网页“我”页面已显示账号。" : self.lastFailure
                let cookieDetail = absent.isEmpty
                    ? "传统 Cookie 名称均已读取，失败发生在账号接口验证阶段。"
                    : "未出现的传统 Cookie 名称（仅诊断）：\(absent)"
                self.state = .failed("\(detail)\n\(cookieDetail)")
            } else {
                self.state = .awaitingCredentials
            }
        }
    }

    static func clearWebData() async {
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
        )
    }
}
