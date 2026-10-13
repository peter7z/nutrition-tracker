import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @Environment(AccountSession.self) private var account
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 20) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(Color("NutritionGreen"))
                        .frame(width: 100, height: 100)
                        .background(Color("NutritionGreen").opacity(0.12), in: RoundedRectangle(cornerRadius: 30))
                        .accessibilityHidden(true)
                    Text(verbatim: "Bocado Log")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Your nutrition, day by day.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                VStack(spacing: 16) {
                    Text("Sign in to get started")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Keep your food diary and progress together. Use the same account in Bocado Log and ChatGPT.")
                        .foregroundStyle(.secondary)
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
                    .id(colorScheme)
                    .frame(height: 54)
                    .disabled(account.challenge == nil || account.isWorking)
                    .accessibilityIdentifier("account.apple.signin")
                    if account.isWorking { ProgressView("Connecting…") }
                    if let error = account.errorKey {
                        Text(LocalizedStringKey(error)).foregroundStyle(.red)
                            .accessibilityIdentifier("login.error")
                        Button("Retry connection") { Task { await account.prepareApple() } }
                            .disabled(account.isWorking)
                            .accessibilityIdentifier("login.retry")
                    }
                }
                Text("Apple Health data stays on this device unless you enable sharing in Settings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(28).padding(.vertical, 48)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("login.screen")
        .task { await account.prepareApple(clearError: false) }
    }
}
