import MarkdownUI
import SwiftUI
import UIKit

struct ExplorationHomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let chatModel: ChatModel
    @State private var isDrawerOpen = false
    @GestureState private var drawerDragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let safeAreaInsets = UIApplication.shared.keyWindowSafeAreaInsets
            let drawerWidth = min(geometry.size.width * 0.84, 360)
            let settledOffset = isDrawerOpen ? drawerWidth : 0
            let paneOffset = min(drawerWidth, max(0, settledOffset + drawerDragOffset))
            let drawerProgress = paneOffset / drawerWidth

            ZStack(alignment: .leading) {
                ExplorationDrawer(
                    chatModel: chatModel,
                    selectedExplorationID: chatModel.currentExploration?.id,
                    onSelect: { record in
                        chatModel.selectExploration(record: record)
                        setDrawer(open: false)
                    },
                    onDelete: { id in
                        chatModel.deleteExploration(id: id)
                    }
                )
                .padding(.top, safeAreaInsets.top)
                .padding(.bottom, safeAreaInsets.bottom)
                .frame(width: drawerWidth, height: geometry.size.height)
                .allowsHitTesting(isDrawerOpen)
                .accessibilityHidden(!isDrawerOpen)

                mainContent
                    .padding(.top, safeAreaInsets.top)
                    .padding(.bottom, safeAreaInsets.bottom)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(AppTheme.paper)
                    .clipShape(.rect(cornerRadius: 38 * drawerProgress))
                    .shadow(color: AppTheme.harbour.opacity(0.28 * drawerProgress), radius: 28 * drawerProgress, x: -8)
                    .offset(x: paneOffset)
                    .contentShape(Rectangle())
                    .simultaneousGesture(drawerGesture(width: drawerWidth))
                    .accessibilityHidden(isDrawerOpen)
            }
            .background(AppTheme.mint)
            .accessibilityAction(.escape) {
                if isDrawerOpen { setDrawer(open: false) }
            }
            .accessibilityAction(named: "Close explorations") {
                if isDrawerOpen { setDrawer(open: false) }
            }
        }
        .ignoresSafeArea()
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            ExplorationHeader(
                isGenerating: chatModel.isGenerating,
                onMenu: { setDrawer(open: true) },
                onNewExploration: { chatModel.startNewExploration() }
            )
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.vertical, 12)

            if let currentExploration = chatModel.currentExploration {
                ExplorationResultView(exploration: currentExploration, isGenerating: chatModel.isGenerating)
            } else {
                NewExplorationView(chatModel: chatModel)
            }
        }
    }

    private func drawerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($drawerDragOffset) { value, offset, _ in
                guard abs(value.translation.width) > abs(value.translation.height),
                      isDrawerOpen || value.startLocation.x < 28 else { return }
                offset = isDrawerOpen
                    ? min(0, max(-width, value.translation.width))
                    : min(width, max(0, value.translation.width))
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height),
                      isDrawerOpen || value.startLocation.x < 28 else { return }
                let projectedOffset = (isDrawerOpen ? width : 0) + value.predictedEndTranslation.width
                setDrawer(open: projectedOffset > width * 0.48)
            }
    }

    private func setDrawer(open: Bool) {
        let animation: Animation = reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.3, dampingFraction: 0.8)
        withAnimation(animation) {
            isDrawerOpen = open
        }
    }
}

private struct ExplorationHeader: View {
    let isGenerating: Bool
    let onMenu: () -> Void
    let onNewExploration: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SquareIconButton(icon: "line.3.horizontal", label: "Explorations", action: onMenu)
                .accessibilityIdentifier("exploration.header.menuButton")

            Spacer()

            Button(action: onNewExploration) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.green, in: .rect(cornerRadius: 12))
            }
            .buttonStyle(PressButtonStyle())
            .disabled(isGenerating)
            .opacity(isGenerating ? 0.45 : 1)
            .accessibilityLabel("New exploration")
            .accessibilityIdentifier("exploration.header.newButton")
        }
    }
}

private struct NewExplorationView: View {
    let chatModel: ChatModel

    private let suggestions = [
        "It is raining and I have four hours",
        "Best swim spot reachable by bike?"
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Godmorgen.")
                        .font(.system(.largeTitle, design: .default, weight: .bold))
                        .tracking(-1)

                    Text("Ask me anything about Copenhagen.")
                        .font(.body)
                        .foregroundStyle(AppTheme.secondary)
                        .padding(.top, 4)

                    Text("TRY ASKING")
                        .sectionLabel()
                        .padding(.top, 28)

                    VStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                chatModel.submitExploration(prompt: suggestion)
                            } label: {
                                Text(suggestion)
                                    .font(.body)
                                    .foregroundStyle(AppTheme.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(15)
                                    .background(AppTheme.surface, in: .rect(cornerRadius: 14))
                            }
                            .buttonStyle(PressButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }

            ExplorationInput(chatModel: chatModel)
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.bottom, 10)
        }
    }
}

private extension View {
    func sectionLabel() -> some View {
        font(.caption.weight(.semibold))
            .tracking(0.3)
            .foregroundStyle(AppTheme.secondary)
            .padding(.bottom, 10)
    }
}

