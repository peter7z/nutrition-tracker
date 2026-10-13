import SwiftUI

struct AccountSection: View {
    @Environment(AccountSession.self) private var account
    @State private var confirmSignOut = false

    var body: some View {
        Section("Bocado account") {
            if account.session != nil {
                if let email = account.email { LabeledContent("Account", value: email) }
                else { Text("Signed in") }
                Text("Use this same account when connecting the ChatGPT plugin.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Sign out", role: .destructive) { confirmSignOut = true }
                    .disabled(account.isWorking)
                    .accessibilityIdentifier("account.signout")
            }
            if account.isWorking { ProgressView() }
            if let error = account.errorKey { Text(LocalizedStringKey(error)).foregroundStyle(.red) }
        }
        .task {
            await account.refreshProfile()
        }
        .alert("Sign out of Bocado?", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) { Task {
                await account.signOut()
            } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your account and server history are kept. Apple Health stays on this device.") }
    }
}
