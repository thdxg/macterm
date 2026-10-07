import AppKit
import SwiftUI

/// Passwords settings: how the password manager behaves at a prompt, and the
/// searchable list of what it has saved. Each saved password is filed under
/// the command that asked for it plus the prompt it printed
/// (`PasswordEntryID`); the secrets themselves live in the login keychain and
/// are read only to autofill or copy, behind the same authentication.
struct PasswordsSettings: View {
    private var vault: PasswordVault { .shared }

    @State private var enabled: Bool = Preferences.shared.passwordManagerEnabled
    @State private var authentication: String = Preferences.shared.passwordAutofillAuthentication.rawValue
    @State private var query = ""
    @State private var pendingRemoval: SavedPassword?
    /// The editor sheet that is up: an entry's Details (the full command,
    /// prompt and, after authentication, password, for rows the list
    /// truncates), or a new entry from the `+`.
    @State private var editor: PasswordEditorRequest?

    var body: some View {
        Form {
            Section {
                Toggle("Enable password manager", isOn: $enabled)
                    .onChange(of: enabled) { _, v in
                        Preferences.shared.passwordManagerEnabled = v
                    }
                Text(Self.enabledCaption).settingsCaption()

                Group {
                    Picker("Require authentication", selection: $authentication) {
                        ForEach(PasswordAutofillAuthentication.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .onChange(of: authentication) { _, v in
                        Preferences.shared.passwordAutofillAuthentication = PasswordAutofillAuthentication(rawValue: v) ?? .untilLocked
                        PasswordAuthenticator.shared.lock()
                    }
                    Text(Self.authenticationCaption).settingsCaption()
                }
                .disabled(!enabled)
            } header: {
                DocsSectionHeader("Password Manager", docs: .passwords)
            }

            Section {
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
                            onDetails: { editor = .edit(entry) },
                            onCopy: { copy(entry) },
                            onRemove: { pendingRemoval = entry }
                        )
                    }
                }
                if let error = vault.lastError {
                    Text(error).settingsCaption()
                }
            } header: {
                DocsSectionHeader("Saved Passwords", docs: .savedPasswords) {
                    Button {
                        editor = .new()
                    } label: {
                        Label("Add Password", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Add a password")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { vault.reload() }
        .sheet(item: $editor) { request in
            PasswordEditorSheet(request: request, vault: vault)
        }
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

    private static let enabledCaption = "Offers to save a password you type at a prompt once it works, "
        + "and fills it in the next time that prompt appears."
    private static let authenticationCaption = "Asks for Touch ID, or your login password, before autofilling "
        + "or showing a saved password. Passwords are stored in your login keychain."

    private var filtered: [SavedPassword] {
        vault.entries(matching: query)
    }

    /// Copy behind the same gate as Autofill.
    private func copy(_ entry: SavedPassword) {
        Task { @MainActor in
            let authorized = await PasswordAuthenticator.shared.authorize(
                reason: "copy the password for “\(entry.id.title)”"
            )
            guard authorized, let secret = vault.password(for: entry.id) else { return }
            PasswordClipboard.copy(secret)
        }
    }
}

/// The general pasteboard write for a password, marked concealed so clipboard
/// managers that honor the convention don't keep it.
enum PasswordClipboard {
    static func copy(_ secret: String) {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(secret, forType: .string)
        pasteboard.setString("", forType: concealed)
    }
}

private struct SavedPasswordRow: View {
    let entry: SavedPassword
    let onDetails: () -> Void
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
                Text(entry.id.isOnDemandOnly ? "Filled from the command palette only" : entry.id.prompt)
                    .font(entry.id.isOnDemandOnly ? .caption : .caption.monospaced())
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
        Button("Details…") { onDetails() }
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
