import ArgumentParser

/// `macterm palette` — the custom command-palette files
/// (`~/.config/macterm/palettes/*.yaml`).
struct PaletteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "palette",
        abstract: "List custom command-palette files and whether each reads.",
        subcommands: [List.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the palette files in ~/.config/macterm/palettes with their name, state and any error."
        )

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "palette.list", args: ControlArgs(), options: options)
        }
    }
}
