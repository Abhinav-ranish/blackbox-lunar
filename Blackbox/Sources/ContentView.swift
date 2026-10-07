import SwiftUI

private extension Color {
    static let recorder = Color(red: 1.0, green: 0.42, blue: 0.0)
    static let teal = Color(red: 0.18, green: 0.77, blue: 0.71)
    static let violet = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let amber = Color(red: 1.0, green: 0.7, blue: 0.15)
    static let alert = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let panel = Color.white.opacity(0.055)
    static let hairline = Color.white.opacity(0.09)
}

struct ContentView: View {
    @State private var engine = BlackboxEngine()
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HeaderView(startedAt: engine.startedAt, logURL: engine.recorder.logURL)
                cameraPanel
                VitalsPanel(engine: engine)
                StatsRow(events: engine.recorder.events)
                ScenePanel(engine: engine)
                timeline
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background { SpaceBackground() }
        .preferredColorScheme(.dark)
        .onAppear { engine.start() }
        .confirmationDialog("Erase the mission log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Erase log and snapshots", role: .destructive) { engine.recorder.clear() }
        }
    }

    // MARK: Camera

    private var cameraPanel: some View {
        CameraPreview(session: engine.camera.session)
            .frame(height: 340)
            .overlay {
                LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .clipShape(.rect(cornerRadius: 22))
            .overlay(alignment: .topLeading) {
                Label("ON-DEVICE · NO CLOUD", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    engine.toggleCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .foregroundStyle(.white)
                .padding(12)
                .accessibilityLabel(engine.usingFrontCamera ? "Switch to back camera" : "Switch to front camera")
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 8) {
                    Circle().fill(engine.status.color).frame(width: 8, height: 8)
                    Text(engine.status.title)
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: .capsule)
                .padding(12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(engine.status.color.opacity(engine.status == .deceased ? 1 : 0.5),
                                  lineWidth: engine.status == .deceased ? 4 : 1)
            }
            .animation(.easeInOut(duration: 0.3), value: engine.status == .deceased)
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("MISSION LOG")
                Spacer()
                Button("Erase", systemImage: "trash", role: .destructive) { confirmClear = true }
                    .labelStyle(.iconOnly)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if engine.recorder.events.isEmpty {
                Text("No events yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            LazyVStack(spacing: 8) {
                ForEach(engine.recorder.events.reversed()) { event in
                    EventRow(event: event, snapshotURL: engine.recorder.snapshotURL(for: event))
                }
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Background

private struct SpaceBackground: View {
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Color.violet.opacity(0.35), .clear],
                           center: .init(x: 0.85, y: 0.0), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color.recorder.opacity(0.12), .clear],
                           center: .init(x: 0.0, y: 0.35), startRadius: 0, endRadius: 360)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Header

private struct HeaderView: View {
    let startedAt: Date
    let logURL: URL

    var body: some View {
        HStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text("BLACKBOX")
                    .font(.system(size: 22, weight: .black))
                    .tracking(1.5)
                Text("CREW FLIGHT RECORDER")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.recorder)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.alert)
                        .frame(width: 7, height: 7)
                        .opacity(Int(context.date.timeIntervalSince1970) % 2 == 0 ? 1 : 0.3)
                    Text(missionClock(now: context.date))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.panel, in: .capsule)
            }
            ShareLink(item: logURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.white)
            .accessibilityLabel("Export mission log")
        }
        .padding(.top, 6)
    }

    private func missionClock(now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(startedAt)))
        return String(format: "T+%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

// MARK: - Vitals

private struct VitalsPanel: View {
    @Bindable var engine: BlackboxEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel("CREW VITALS")
                Spacer()
                Picker("Alarm after", selection: $engine.demoMode) {
                    Text("10 s demo").tag(true)
                    Text("2 h").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            HStack(spacing: 16) {
                CountdownRing(progress: progress, color: engine.status.color, label: ringLabel)
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.status.title)
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(engine.status.color)
                        .contentTransition(.numericText())
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .card()
        .animation(.easeInOut(duration: 0.25), value: engine.status.title)
    }

    private var progress: Double {
        switch engine.status {
        case .still(let t): min(t / engine.inactivityLimit, 1)
        case .deceased: 1
        default: 0
        }
    }

    private var ringLabel: String {
        switch engine.status {
        case .still(let t) where engine.demoMode: "\(max(0, Int(engine.inactivityLimit - t)))s"
        case .still: "STILL"
        case .deceased: "LOST"
        case .moving: "OK"
        case .noHuman: "—"
        }
    }

    private var detail: String {
        switch engine.status {
        case .noHuman: "Waiting for a crew member to enter the cabin."
        case .moving: "Movement detected. Life signs nominal."
        case .still(let t): "Motionless for \(Int(t)) s. Alarm at \(engine.limitLabel)."
        case .deceased: "No movement for \(engine.limitLabel). Logged to the black box."
        }
    }
}

private struct CountdownRing: View {
    let progress: Double
    let color: Color
    let label: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.hairline, lineWidth: 7)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
            Text(label)
                .font(.system(size: 15, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
                .contentTransition(.numericText())
        }
        .frame(width: 72, height: 72)
    }
}

