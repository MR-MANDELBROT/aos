import SwiftUI
import UniformTypeIdentifiers

/// Import from a Bitwarden export (JSON or CSV, unencrypted), then delete the export.
struct ImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Step {
        case choose
        case preview(URL, ImportResult)
        case done(URL, added: Int, duplicates: Int, skipped: Int)
    }

    @State private var step: Step = .choose
    @State private var picking = false
    @State private var error: String?
    @State private var fileDeleted = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case .choose: chooseView
                    case .preview(let url, let result): previewView(url, result)
                    case .done(let url, let added, let duplicates, let skipped):
                        doneView(url, added: added, duplicates: duplicates, skipped: skipped)
                    }
                }
                .padding()
            }
            .aosBackground()
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .done = step {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.json, .commaSeparatedText, .plainText]) { result in
                switch result {
                case .success(let url): read(url)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }

    // MARK: Steps

    private var chooseView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                HeroSymbol(systemName: "square.and.arrow.down", size: 56)
                Text("Bring your logins from Bitwarden").font(.title3.weight(.semibold))
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("In Bitwarden").font(.headline)
                    Text("1. Open Tools > Export vault.")
                    Text("2. Choose the format \u{201E}.json\u{201C} or \u{201E}.csv\u{201C}, not the encrypted one.")
                    Text("3. Save the file in Files (On My iPhone).")
                }
                .font(.subheadline)
            }
            FactRow(symbol: "exclamationmark.shield", text: "The export contains all your passwords unencrypted. aOS reads it once; afterwards you delete it.",
                    tint: .orange)
            FactRow(symbol: "iphone", text: "Imported logins stay on this iPhone, locked with Face ID.")
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.subheadline)
            }
            Button {
                error = nil
                picking = true
            } label: {
                Label("Choose the export file", systemImage: "folder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    private func previewView(_ url: URL, _ result: ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(url.lastPathComponent).font(.headline).lineLimit(2)
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Logins found: \(result.logins.count)", systemImage: "key.horizontal")
                        .font(.title3.weight(.semibold))
                    if result.logins.contains(where: { !$0.totp.isEmpty }) {
                        Label("With one-time codes: \(result.logins.filter { !$0.totp.isEmpty }.count)",
                              systemImage: "clock.badge.checkmark")
                            .foregroundStyle(.secondary)
                    }
                    if result.skippedOther > 0 {
                        Label("Left out, not logins (notes, cards, identities): \(result.skippedOther)", systemImage: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    if result.skippedEmpty > 0 {
                        Label("Left out, without user name and password: \(result.skippedEmpty)", systemImage: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
            Button {
                importLogins(url, result)
            } label: {
                Label("Import the logins", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(result.logins.isEmpty)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.subheadline)
            }
        }
    }

    private func doneView(_ url: URL, added: Int, duplicates: Int, skipped: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                HeroSymbol(systemName: "checkmark", tint: BrandColor.mint, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logins imported: \(added)").font(.title3.weight(.semibold))
                    if duplicates > 0 {
                        Text("Already in the vault: \(duplicates)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            GlassCard(tint: fileDeleted ? nil : BrandColor.attention) {
                VStack(alignment: .leading, spacing: 12) {
                    if fileDeleted {
                        Label("The export file is deleted.", systemImage: "checkmark.circle.fill").font(.headline)
                            .foregroundStyle(.green)
                        Text("If it was in iCloud Drive, also empty \u{201E}Recently Deleted\u{201C} in Files.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Label("Now delete the export file", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(BrandColor.attention)
                        Text("\u{201E}\(url.lastPathComponent)\u{201C} still contains all your passwords unencrypted. Delete it, and empty \u{201E}Recently Deleted\u{201C} in Files afterwards.")
                            .font(.subheadline)
                        Button(role: .destructive) {
                            deleteFile(url)
                        } label: {
                            Label("Delete the file now", systemImage: "trash").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                        if let deleteError {
                            Text(deleteError).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func read(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let result = try BitwardenImport.parse(data: data, fileName: url.lastPathComponent)
            step = .preview(url, result)
        } catch BitwardenImport.ImportError.encrypted {
            error = String(localized: "This export is encrypted. Export again and choose \u{201E}.json\u{201C} or \u{201E}.csv\u{201C} without encryption.")
        } catch BitwardenImport.ImportError.notBitwarden {
            error = String(localized: "This file doesn't look like a Bitwarden export.")
        } catch BitwardenImport.ImportError.empty {
            error = String(localized: "The file contains no logins.")
        } catch {
            self.error = String(localized: "The file couldn't be read.")
        }
    }

    private func importLogins(_ url: URL, _ result: ImportResult) {
        do {
            let (added, duplicates) = try model.vault.add(imported: result.logins)
            step = .done(url, added: added, duplicates: duplicates, skipped: result.skippedOther + result.skippedEmpty)
        } catch Keychain.Failure.noPasscode {
            error = String(localized: "Set a passcode for this iPhone first (Settings > Face ID & Passcode). The vault needs it.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.removeItem(at: url)
            fileDeleted = true
        } catch {
            deleteError = String(localized: "aOS may not delete it there. Delete it in the Files app.")
        }
    }
}
