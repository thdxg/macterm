import SwiftUI

/// What the password editor sheet is opened on: a saved entry (Settings →
/// Passwords → Details…) or a new one the user is adding — from Settings'
/// `+`, or from the palette's Password Manager with what was typed there
/// already filled in as the command.
struct PasswordEditorRequest: Identifiable {
    enum Kind {
        case edit(SavedPassword)
        case new(command: String, prompt: String)
    }

    let id = UUID()
    let kind: Kind

    static func edit(_ entry: SavedPassword) -> PasswordEditorRequest {
        PasswordEditorRequest(kind: .edit(entry))
    }

    static func new(command: String = "", prompt: String = "") -> PasswordEditorRequest {
        PasswordEditorRequest(kind: .new(command: command, prompt: prompt))
    }
}

/// One password, untruncated and editable: the command exactly as the
/// process table reported it (the list shows a shortened form), the prompt
/// line, and the password itself. A saved password is shown behind the same
/// authentication Autofill uses and becomes a field once shown; a new one is
/// typed into a secure field. Nothing is written until Save; Cancel discards
/// every edit. Save files the entry under the edited command and prompt
/// through the rules detection applies (`PasswordPromptIdentity
/// .declaredEntryID`), so an edit lands where the next prompt will look. A
/// revealed password lives only in this sheet's state and goes with it.
///
/// The command is required; the prompt is not, and without one the entry is
/// filled only from the palette's Password Manager, never offered at a
/// prompt (`PasswordEntryID.isOnDemandOnly`). Entries filed under a prompt
/// alone are detection's own — a key passphrase belongs to the key whatever
/// asks, a `read -s` to the shell — so one can be edited as it is, but none
/// is created here, nor made by clearing a command.
struct PasswordEditorSheet: View {
    let request: PasswordEditorRequest
    let vault: PasswordVault

    private enum Field: Hashable {
        case command
        case password
    }

    @Environment(\.dismiss) private var dismiss
    @State private var command: String
    @State private var prompt: String
    /// The password as shown and edited: a saved one is nil until revealed,
    /// a new one starts empty.
    @State private var password: String?
    /// What the store held when revealed, to tell an edit from a look.
    @State private var storedPassword: String?
    @State private var busy = false
    @State private var problem: String?
    @FocusState private var focus: Field?

    init(request: PasswordEditorRequest, vault: PasswordVault) {
        self.request = request
        self.vault = vault
        switch request.kind {
        case let .edit(entry):
            _command = State(initialValue: entry.id.command ?? "")
            _prompt = State(initialValue: entry.id.prompt)
        case let .new(command, prompt):
            _command = State(initialValue: command)
            _prompt = State(initialValue: prompt)
            _password = State(initialValue: "")
        }
    }

    private var entry: SavedPassword? {
        if case let .edit(entry) = request.kind { entry } else { nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Command", text: $command, prompt: Text(isPromptOnly ? "Any command" : "Required"))
                        .font(.body.monospaced())
                        .focused($focus, equals: .command)
                    TextField("Prompt", text: $prompt, prompt: Text("None — fill from the palette only"))
                        .font(.body.monospaced())
                    passwordRow
                    if let modified = entry?.modified {
                        LabeledContent("Saved") {
                            Text(modified, format: .dateTime.year().month().day().hour().minute())
                        }
                    }
                } header: {
                    if entry == nil { Text("New Password") }
                } footer: {
                    Text(problem ?? caption)
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
        .onAppear {
            // A new entry opened with its command or prompt already named
            // (the palette's "Add Password for …") is waiting for the password.
            guard entry == nil else { return }
            focus = command.isEmpty && prompt.isEmpty ? .command : .password
        }
    }

    private static let rule = "Autofill is offered when both the command and the prompt match. "
        + "Without a prompt, the password is never offered at a prompt; pick it from Password Manager "
        + "in the command palette."

    private var caption: String {
        if isPromptOnly { return "Saved for this prompt from any command. " + Self.rule }
        // A key passphrase prompt files under the key, whatever command was typed.
        if !command.trimmingCharacters(in: .whitespaces).isEmpty, proposedID.command == nil {
            return "A key passphrase is saved from its prompt: type it there once and save it."
        }
        return Self.rule
    }

    /// An entry detection filed under its prompt alone, being edited.
    private var isPromptOnly: Bool {
        guard let entry else { return false }
        return entry.id.command == nil
    }

    @ViewBuilder
    private var passwordRow: some View {
        if entry == nil {
            SecureField("Password", text: Binding(get: { password ?? "" }, set: { password = $0 }))
                .font(.body.monospaced())
                .focused($focus, equals: .password)
        } else {
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
        }
    }

    /// Where the edited entry will be filed — through detection's own rules,
    /// so `sudo apt update` still collapses to `sudo` and a key passphrase
    /// still drops its command.
    ///
    /// An entry whose command and prompt weren't touched stays exactly where
    /// it is: detection files some entries under identities the declared
    /// rules would collapse — a passphrase asked by a replaceable program is
    /// filed under that program, a `~/bin/sudo` under its own path — and
    /// re-deriving them would move a password-only edit onto the shared
    /// entry those programs must never be offered.
    private var proposedID: PasswordEntryID {
        Self.filing(command: command, prompt: prompt, editing: entry?.id)
    }

    static func filing(command: String, prompt: String, editing current: PasswordEntryID?) -> PasswordEntryID {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let normalizedPrompt = PasswordPromptIdentity.normalize(prompt)
        if let current, trimmed == (current.command ?? ""), normalizedPrompt == current.prompt {
            return current
        }
        return PasswordPromptIdentity.declaredEntryID(
            prompt: normalizedPrompt,
            command: trimmed.isEmpty ? nil : trimmed
        )
    }

    private var passwordChanged: Bool {
        guard let password else { return false }
        return password != storedPassword
    }

    private var hasChanges: Bool {
        guard let entry else { return true }
        return proposedID != entry.id || passwordChanged
    }

    private var isValid: Bool {
        let id = proposedID
        guard id.command != nil || (isPromptOnly && !id.prompt.isEmpty) else { return false }
        if entry == nil { return !(password ?? "").isEmpty }
        return password.map { !$0.isEmpty } ?? true
    }

    private func reveal() {
        guard let entry else { return }
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
        if newID != entry?.id, vault.contains(newID) {
            problem = "A password is already saved for that command and prompt."
            return
        }
        guard let entry else {
            if vault.save(password ?? "", for: newID) {
                dismiss()
            } else {
                problem = vault.lastError ?? "Couldn’t save the password."
            }
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