// MARK: - Stats

private struct StatsRow: View {
    let events: [RecorderEvent]

    var body: some View {
        HStack(spacing: 10) {
            stat("Sightings", count(.humanDetected), "person.fill", .teal)
            stat("Observations", count(.observation), "eye.fill", .violet)
            stat("Loo breaks", count(.loo), "toilet.fill", .amber)
        }
    }

    private func count(_ kind: EventKind) -> Int { events.lazy.filter { $0.kind == kind }.count }

    private func stat(_ title: String, _ value: Int, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.footnote).foregroundStyle(tint)
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.panel, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.hairline))
    }
}

// MARK: - Scene AI

private struct ScenePanel: View {
    let engine: BlackboxEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("ONBOARD AI")
                Spacer()
                Text("Liquid LFM2.5-VL · Melange")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.teal)
            }
            switch engine.modelState {
            case .idle:
                Text("Starting…").font(.footnote).foregroundStyle(.secondary)
            case .downloading(let p):
                ProgressView(value: Double(p)) {
                    Text("Loading model \(Int(p * 100))%").font(.footnote)
                }
                .tint(.teal)
            case .ready:
                Text(engine.lastObservation.isEmpty ? "Observing the cabin…" : "“\(engine.lastObservation)”")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if engine.lastObservationMs > 0 {
                    Label("\(engine.lastObservationMs) ms per frame · on-device", systemImage: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(Color.alert)
            }
        }
        .card()
    }
}

// MARK: - Shared pieces

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(.secondary)
    }
}

private extension View {
    func card() -> some View {
        padding(16)
            .background(Color.panel, in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.hairline))
    }
}

private extension VitalStatus {
    var title: String {
        switch self {
        case .noHuman: "NO CREW IN VIEW"
        case .moving: "ALIVE"
        case .still: "MOTIONLESS"
        case .deceased: "NO SIGNS OF LIFE"
        }
    }

    var color: Color {
        switch self {
        case .noHuman: .gray
        case .moving: .teal
        case .still: .amber
        case .deceased: .alert
        }
    }
}

private struct EventRow: View {
    let event: RecorderEvent
    let snapshotURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.kind.rawValue)
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(tint)
                    Spacer()
                    Text(event.date, format: .dateTime.hour().minute().second())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(event.detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            if let snapshotURL, let image = UIImage(contentsOfFile: snapshotURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 46, height: 60)
                    .clipShape(.rect(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(Color.panel, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(event.kind == .deceased ? Color.alert.opacity(0.6) : Color.hairline))
    }

    private var tint: Color {
        switch event.kind {
        case .deceased: .alert
        case .humanDetected, .revived, .movementResumed: .teal
        case .loo: .amber
        case .observation: .violet
        case .system, .sessionStart: .recorder
        case .humanLeft: .gray
        }
    }
}
