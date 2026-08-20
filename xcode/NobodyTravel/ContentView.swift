import SwiftUI
import UIKit

private enum AppPhase {
    case welcome
    case city
    case guide
    case ready
    case loading
    case main
}

enum AppTheme {
    static let green = adaptive(light: 0x0E6B4E, dark: 0x0E6B4E)
    static let harbour = adaptive(light: 0x0A4E39, dark: 0x0B3D2F)
    static let mint = adaptive(light: 0xDCEFE4, dark: 0x15372C)
    static let paper = adaptive(light: 0xF5F3EE, dark: 0x111412)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1C211E)
    static let drawerEnd = adaptive(light: 0xEFF7F2, dark: 0x122A21)
    static let ink = adaptive(light: 0x15181A, dark: 0xF2F3F0)
    static let nobodyWhoYellow = Color(red: 1, green: 210 / 255, blue: 30 / 255)
    static let nobodyWhoInk = Color(red: 50 / 255, green: 52 / 255, blue: 61 / 255)
    static let secondary = ink.opacity(0.58)
    static let pagePadding: CGFloat = 22

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

struct ContentView: View {
    @AppStorage("hasCompletedModelSetup") private var hasCompletedModelSetup = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = AppPhase.welcome
    @State private var chatModel = ChatModel()
    @State private var hasRestoredSession = false

    var body: some View {
        ZStack {
            switch phase {
            case .welcome:
                WelcomeView {
                    changePhase(to: .city)
                }
            case .city:
                CitySetupView {
                    changePhase(to: .guide)
                }
            case .guide:
                GuideSetupView(chatModel: chatModel) {
                    Task {
                        let isReady = chatModel.isModelDownloaded
                            ? await chatModel.loadDownloadedModel()
                            : await chatModel.downloadAndLoadModel()
                        guard isReady else { return }
                        changePhase(to: .ready)
                    }
                }
            case .ready:
                ReadyView {
                    hasCompletedModelSetup = true
                    changePhase(to: .main)
                }
            case .loading:
                LoadingView()
            case .main:
                ExplorationHomeView(chatModel: chatModel)
            }
        }
        .foregroundStyle(AppTheme.ink)
        .task {
            await restoreSession()
        }
    }

    private func restoreSession() async {
        guard !hasRestoredSession else { return }
        hasRestoredSession = true
        guard hasCompletedModelSetup else { return }
        guard chatModel.refreshDownloadStatus() else {
            changePhase(to: .guide)
            return
        }

        changePhase(to: .loading)
        let isReady = await chatModel.loadDownloadedModel()
        changePhase(to: isReady ? .main : .guide)
    }

    private func changePhase(to newPhase: AppPhase) {
        let animation: Animation = reduceMotion ? .linear(duration: 0.1) : .smooth(duration: 0.38)
        withAnimation(animation) {
            phase = newPhase
        }
    }
}

private struct WelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        OnboardingPage(background: welcomeBackground, foreground: .white) {
            StatusPill(text: "Runs on this phone")

            Spacer()

            Text("Calm travelling, on device.")
                .font(.system(.largeTitle, design: .default, weight: .bold))
                .tracking(-1.1)
                .lineSpacing(-2)

