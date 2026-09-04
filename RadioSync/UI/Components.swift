import SwiftUI

// MARK: - Header

struct SourceHeader: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.metadata.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = model.metadata.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let detail = model.metadata.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            SourceMenu()
        }
    }
}

struct SourceMenu: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        Menu {
            Picker("Source", selection: Binding(
                get: { model.sourceKind },
                set: { model.selectSource($0) }
            )) {
                ForEach(model.availableSources) { kind in
                    Label(kind.title, systemImage: kind.symbolName).tag(kind)
                }
            }
        } label: {
            Image(systemName: model.sourceKind.symbolName)
                .font(.title2)
                .frame(width: 56, height: 56)
                .background(.white.opacity(0.12), in: Circle())
        }
        .accessibilityLabel("Audio source")
    }
}

// MARK: - Delay

struct DelayReadout: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(spacing: 2) {
            Text("DELAY")
                .font(.caption.weight(.semibold))
                .tracking(2)
                .foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(model.displayedDelay, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("s")
                    .font(.system(size: 40, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            Text(model.statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(statusColor)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private var statusColor: Color {
        switch model.state {
        case .stopped: .secondary
        case .starting, .buffering: .yellow
        case .playing: .green
        case .paused: .orange
        }
    }
}

struct DelaySlider: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { model.displayedDelay },
                    set: { model.scrub(to: $0) }
                ),
                in: model.delayRange,
                step: 0.1
            ) { editing in
                if !editing { model.endScrub() }
            }
            HStack {
                Text("0 s")
                Spacer()
                Text("90 s")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct NudgeRow: View {
    @Environment(PlayerModel.self) private var model

    private let steps: [Double] = [-1, -0.1, 0.1, 1]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(steps, id: \.self) { step in
                Button {
                    model.nudge(by: step)
                } label: {
                    Text(label(for: step))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 68)
                }
                .buttonStyle(BigButtonStyle())
                .accessibilityLabel(step < 0 ? "Decrease delay by \(abs(step)) seconds" : "Increase delay by \(step) seconds")
            }
        }
    }

    private func label(for step: Double) -> String {
        let sign = step < 0 ? "−" : "+"
        let magnitude = abs(step)
        if magnitude >= 1 {
            return "\(sign)\(Int(magnitude)) s"
        }
        return String(format: "%@%.1f s", sign, magnitude)
    }
}

// MARK: - Transport

struct TransportRow: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.togglePlayPause()
            } label: {
                Label(primaryTitle, systemImage: primarySymbol)
                    .font(.title2.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 76)
            }
            .buttonStyle(BigButtonStyle(prominent: true))
            .disabled(model.state == .starting)

            if model.state != .stopped {
                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2.weight(.bold))
                        .frame(width: 96, height: 76)
                }
                .buttonStyle(BigButtonStyle())
                .accessibilityLabel("Stop")
            }
        }
    }

    private var primaryTitle: String {
        switch model.state {
        case .stopped: "Play"
        case .starting: "Starting"
        case .paused: "Resume"
        case .buffering, .playing: "Pause"
        }
    }

    private var primarySymbol: String {
        switch model.state {
        case .stopped, .paused: "play.fill"
        case .starting: "hourglass"
        case .buffering, .playing: "pause.fill"
        }
    }
}

struct VolumeRow: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                Slider(
                    value: Binding(
                        get: { Double(model.volume) },
                        set: { model.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                Image(systemName: "speaker.wave.3.fill")
            }
            .foregroundStyle(.secondary)
            if !model.outputRouteName.isEmpty {
                Text(model.outputRouteName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Error

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(Color.red.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Styles

/// Big, high-contrast touch target for a dark room.
struct BigButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background(
                prominent
                    ? AnyShapeStyle(Color.accentColor.opacity(configuration.isPressed ? 0.7 : 1))
                    : AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.28 : 0.12)),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
