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
    /// The entry whose Details sheet is up: the full command, prompt and
    /// (after authentication) password, for rows the list truncates.
    @State private var details: SavedPassword?

    var body: some View {
        Form {
            Section("Password Manager") {
                Toggle("Offer to save passwords", isOn: $offerToSave)
                    .onChange(of: offerToSave) { _, v in
                        Preferences.shared.offerToSavePasswords = v
                    }
                Text(Self.offerCaption).settingsCaption()

                Picker("Ask for Touch ID", selection: $authentication) {
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
                            onDetails: { details = entry },
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
        .sheet(item: $details) { entry in
            PasswordDetailsSheet(entry: entry, vault: vault)
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

    private static let offerCaption = "After a password you type works, offer to save it for that command."
    private static let authenticationCaption = "Autofill confirms with Touch ID, or your login password where Touch ID isn’t available. "
        + "Once per app launch also asks again after the Mac locks or sleeps. "
        + "Passwords are stored in your login keychain."

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

/// One saved password, untruncated and editable: the command exactly as the
/// process table reported it (the list shows a shortened form), the prompt
/// line, and the password itself, shown behind the same authentication
/// Autofill uses. Command and prompt are fields to type in; the password
/// becomes one once shown. Nothing is written until Save; Cancel discards
/// every edit. Save files the entry under
/// the edited command and prompt through the same rules detection applies
/// (`PasswordPromptIdentity.entryID`), so an edit lands where the next prompt
/// will look. The revealed password lives only in this sheet's state and goes
/// with it.
private struct PasswordDetailsSheet: View {
    let entry: SavedPassword
    let vault: PasswordVault

    @Environment(\.dismiss) private var dismiss
    @State private var command: String
    @State private var prompt: String
    /// The password as shown and edited; nil until revealed.
    @State private var password: String?
    /// What the store held when revealed, to tell an edit from a look.
    @State private var storedPassword: String?
    @State private var busy = false
    @State private var problem: String?

    init(entry: SavedPassword, vault: PasswordVault) {
        self.entry = entry
        self.vault = vault
        _command = State(initialValue: entry.id.command ?? "")
        _prompt = State(initialValue: entry.id.prompt)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Command", text: $command, prompt: Text("Any command"))
                        .font(.body.monospaced())
                    TextField("Prompt", text: $prompt)
                        .font(.body.monospaced())
                    LabeledContent("Password") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if password != nil {
                                TextField("Password", text: Binding(
                                    get: { password ?? "" },
                                    set: { password = $0 }
                                ))
                                .labelsHidden()
                                .font(.body.monospaced())
                                .multilineTextAlignment(.trailing)
                                Button("Hide") { password = nil }
                            } else {
                                Text(verbatim: "••••••••")
                                    .font(.body.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Button("Show") { reveal() }
                                    .disabled(busy)
                            }
                        }
                    }
                    if let modified = entry.modified {
                        LabeledContent("Saved") {
                            Text(modified, format: .dateTime.year().month().day().hour().minute())
                        }
                    }
                } footer: {
                    Text(problem ??
                        "Autofill is offered when both the command and the prompt match. Without a command, the prompt alone is enough.")
                        .foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(MactermTheme.failure))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || !isValid || busy)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Where the edited entry will be filed — through detection's own rules,
    /// so `sudo apt update` still collapses to `sudo` and a key passphrase
    /// still drops its command.
    private var proposedID: PasswordEntryID {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        return PasswordPromptIdentity.declaredEntryID(
            prompt: PasswordPromptIdentity.normalize(prompt),
            command: trimmed.isEmpty ? nil : trimmed
        )
    }

    private var passwordChanged: Bool {
        guard let password else { return false }
        return password != storedPassword
    }

    private var hasChanges: Bool { proposedID != entry.id || passwordChanged }

    private var isValid: Bool {
        !proposedID.prompt.isEmpty && (password.map { !$0.isEmpty } ?? true)
    }

    private func reveal() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let authorized = await PasswordAuthenticator.shared.authorize(
                reason: "show the password for “\(entry.id.title)”"
            )
            guard authorized, let secret = vault.password(for: entry.id) else { return }
            storedPassword = secret
            password = secret
        }
    }

    /// Save under the edited identity. Moving an entry needs its password,
    /// so an edit that never revealed it authenticates for the read here.
    private func save() {
        let newID = proposedID
        if newID != entry.id, vault.contains(newID) {
            problem = "A password is already saved for that command and prompt."
            return
        }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let secret: String
            if let password {
                secret = password
            } else {
                let authorized = await PasswordAuthenticator.shared.authorize(
                    reason: "change the saved password entry for “\(entry.id.title)”"
                )
                guard authorized, let stored = vault.password(for: entry.id) else {
                    problem = vault.lastError ?? "Couldn’t read the saved password."
                    return
                }
                secret = stored
            }
            if vault.update(entry.id, to: newID, password: secret) {
                dismiss()
            } else {
                problem = vault.lastError ?? "Couldn’t save the changes."
            }
        }
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