            Text("The model lives on your phone. It works in the metro, on the harbour bus, and with roaming switched off.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.72))
                .lineSpacing(4)
                .padding(.top, 4)

            PrimaryButton(title: "Get started", style: .light, action: onContinue)
                .padding(.top, 12)
                .accessibilityIdentifier("onboarding.welcome.continueButton")

            BrandFooter(dark: true)
                .padding(.top, 16)
        }
    }

    private var welcomeBackground: some View {
        LinearGradient(
            colors: [AppTheme.green, AppTheme.harbour],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct CitySetupView: View {
    let onContinue: () -> Void

    var body: some View {
        OnboardingPage(background: AppTheme.green, foreground: .white) {
            Text("Step 1 of 3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))

            Text("Pick your city.")
                .font(.system(.largeTitle, design: .default, weight: .bold))
                .tracking(-1)
                .padding(.top, 8)

            Text("Copenhagen places, prices, transit, and etiquette stay on your phone.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.68))
                .lineSpacing(4)
                .padding(.top, 1)

            VStack(spacing: 9) {
                CityRow(letter: "K", city: "Copenhagen", detail: "Offline guide, 1,240 places", isSelected: true)

                VStack(spacing: 0) {
                    CityRow(letter: "S", city: "Stockholm")
                    CityRow(letter: "L", city: "Lisbon")
                    CityRow(letter: "B", city: "Berlin")
                    CityRow(letter: "T", city: "Tokyo")
                }
                .background(.white.opacity(0.09), in: .rect(cornerRadius: 17))
                .overlay {
                    RoundedRectangle(cornerRadius: 17)
                        .stroke(.white.opacity(0.14), lineWidth: 0.5)
                }
            }
            .padding(.top, 18)

            Spacer()

            SourceLine(imageName: "WikivoyageLogo", text: "Travel information from Wikivoyage", dark: true)

            PrimaryButton(title: "Continue", style: .light, action: onContinue)
                .accessibilityIdentifier("onboarding.city.continueButton")
        }
    }
}

private struct CityRow: View {
    let letter: String
    let city: String
    var detail: String?
    var isSelected = false

    var body: some View {
        HStack(spacing: 14) {
            Text(letter)
                .font(.headline)
                .frame(width: 38, height: 38)
                .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                .background(isSelected ? AppTheme.green : .white.opacity(0.12), in: .rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(city)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondary)
                }
            }
            .foregroundStyle(isSelected ? AppTheme.ink : .white.opacity(0.62))

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.green)
                    .accessibilityLabel("Selected")
            } else {
                Text("Soon")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .padding(.horizontal, 17)
        .frame(minHeight: isSelected ? 68 : 58)
        .background(isSelected ? Color.white : Color.clear, in: .rect(cornerRadius: 17))
        .accessibilityElement(children: .combine)
    }
}

private struct GuideSetupView: View {
    let chatModel: ChatModel
    let onDownload: () -> Void

    var body: some View {
        OnboardingPage(background: AppTheme.paper, foreground: AppTheme.ink) {
            Text("Step 2 of 3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondary)

            Text("Download your guide.")
                .font(.system(.largeTitle, design: .default, weight: .bold))
                .tracking(-1)
                .padding(.top, 8)

            Text("Gemma is compact, private, and ready for offline explorations of Copenhagen.")
                .font(.body)
                .foregroundStyle(AppTheme.secondary)
                .lineSpacing(4)
                .padding(.top, 1)

            ModelCard(chatModel: chatModel)
                .padding(.top, 20)

            if let modelError = chatModel.modelError {
                Label(modelError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("onboarding.model.error")
            }

            Spacer()

            SourceLine(imageName: "NobodyWhoLogo", text: "On-device inference by NobodyWho", dark: false)

            PrimaryButton(title: buttonTitle, style: .green, action: onDownload)
                .disabled(chatModel.isDownloading || chatModel.isLoadingModel)
                .opacity(chatModel.isDownloading || chatModel.isLoadingModel ? 0.55 : 1)
                .accessibilityIdentifier("onboarding.model.downloadButton")
        }
        .onAppear {
            _ = chatModel.refreshDownloadStatus()
        }
    }

    private var buttonTitle: String {
        if chatModel.modelError != nil {
            return "Try again"
        }
        if chatModel.isModelDownloaded {
            return "Prepare Gemma"
        }
        return "Download Gemma"
    }
}

private struct ModelCard: View {
    let chatModel: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Text("G")
                    .font(.headline)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.16), in: .rect(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text("The local")
                        .font(.headline)
                    Text("Gemma 3 270M, 4-bit")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.66))
                    Text("241 MB, text only")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.66))
                }

                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .accessibilityLabel("Selected")
            }

            if chatModel.isDownloading {
                ProgressView(value: chatModel.downloadProgress)
                    .tint(AppTheme.mint)
                Text(downloadLabel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            } else if chatModel.isLoadingModel {
                HStack(spacing: 9) {
                    ProgressView()
                        .tint(.white)
                    Text("Preparing Gemma")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
            } else {
                Label("Stored and run on this iPhone", systemImage: "iphone")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .foregroundStyle(.white)
        .padding(17)
        .background(AppTheme.green, in: .rect(cornerRadius: 17))
        .accessibilityElement(children: .contain)
    }

    private var downloadLabel: String {
        guard let progress = chatModel.downloadProgress else {
            return "Downloading Gemma"
        }
        return "Downloading Gemma, \(Int(progress * 100))%"
    }
}

private struct ReadyView: View {
    let onContinue: () -> Void

    var body: some View {
        OnboardingPage(background: readyBackground, foreground: .white) {
            StatusPill(text: "Copenhagen, ready offline")

            Spacer()

            Text("Turn on airplane mode. Go ahead.")
                .font(.system(.largeTitle, design: .default, weight: .bold))
                .tracking(-1.1)
                .lineSpacing(-2)

            Text("Welcome to calm travelling. Your guide and explorations stay on this phone.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
                .lineSpacing(4)
                .padding(.top, 3)

            HStack(spacing: 24) {
                Fact(value: "1,240", label: "sample places")
                Fact(value: "Offline", label: "answers")
                Fact(value: "0", label: "data sold")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
            .overlay(alignment: .top) { Divider().overlay(.white.opacity(0.18)) }
            .overlay(alignment: .bottom) { Divider().overlay(.white.opacity(0.18)) }
            .padding(.vertical, 8)

            PrimaryButton(title: "Start asking", style: .light, action: onContinue)
                .accessibilityIdentifier("onboarding.ready.continueButton")
        }
    }

    private var readyBackground: some View {
        LinearGradient(
            colors: [AppTheme.green, AppTheme.harbour],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct Fact: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.mint)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LoadingView: View {
    var body: some View {
        ZStack {
            AppTheme.paper.ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppTheme.green)
                Text("Preparing your offline guide")
                    .font(.headline)
                Text("Gemma stays on this device.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingPage<Background: View, Content: View>: View {
    let background: Background
    let foreground: Color
    @ViewBuilder let content: Content

    init(
        background: Background,
        foreground: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.background = background
        self.foreground = foreground
        self.content = content()
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 12)
        }
    }
}

private struct StatusPill: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.mint)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.white.opacity(0.13), in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.22), lineWidth: 0.5) }
            .accessibilityElement(children: .combine)
    }
}

