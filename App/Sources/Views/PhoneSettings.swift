import AOSKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings > iPhone: pairing, paired devices, what the phone needs.
struct PhoneSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var showPairing = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    HeroSymbol(systemName: "iphone", tint: BrandColor.indigo)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Brand.name) on your iPhone").font(.headline)
                        Text("Approve sign-ins for your agent with Face ID, open your Mac's terminal, and watch and control your Mac and the workspace, also on the go.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("This Mac") {
                LabeledContent {
                    if model.remoteLoginOn {
                        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Turn On …") { model.openRemoteLoginSettings() }.buttonStyle(.glass)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remote Login")
                        Text("The iPhone connects over SSH: encrypted, and only with its own key.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Paired") {
                if model.pairedDevices.isEmpty {
                    Text("No iPhone paired yet.").foregroundStyle(.secondary)
                }
                ForEach(model.pairedDevices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: "iphone").foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            HStack(spacing: 6) {
                                StatusDot(color: connected(device) ? .green : .secondary)
                                Text(connected(device) ? String(localized: "Connected now") : String(localized: "Not connected"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { model.removeDevice(device) }.buttonStyle(.glass)
                    }
                }
                Button {
                    showPairing = true
                } label: {
                    Label("Pair an iPhone …", systemImage: "qrcode")
                }
                .buttonStyle(.glassProminent)
                .disabled(!model.remoteLoginOn)
            }

            Section {
                Text("Away from your Wi-Fi, the iPhone reaches this Mac through a VPN such as Tailscale. With it on both devices, the app finds the Mac by itself.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("On the go")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPhone() }
        .sheet(isPresented: $showPairing, onDismiss: { model.stopPairing() }) {
            PairingView().environmentObject(model)
        }
    }

    func connected(_ device: AuthorizedKeys.Device) -> Bool {
        model.phoneConnected && (model.phoneName == device.name || model.pairedDevices.count == 1)
    }
}

/// The QR code the iPhone scans.
struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            let _ = model.pairingTick
            switch model.pairing?.state {
            case .waiting?:
                Text("Scan this code with \(Brand.name) on your iPhone").font(.title3.bold()).multilineTextAlignment(.center)
                if let url = model.pairing?.url, let image = QRCode.image(url) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Open \(Brand.name) on your iPhone.")
                    step(2, "Tap \u{201C}Pair with your Mac\u{201D}.")
                    step(3, "Point the camera at this code.")
                }
                Link(destination: Brand.phoneAppPage) {
                    Label("\(Brand.name) isn't on your iPhone yet?", systemImage: "arrow.down.app")
                }
                .font(.callout)
                if let expires = model.pairing?.expires {
                    Text("The code is valid until \(expires.formatted(date: .omitted, time: .shortened)) and only once.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .paired(let name)?:
                HeroSymbol(systemName: "checkmark", tint: .green)
                Text("\(name) is paired.").font(.title3.bold())
                Text("Open \(Brand.name) on the iPhone: it connects to this Mac now.").foregroundStyle(.secondary)
            case .failed(let reason)?:
                HeroSymbol(systemName: "exclamationmark.triangle", tint: .orange)
                Text("Pairing didn't work").font(.title3.bold())
                Text(reason).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { model.startPairing() }.buttonStyle(.glassProminent)
            case .expired?:
                HeroSymbol(systemName: "clock", tint: .secondary)
                Text("The code expired").font(.title3.bold())
                Button("New Code") { model.startPairing() }.buttonStyle(.glassProminent)
            case .starting?, nil:
                ProgressView()
                Text("Preparing …").foregroundStyle(.secondary)
            }
            Button(isPaired ? "Done" : "Cancel") { dismiss() }
                .buttonStyle(.glass).keyboardShortcut(isPaired ? .defaultAction : .cancelAction)
        }
        .padding(28)
        .frame(width: 400)
        .onAppear { model.startPairing() }
    }

    var isPaired: Bool {
        if case .paired = model.pairing?.state { return true }
        return false
    }

    func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.callout.bold()).foregroundStyle(BrandColor.indigo).frame(width: 16)
            Text(text).font(.callout)
        }
    }
}

enum QRCode {
    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
