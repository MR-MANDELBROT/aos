import SwiftUI
import VisionKit

/// Pairing with a Mac: scan (or paste) the code Annex on the Mac shows, check what it says, pair.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let initialLink: String?

    enum Step: Equatable {
        case scan
        case confirm(PairingLink)
        case working(PairingLink, AppModel.PairingStep?)
        case done(PairedMac)
        case failed(PairingLink, String)
    }

    @State private var step: Step = .scan
    @State private var pasted = ""
    @State private var parseError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .scan: scanView
                case .confirm(let link): confirmView(link)
                case .working(let link, let progress): workingView(link, progress)
                case .done(let mac): doneView(mac)
                case .failed(let link, let message): failedView(link, message)
                }
            }
            .navigationTitle("Pair with a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .done = step {} else {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                }
            }
        }
        .onAppear {
            if let initialLink { accept(initialLink) }
            #if DEBUG
            if model.isDemo, initialLink == nil {
                step = .confirm(PairingLink(macName: "Max’s MacBook Pro", hosts: ["Maxs-MacBook-Pro.local", "192.168.178.24"],
                                            pairingPort: 50123, user: "max",
                                            hostKeyFingerprint: "SHA256:IKIpT5qrBHciGB6LMk+7fuTQHDnNluSkoLBSGY4SWMQ",
                                            code: Data(0..<16)))
            }
            #endif
        }
        .interactiveDismissDisabled(isWorking)
    }

    private var isWorking: Bool { if case .working = step { true } else { false } }

    // MARK: Scan

    private var scanView: some View {
        ScrollView {
            VStack(spacing: 20) {
                if QRScanner.isAvailable {
                    QRScanner { text in accept(text) }
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(alignment: .bottom) {
                            Text("Point the camera at the code on your Mac")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .glassEffect()
                                .padding(12)
                        }
                } else {
                    GlassCard {
                        HStack(spacing: 14) {
                            HeroSymbol(systemName: "qrcode.viewfinder", size: 52)
                            Text("The camera isn't available here. Paste the pairing link instead: on the Mac, Annex can copy it.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Or paste the link").font(.headline)
                    TextField(text: $pasted, prompt: Text(verbatim: "annex-pair://v1?…"), axis: .vertical) {
                        Text("Or paste the link")
                    }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .lineLimit(1...4)
                        .padding(12)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    HStack {
                        PasteButton(payloadType: String.self) { strings in
                            if let text = strings.first { pasted = text; accept(text) }
                        }
                        .buttonBorderShape(.capsule)
                        Spacer()
                        Button("Continue") { accept(pasted) }
                            .buttonStyle(.glassProminent)
                            .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let parseError {
                        Label(parseError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    FactRow(symbol: "desktopcomputer", text: "On the Mac: open Annex and choose \u{201E}Connect iPhone\u{201C}. It turns on nothing new; it uses the Mac's Remote Login.")
                    FactRow(symbol: "key", text: "This iPhone makes its own key. Only its public half goes to the Mac.")
                }
            }
            .padding()
        }
        .annexBackground()
    }

    private func accept(_ text: String) {
        do {
            let link = try PairingLink(text)
            parseError = nil
            step = .confirm(link)
        } catch PairingLink.ParseError.newerVersion {
            parseError = String(localized: "This code is from a newer Annex. Update the app on this iPhone.")
        } catch {
            parseError = String(localized: "That isn't a pairing code of Annex.")
        }
    }

    // MARK: Confirm

    private func confirmView(_ link: PairingLink) -> some View {
        @Bindable var model = model
        return Form {
            Section {
                HStack(spacing: 14) {
                    HeroSymbol(systemName: "laptopcomputer", size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(link.macName).font(.title3.weight(.semibold))
                        Text("User \(link.user)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Pair only with your own Mac. Annex on the Mac adds this iPhone's key to your user's SSH keys there.")
            }
            Section("How the iPhone reaches it") {
                ForEach(link.hosts, id: \.self) { host in
                    Label(host, systemImage: host.hasSuffix(".ts.net") ? "point.3.connected.trianglepath.dotted" : "network")
                        .font(.callout)
                }
            }
            Section {
                KeyText(text: link.hostKeyFingerprint)
            } header: {
                Text("The Mac's SSH key")
            } footer: {
                Text("The iPhone accepts the Mac only with exactly this key, now and later.")
            }
            Section {
                TextField("Name", text: $model.deviceName)
            } header: {
                Text("Name of this iPhone")
            } footer: {
                Text("Annex on the Mac lists paired devices by this name.")
            }
            Section {
                Button {
                    Task { await pair(link) }
                } label: {
                    Label("Pair", systemImage: "link").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private func pair(_ link: PairingLink) async {
        step = .working(link, nil)
        do {
            let mac = try await model.pair(with: link) { progress in
                if case .done = progress { return }
                step = .working(link, progress)
            }
            step = .done(mac)
        } catch {
            step = .failed(link, error.localizedDescription)
        }
    }

    // MARK: Progress and result

    private func workingView(_ link: PairingLink, _ progress: AppModel.PairingStep?) -> some View {
        VStack(spacing: 22) {
            Spacer()
            ProgressView().controlSize(.large)
            VStack(spacing: 10) {
                ProgressLine(text: "Asking the Mac", state: progress == nil || progress == .contactingMac ? .running : .done)
                ProgressLine(text: "Checking the Mac's key", state: progress == .checkingKey ? .running : .waiting)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
        .annexBackground()
    }

    private func doneView(_ mac: PairedMac) -> some View {
        VStack(spacing: 20) {
            Spacer()
            HeroSymbol(systemName: "checkmark", tint: BrandColor.mint, size: 84)
            Text("Paired with \(mac.name)").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text("The iPhone now reaches your Mac by itself whenever the app is open.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding()
        .annexBackground()
    }

    private func failedView(_ link: PairingLink, _ message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            HeroSymbol(systemName: "exclamationmark", tint: .orange, size: 84)
            Text("Pairing didn't work").font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Button {
                Task { await pair(link) }
            } label: {
                Text("Try again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Button("Scan another code") { step = .scan }
                .buttonStyle(.glass)
        }
        .padding()
        .annexBackground()
    }
}

private struct ProgressLine: View {
    enum State { case waiting, running, done }
    let text: LocalizedStringKey
    let state: State

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state == .done ? "checkmark.circle.fill" : state == .running ? "circle.dotted" : "circle")
                .foregroundStyle(state == .done ? BrandColor.mint : state == .running ? BrandColor.indigo : .secondary)
                .symbolEffect(.pulse, isActive: state == .running)
            Text(text).foregroundStyle(state == .waiting ? .secondary : .primary)
        }
        .frame(maxWidth: 280, alignment: .leading)
    }
}

/// VisionKit's live scanner for QR codes; reports the first `annex-pair:` code it sees.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var lastCode: String?

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                guard case .barcode(let code) = item, let text = code.payloadStringValue,
                      text.lowercased().hasPrefix(PairingLink.scheme + ":"), text != lastCode else { continue }
                lastCode = text
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCode(text)
            }
        }
    }
}