private struct ExplorationInput: View {
    @Bindable var chatModel: ChatModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about Copenhagen", text: $chatModel.draft, axis: .vertical)
                .font(.body)
                .lineLimit(1...4)
                .frame(minHeight: 38)
                .submitLabel(.send)
                .onSubmit {
                    chatModel.submitExploration()
                }
                .accessibilityIdentifier("exploration.input.textField")

            Button {
                chatModel.submitExploration()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(chatModel.canSubmit ? AppTheme.green : Color.gray.opacity(0.4), in: Circle())
            }
            .buttonStyle(PressButtonStyle())
            .disabled(!chatModel.canSubmit)
            .accessibilityLabel("Start exploration")
            .accessibilityIdentifier("exploration.input.sendButton")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(AppTheme.surface, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AppTheme.ink.opacity(0.1), lineWidth: 0.5) }
        .shadow(color: AppTheme.ink.opacity(0.06), radius: 16, y: 6)
    }
}

private struct ExplorationResultView: View {
    let exploration: Exploration
    let isGenerating: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(exploration.prompt)
                    .font(.body)
                    .foregroundStyle(AppTheme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if exploration.response.isEmpty && isGenerating {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(AppTheme.green)
                        Text("Writing your answer")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondary)
                    }
                } else {
                    Markdown(exploration.response)
                        .textSelection(.enabled)
                }

                if !isGenerating && !exploration.response.isEmpty {
                    HStack {
                        if let speed = exploration.tokensPerSecond {
                            Text("\(Int(speed.rounded())) tok/s")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.secondary)
                        }

                        Spacer()

                        SquareIconButton(icon: "square.and.arrow.up", label: "Share answer", action: {})
                            .accessibilityIdentifier("exploration.result.shareButton")
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .accessibilityIdentifier("exploration.result.scrollView")
    }
}

private struct ExplorationDrawer: View {
    let chatModel: ChatModel
    let selectedExplorationID: UUID?
    let onSelect: (Exploration) -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Explorations")
                    .font(.system(.title, design: .default, weight: .bold))
                    .tracking(-0.8)
                Text("Saved on this device")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 20)

            List {
                if chatModel.explorations.isEmpty {
                    Text("No saved explorations yet.")
                        .font(.body)
                        .foregroundStyle(AppTheme.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                ForEach(chatModel.explorations) { exploration in
                    ExplorationRow(
                        exploration: exploration,
                        isSelected: selectedExplorationID == exploration.id,
                        onSelect: { onSelect(exploration) }
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            onDelete(exploration.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.visible)
            .frame(maxHeight: .infinity)

            VStack(spacing: 8) {
                DrawerLink(
                    title: "Donate to Wikipedia",
                    subtitle: "Support free travel guides",
                    imageName: "WikivoyageLogo",
                    destination: URL(string: "https://donate.wikimedia.org/")!,
                    background: AppTheme.green,
                    foreground: .white,
                    detail: .white.opacity(0.72),
                    logoBackground: .white
                )

                DrawerLink(
                    title: "Discover NobodyWho",
                    subtitle: "Run private AI in your apps",
                    imageName: "NobodyWhoLogo",
                    destination: URL(string: "https://www.nobodywho.ai")!,
                    background: AppTheme.nobodyWhoYellow,
                    foreground: AppTheme.nobodyWhoInk,
                    detail: AppTheme.nobodyWhoInk.opacity(0.72),
                    logoBackground: AppTheme.nobodyWhoInk
                )
            }
            .padding(14)
        }
        .background(
            LinearGradient(
                colors: [AppTheme.mint, AppTheme.drawerEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

private struct ExplorationRow: View {
    let exploration: Exploration
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                Text(exploration.prompt)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(exploration.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .contentShape(Rectangle())
            .background(AppTheme.surface, in: .rect(cornerRadius: 16))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(AppTheme.green.opacity(0.35), lineWidth: 1)
                }
            }
        }
        .buttonStyle(PressButtonStyle())
        .accessibilityLabel("Open exploration: \(exploration.prompt)")
    }
}

private struct DrawerLink: View {
    let title: String
    let subtitle: String
    let imageName: String
    let destination: URL
    let background: Color
    let foreground: Color
    let detail: Color
    let logoBackground: Color

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 11) {
                LogoImage(name: imageName, size: 30)
                    .padding(3)
                    .background(logoBackground, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(detail)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(foreground)
            .padding(14)
            .background(background, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(PressButtonStyle())
    }
}

private struct SquareIconButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(AppTheme.green)
                .frame(width: 44, height: 44)
                .background(AppTheme.surface, in: .rect(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(AppTheme.ink.opacity(0.08), lineWidth: 0.5) }
        }
        .buttonStyle(PressButtonStyle())
        .accessibilityLabel(label)
    }
}

private extension UIApplication {
    var keyWindowSafeAreaInsets: EdgeInsets {
        guard
            let scene = connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let window = scene.windows.first(where: \.isKeyWindow)
        else {
            return EdgeInsets()
        }

        return EdgeInsets(
            top: window.safeAreaInsets.top,
            leading: window.safeAreaInsets.left,
            bottom: window.safeAreaInsets.bottom,
            trailing: window.safeAreaInsets.right
        )
    }
}

struct PressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(
                reduceMotion ? .linear(duration: 0.05) : .spring(response: 0.24, dampingFraction: 0.9),
                value: configuration.isPressed
            )
    }
}

