import SwiftUI

struct NotchView: View {
    let model: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
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
            // The strip beside the hardware notch: the volume and brightness HUD in the same places as in the closed
            // notch, otherwise the section on the left, which opens the menu of all sections, and the battery on the
            // right.
            ZStack {
                if let hud = model.hud {
                    HUDView(event: hud, style: model.settings.hudLevelStyle, notchSize: model.geometry.notchSize)
                        .transition(.opacity)
                } else {
                    HStack(spacing: 0) {
                        SectionTitle(
                            section: model.currentSection,
                            systemImage: model.systemImage(for: model.currentSection),
                            isMenuShown: model.showsSectionMenu
                        ) {
                            model.showsSectionMenu.toggle()
                        }
                        .frame(maxWidth: model.statusWidth, alignment: .leading)
                        Spacer(minLength: 0)
                        OpenNotchStatus(battery: model.battery.state, showsDate: model.settings.showsDateInOpenNotch)
                            .frame(maxWidth: model.statusWidth, alignment: .trailing)
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: model.geometry.notchSize.height)
            .animation(.easeOut(duration: 0.15), value: model.hud == nil)

            Group {
                if model.showsSectionMenu {
                    SectionMenu(model: model)
                } else if model.showsShelf {
                    ShelfView(model: model)
                } else if model.showsClipboard {
                    ClipboardView(model: model)
                } else if model.showsSound {
                    SoundPanel(sound: model.sound, appVolumes: model.appVolumes, settings: model.settings)
                } else if model.showsTranslation {
                    TranslationPanel(
                        translator: model.translator,
                        isTyping: model.isTypingTranslation,
                        translatesOnDoubleCopy: model.settings.translatesOnDoubleCopy,
                        beginTyping: model.typeTranslation
                    )
                } else if let track = model.nowPlaying.track {
                    NowPlayingCard(track: track, nowPlaying: model.nowPlaying)
                } else {
                    // As the shelf and the clipboard say they're empty.
                    VStack(spacing: 6) {
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .medium))
                        Text("Nothing is playing")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, NotchViewModel.Layout.openBottomPadding)
            .animation(.easeOut(duration: 0.15), value: model.showsSectionMenu)

            SectionDock(model: model)
                .frame(height: NotchViewModel.Layout.dockHeight)
        }
        .padding(.horizontal, NotchViewModel.Layout.openHorizontalPadding)
    }
}
