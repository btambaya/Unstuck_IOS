import SwiftUI
import UnstuckDesign

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    var body: some View {
        Group {
            if !model.configured {
                ConfigNeededView()
            } else if !model.signedIn {
                AuthView()
            } else if !model.onboarded {
                OnboardingView()
            } else {
                MainTabScaffold()
            }
        }
        .background(theme.palette.bg.ignoresSafeArea())
    }
}

/// Shown when SUPABASE_HOST / ANON_KEY aren't set (e.g. fresh checkout
/// before Secrets.xcconfig is filled in). Keeps the app launchable.
struct ConfigNeededView: View {
    @Environment(\.uTheme) private var theme
    var body: some View {
        VStack(spacing: 14) {
            Wordmark(size: 24)
            SectionLabel("Setup")
            Text("Add SUPABASE_HOST + SUPABASE_ANON_KEY to App/Secrets.xcconfig, then rebuild.")
                .font(UFont.sans(14))
                .foregroundStyle(theme.palette.ink2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.bg.ignoresSafeArea())
    }
}