private struct SourceLine: View {
    let imageName: String
    let text: String
    let dark: Bool

    var body: some View {
        HStack(spacing: 8) {
            LogoImage(name: imageName, size: 24)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(dark ? .white.opacity(0.62) : AppTheme.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
    }
}

private struct BrandFooter: View {
    let dark: Bool

    var body: some View {
        VStack(spacing: 10) {
            Text("Written by humans, served by yourself")
                .font(.caption)
                .foregroundStyle(dark ? .white.opacity(0.45) : AppTheme.secondary)

            HStack(spacing: 18) {
                BrandLink(
                    title: "Wikivoyage",
                    imageName: "WikivoyageLogo",
                    destination: URL(string: "https://en.wikivoyage.org/wiki/Copenhagen")!,
                    dark: dark
                )
                Divider()
                    .frame(height: 18)
                    .overlay(dark ? .white.opacity(0.25) : AppTheme.ink.opacity(0.15))
                BrandLink(
                    title: "NobodyWho",
                    imageName: "NobodyWhoLogo",
                    destination: URL(string: "https://www.nobodywho.ai")!,
                    dark: dark
                )
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BrandLink: View {
    let title: String
    let imageName: String
    let destination: URL
    let dark: Bool

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 7) {
                LogoImage(name: imageName, size: 25)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(dark ? .white.opacity(0.84) : AppTheme.ink)
        }
        .accessibilityLabel("Open \(title)")
    }
}

struct LogoImage: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

private enum PrimaryButtonStyle {
    case light
    case green
}

private struct PrimaryButton: View {
    let title: String
    let style: PrimaryButtonStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(style == .light ? AppTheme.harbour : .white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .background(style == .light ? Color.white : AppTheme.green, in: .rect(cornerRadius: 15))
        }
        .buttonStyle(PressButtonStyle())
    }
}

#Preview {
    ContentView()
}
