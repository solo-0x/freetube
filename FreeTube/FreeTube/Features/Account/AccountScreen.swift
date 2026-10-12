import SwiftUI
import Kingfisher

@available(iOS 17.0, *)
struct AccountScreen: View {
    @State private var model = AccountViewModel()
    @State private var showingLogin = false
    @State private var auth = AuthState.shared

    var body: some View {
        NavigationStack {
            List {
                if let info = model.info {
                    Section {
                        HStack(spacing: 12) {
                            KFImage(info.avatarURL)
                                .thumbnail(size: CGSize(width: 64, height: 64)) {
                                    Circle().fill(.gray.opacity(0.2))
                                }
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(Circle())

                            VStack(alignment: .leading) {
                                Text(info.displayName).font(.headline)
                                if let handle = info.handle {
                                    Text(handle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            Task { await model.signOut() }
                        } label: {
                            Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } else if case .loggedIn = auth.status {
                    Section {
                        if model.isLoading {
                            ProgressView("正在验证登录状态…")
                        } else if model.sessionRejected {
                            Label("登录验证未通过", systemImage: "exclamationmark.circle")
                            Text("会话已保存，但 YouTube 未认可当前会话，请重试验证或重新登录。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("重新登录") { showingLogin = true }
                        } else {
                            Label("登录会话已保存", systemImage: "person.crop.circle.badge.checkmark")
                            Text("账号资料暂未加载成功，请重试。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("重新加载账号资料") { Task { await model.load() } }
                            .disabled(model.isLoading)
                        Button("退出登录", role: .destructive) { Task { await model.signOut() } }
                    }
                } else {
                    Section {
                        Button {
                            showingLogin = true
                        } label: {
                            Label("Sign in to YouTube", systemImage: "person.crop.circle.badge.plus")
                        }
                    } footer: {
                        Text("FreeTube uses a `WKWebView` to capture cookies. They are stored only in the Keychain.")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task { await SessionManager.shared.handleExpiredSession() }
                    } label: {
                        Label("Reset session", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("If videos stop loading, tap this to wipe stored cookies and the visitor token. The next playback attempt will run anonymously.")
                }

                Section {
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
            .navigationTitle("Account")
            .task { await model.load() }
            .onChange(of: auth.status) { _, _ in
                Task { await model.load() }
            }
            .sheet(isPresented: $showingLogin) {
                LoginScreen()
                    .onDisappear { Task { await model.load() } }
            }
            .errorToast(Bindable(model).errorState)
        }
    }
}
