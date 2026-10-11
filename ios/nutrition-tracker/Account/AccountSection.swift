import SwiftUI
import AuthenticationServices

struct AccountSection: View {
    @Environment(AccountSession.self) private var account
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmSignOut = false

    var body: some View {
        Section("Nutrition Tracker account") {
            if account.session != nil {
                if let email = account.email { LabeledContent("Account", value: email) }
                else { Text("Signed in") }
                Text("Use this same account when connecting the ChatGPT plugin.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Sign out", role: .destructive) { confirmSignOut = true }.disabled(account.isWorking)
            } else {
                Text("Sign in with Apple to use the same account in iOS and ChatGPT. Existing accounts with the same verified email are linked automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email]
                    request.nonce = account.challenge?.nonce
                } onCompletion: { result in
                    Task {
                        await account.completeApple(result)
                        if account.session == nil { await account.prepareApple(clearError: false) }
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 48)
                .disabled(account.challenge == nil || account.isWorking)
                .accessibilityIdentifier("account.apple.signin")
                if account.errorKey != nil {
                    Button("Retry connection") { Task { await account.prepareApple() } }
                        .disabled(account.isWorking)
                }
            }
            if account.isWorking { ProgressView() }
            if let error = account.errorKey { Text(LocalizedStringKey(error)).foregroundStyle(.red) }
        }
        .task {
            if account.session == nil { await account.prepareApple() }
            else { await account.refreshProfile() }
        }
        .confirmationDialog("Sign out of Nutrition Tracker?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task {
                await account.signOut()
                if account.session == nil { await account.prepareApple() }
            } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your account and server history are kept. Apple Health stays on this device.") }
    }
}
