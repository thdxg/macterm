import AppKit
import SwiftUI

/// Passwords settings: how the password manager behaves at a prompt, and the
/// searchable list of what it has saved. Each saved password is filed under
/// the command that asked for it plus the prompt it printed
/// (`PasswordEntryID`); the secrets themselves live in the login keychain and
/// are read only to autofill or copy, behind the same authentication.
struct PasswordsSettings: View {
    private var vault: PasswordVault { .shared }

    @State private var offerToSave: Bool = Preferences.shared.offerToSavePasswords
    @State private var authentication: String = Preferences.shared.passwordAutofillAuthentication.rawValue
    @State private var query = ""
    @State private var pendingRemoval: SavedPassword?

    var body: some View {
        Form {
            Section("Password Manager") {
                Toggle("Offer to save passwords", isOn: $offerToSave)
                    .onChange(of: offerToSave) { _, v in
                        Preferences.shared.offerToSavePasswords = v
                    }
                Text(Self.offerCaption).settingsCaption()

                Picker("Require Touch ID to autofill", selection: $authentication) {
                    ForEach(PasswordAutofillAuthentication.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .onChange(of: authentication) { _, v in
                    Preferences.shared.passwordAutofillAuthentication = PasswordAutofillAuthentication(rawValue: v) ?? .everyTime
                    PasswordAuthenticator.shared.lock()
                }
                Text("Your login password works where Touch ID isn’t available. Passwords are stored in your login keychain.")
                    .settingsCaption()
            }

            Section("Saved Passwords") {
                SearchField(text: $query, prompt: "Search saved passwords")
                if vault.entries.isEmpty {
                    Text("No saved passwords.")
                        .foregroundStyle(.secondary)
                } else if filtered.isEmpty {
                    Text("No saved passwords match “\(query)”.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { entry in
                        SavedPasswordRow(
                            entry: entry,
                            onCopy: { copy(entry) },
                            onRemove: { pendingRemoval = entry }
                        )
                    }
                }
                if let error = vault.lastError {
                    Text(error).settingsCaption()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { vault.reload() }
        .alert(
            "Remove saved password?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
                .keyboardShortcut(.cancelAction)
            Button("Remove", role: .destructive) {
                if let entry = pendingRemoval { vault.remove(entry.id) }
                pendingRemoval = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("The password for “\(pendingRemoval?.id.title ?? "")” will be removed from your keychain.")
        }
    }

    private static let offerCaption = "After a password you type works, offer to save it for that command."

    private var filtered: [SavedPassword] {
        vault.entries(matching: query)
    }

    /// Copy behind the same gate as Autofill, marked concealed so clipboard
    /// managers that honor the convention don't keep it.
    private func copy(_ entry: SavedPassword) {
        Task { @MainActor in
            let authorized = await PasswordAuthenticator.shared.authorize(
                reason: "copy the password for “\(entry.id.title)”"
            )
            guard authorized, let secret = vault.password(for: entry.id) else { return }
            let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareTypes([.string, concealed], owner: nil)
            pasteboard.setString(secret, forType: .string)
            pasteboard.setString("", forType: concealed)
        }
    }
}

private struct SavedPasswordRow: View {
    let entry: SavedPassword
    let onCopy: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.id.command == nil ? "key.horizontal" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.id.displayCommand ?? "Any command")
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.id.prompt)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if let modified = entry.modified {
                Text(modified, format: .dateTime.year().month().day())
                    .settingsCaption()
            }

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Copy Password") { onCopy() }
        Divider()
        Button("Remove…", role: .destructive) { onRemove() }
    }
}

/// AppKit's search field — SwiftUI has no standalone one on macOS outside
/// `.searchable`, which would put it in the Settings window's toolbar.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context _: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
