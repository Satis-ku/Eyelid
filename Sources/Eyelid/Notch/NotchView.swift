import SwiftUI

struct NotchView: View {
    let model: NotchViewModel

    private let animation = Animation.spring(response: 0.42, dampingFraction: 0.82)

    var body: some View {
        let size = model.bodySize

        content
            .frame(width: size.width, height: size.height, alignment: .top)
            .padding(.horizontal, model.topRadius)
            .background(.black)
            .clipShape(NotchShape(
                topCornerRadius: model.topRadius,
                bottomCornerRadius: model.bottomRadius,
                lowerLidDepth: model.lowerLidDepth
            ))
            .shadow(color: .black.opacity(model.state == .open ? 0.45 : 0), radius: 14, y: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(animation, value: model.state)
            .animation(animation, value: model.showsActivity)
            .animation(animation, value: model.batteryEvent)
            .animation(animation, value: model.output == nil)
            .animation(animation, value: model.hud == nil)
            .animation(animation, value: model.isShowingTrackTitle)
            // The notch grows as the translation comes in.
            .animation(animation, value: model.translator.request?.outcome)
            // The next title replaces the last one in place, title and artist together.
            .animation(.easeInOut(duration: 0.25), value: model.trackTitle?.id)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .open:
            OpenNotchView(model: model)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        case .closed:
            VStack(spacing: 0) {
                ZStack {
                    closedActivity
                }
                .frame(height: model.geometry.notchSize.height)

                // Below the hardware notch, where the notch drops like a lower eyelid.
                if model.isShowingTrackTitle, let title = model.trackTitle, let track = model.nowPlaying.track {
                    TrackTitleView(
                        title: title,
                        line: TitleLine(title: track.title, artist: track.artist),
                        // The previous track's colors until the new artwork is here, then a blend into its own.
                        color: track.artworkColor,
                        size: CGSize(width: model.bodySize.width, height: NotchViewModel.Layout.trackTitleHeight),
                        inset: NotchViewModel.Layout.trackTitleInset
                    ) {
                        model.finishTrackTitle(title.id)
                    }
                    .id(title.id)
                    .transition(.opacity)
                }
            }
        }
    }

    /// Beside the hardware notch: the HUD, an output or battery event, or what's playing.
    @ViewBuilder
    private var closedActivity: some View {
        if let hud = model.hud {
            HUDView(event: hud, style: model.settings.hudLevelStyle, notchSize: model.geometry.notchSize)
                .transition(.opacity)
        } else if let output = model.output {
            OutputActivityView(event: output, style: model.settings.hudLevelStyle, notchSize: model.geometry.notchSize)
                .transition(.opacity)
        } else if let event = model.batteryEvent {
            BatteryActivityView(event: event, notchSize: model.geometry.notchSize)
                .transition(.opacity)
        } else if model.showsNowPlayingActivity, let track = model.nowPlaying.track {
            ClosedActivityView(
                track: track,
                notchSize: model.geometry.notchSize,
                audioLevels: model.audioLevels,
                isEqualizerHovered: model.isHoveringEqualizer
            ) {
                model.openSound()
            }
                .transition(.opacity)
        } else if model.showsIdleActivity {
            IdleActivityView(battery: model.battery.state, notchSize: model.geometry.notchSize)
                .transition(.opacity)
        }
    }
}

private struct OpenNotchView: View {
    let model: NotchViewModel

    var body: some View {
        VStack(spacing: 0) {
            // The strip beside the hardware notch: the volume and brightness HUD in the same places as
            // in the closed notch, otherwise the tabs on the left and the battery on the right.
            ZStack {
                if let hud = model.hud {
                    HUDView(event: hud, style: model.settings.hudLevelStyle, notchSize: model.geometry.notchSize)
                        .transition(.opacity)
                } else {
                    let tabs = model.tabs
                    let leading = model.leadingTabCount
                    HStack(spacing: 0) {
                        NotchTabs(model: model, tabs: Array(tabs.prefix(leading)))
                        Spacer(minLength: 0)
                        // Tabs that don't fit left of the camera go right of it, and the date makes room.
                        HStack(spacing: 0) {
                            if leading < tabs.count {
                                NotchTabs(model: model, tabs: Array(tabs.dropFirst(leading)))
                                    .padding(.leading, NotchViewModel.Layout.cameraGap)
                            }
                            Spacer(minLength: 0)
                            OpenNotchStatus(battery: model.battery.state, showsDate: model.settings.showsDateInOpenNotch)
                                .frame(maxWidth: model.statusWidth - model.trailingTabsWidth, alignment: .trailing)
                        }
                        .frame(width: model.statusWidth)
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: model.geometry.notchSize.height)
            .animation(.easeOut(duration: 0.15), value: model.hud == nil)

            Group {
                if model.showsShelf {
                    ShelfView(model: model)
                } else if model.showsClipboard {
                    ClipboardView(model: model)
                } else if model.showsSound {
                    SoundPanel(sound: model.sound, settings: model.settings)
                } else if model.showsTranslation {
                    TranslationPanel(
                        translator: model.translator,
                        isTyping: model.isTypingTranslation,
                        beginTyping: model.typeTranslation
                    )
                } else if let track = model.nowPlaying.track {
                    NowPlayingCard(track: track, nowPlaying: model.nowPlaying)
                } else {
                    Label("Nothing is playing", systemImage: "music.note")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, NotchViewModel.Layout.openHorizontalPadding)
        .padding(.bottom, NotchViewModel.Layout.openBottomPadding)
    }
}

/// Switches the open notch between now playing, the shelf, the clipboard history, sound and the translator.
private struct NotchTabs: View {
    let model: NotchViewModel
    let tabs: [NotchViewModel.Tab]

    var body: some View {
        HStack(spacing: NotchViewModel.Layout.tabSpacing) {
            ForEach(tabs, id: \.self) { tab in
                TabButton(title: title(of: tab), systemImage: systemImage(of: tab), isSelected: model.tab == tab) {
                    if tab == .clipboard {
                        model.resetClipboard()
                    }
                    model.tab = tab
                }
            }
        }
    }

    private func title(of tab: NotchViewModel.Tab) -> String {
        switch tab {
        case .nowPlaying: "Now Playing"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .sound: "Sound"
        case .translation: "Translation"
        }
    }

    private func systemImage(of tab: NotchViewModel.Tab) -> String {
        switch tab {
        case .nowPlaying: "music.note"
        case .shelf: model.shelf.items.isEmpty ? "tray" : "tray.full"
        case .clipboard: "doc.on.clipboard"
        case .sound: "speaker.wave.2"
        case .translation: "translate"
        }
    }
}

private struct TabButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.45))
                .frame(width: NotchViewModel.Layout.tabWidth, height: 22)
                .background(.white.opacity(isSelected ? 0.14 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}
