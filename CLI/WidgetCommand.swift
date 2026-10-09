import ArgumentParser

/// `macterm widget` — terminals on the desktop (`DesktopWidget`).
struct WidgetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "widget",
        abstract: "List, add, edit and remove desktop widgets.",
        subcommands: [List.self, New.self, Change.self, Edit.self, Done.self, Remove.self],
        defaultSubcommand: List.self
    )

    /// The sizes, spelled as the socket takes them.
    static let sizeHelp = "Size as a grid span, COLUMNSxROWS, for example 3x2."

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List desktop widgets.")

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "widget.list", args: ControlArgs(), options: options)
        }
    }

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a locked desktop widget that runs your login shell, in the middle of the desktop."
        )

        @Option(help: ArgumentHelp(WidgetCommand.sizeHelp + " The default is 3x3."))
        var size: String?

        @Option(help: "A name for the widget. Settings and widgets.yaml show it.")
        var name: String?

        @Option(name: .customLong("run"), help: "Command to type into the shell of the widget each time that it starts a shell.")
        var runCommand: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = ControlArgs(name: name, run: runCommand)
            args.size = size
            try runControlCommand(command: "widget.new", args: args, options: options)
        }
    }

    struct Change: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Resize a desktop widget. It snaps to the desktop grid."
        )

        @Argument(help: "Widget (index, widget:N, or id).")
        var widget: String

        @Option(help: ArgumentHelp(WidgetCommand.sizeHelp))
        var size: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = ControlArgs()
            args.widget = widget
            args.size = size
            try runControlCommand(command: "widget.set", args: args, options: options)
        }
    }

    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Unlock a widget, so it takes input and you can move it and change its size. You can edit one widget at a time."
        )

        @Argument(help: "Widget (index, widget:N, or id).")
        var widget: String

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = ControlArgs()
            args.widget = widget
            try runControlCommand(command: "widget.edit", args: args, options: options)
        }
    }

    struct Done: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Lock the widget being edited.")

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "widget.done", args: ControlArgs(), options: options)
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a desktop widget and end its shell and session."
        )

        @Argument(help: "Widget (index, widget:N, or id).")
        var widget: String

        @Flag(help: "Remove even if a program is running in it.")
        var force = false

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = ControlArgs(force: force)
            args.widget = widget
            try runControlCommand(command: "widget.remove", args: args, options: options)
        }
    }
}
