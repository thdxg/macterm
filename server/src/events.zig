//! The session's own events (design/003 §5, design/004 §6).
//!
//! `Watch` holds the session's terminal and listens to what the terminal
//! parses: the title, the cwd, the OSC 133 marks, the OSC 9;4 progress and
//! the bell. It coalesces them (the rules are on `messages.coalesce_ms`),
//! derives the run status, and keeps the events in `ready`, in order, until
//! the session sends them. The foreground is the session's: it reads the pty,
//! not the terminal.
//!
//! Nothing here reads a clock: each call takes the time in milliseconds, so
//! the tests drive time by hand.

const std = @import("std");
const terminal = @import("terminal.zig");
const protocol = @import("protocol/protocol.zig");
const ghostty_vt = terminal.ghostty_vt;
const m = protocol.messages;

const Handler = ghostty_vt.TerminalStream.Handler;
const SemanticPrompt = Handler.SemanticPrompt;
const ProgressReport = ghostty_vt.osc.Command.ProgressReport;

/// One event that waits to go out. The slices belong to the `Watch`.
pub const Event = union(enum) {
    title: []const u8,
    cwd: []const u8,
    mark: struct { kind: m.MarkKind, command: ?[]const u8 = null, exit_code: ?i32 = null },
    progress: m.Progress,
    bell,
    activity,
    status: m.Status,
};

/// The values that coalesce.
const Key = enum { title, cwd, progress, bell };

const Hold = struct {
    /// When the last one went out.
    sent_at: ?i64 = null,
    /// A newer one waits for the end of the window.
    held: bool = false,
};

pub const Watch = struct {
    gpa: std.mem.Allocator,
    term: ghostty_vt.Terminal,
    ready: std.ArrayList(Event) = .empty,
    /// The time of the bytes that the terminal parses now.
    now_ms: i64 = 0,
    holds: [std.enums.values(Key).len]Hold = @splat(.{}),
    activity_at: ?i64 = null,
    /// The last progress report; null after `remove`.
    progress: ?m.Progress = null,
    status: m.Status = .{ .state = .idle },
    /// A progress report started the run, not a mark.
    run_by_progress: bool = false,
    /// The command that runs now, for its `end` mark.
    command: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, term: ghostty_vt.Terminal) Watch {
        return .{ .gpa = gpa, .term = term };
    }

    pub fn deinit(w: *Watch) void {
        w.clearReady();
        w.ready.deinit(w.gpa);
        if (w.command) |c| w.gpa.free(c);
        w.term.deinit(w.gpa);
    }

    /// Connects the terminal's effects to this watch. `handler` must parse
    /// into `w.term`, and `w` must not move after this.
    pub fn install(w: *Watch, handler: *Handler) void {
        std.debug.assert(handler.terminal == &w.term);
        handler.effects.title_changed = &onTitle;
        handler.effects.pwd_changed = &onPwd;
        handler.effects.bell = &onBell;
        handler.effects.progress_report = &onProgress;
        handler.effects.semantic_prompt = &onSemanticPrompt;
        handler.effects.reset = &onReset;
    }

    /// Parses pty output at time `now`.
    pub fn feed(w: *Watch, stream: anytype, data: []const u8, now: i64) void {
        w.now_ms = now;
        stream.nextSlice(data);
        if (data.len == 0) return;
        if (w.activity_at) |at| if (now - at < m.activity_ms) return;
        w.activity_at = now;
        w.push(.activity);
    }

    /// Sends the held values whose window ended by `now`.
    pub fn flush(w: *Watch, now: i64) void {
        w.now_ms = now;
        for (&w.holds, 0..) |*h, i| {
            if (!h.held or now - h.sent_at.? < m.coalesce_ms) continue;
            h.held = false;
            h.sent_at = now;
            w.emit(@enumFromInt(i));
        }
    }

    /// When the next held value is due, or null when none waits.
    pub fn deadline(w: *const Watch) ?i64 {
        var next: ?i64 = null;
        for (w.holds) |h| {
            if (!h.held) continue;
            const due = h.sent_at.? + m.coalesce_ms;
            next = if (next) |n| @min(n, due) else due;
        }
        return next;
    }

    /// The events that tell a new client the current state, into `out`.
    /// The slices belong to the terminal and stay valid until it parses.
    pub fn current(w: *Watch, out: *std.ArrayList(Event)) !void {
        if (w.term.getTitle()) |t| if (t.len > 0) try out.append(w.gpa, .{ .title = t });
        if (w.term.getPwd()) |p| if (p.len > 0) try out.append(w.gpa, .{ .cwd = p });
        if (w.progress) |p| try out.append(w.gpa, .{ .progress = p });
        if (w.status.state != .idle) try out.append(w.gpa, .{ .status = w.status });
    }

    /// Frees the events that went out.
    pub fn clearReady(w: *Watch) void {
        for (w.ready.items) |e| freeEvent(w.gpa, e);
        w.ready.clearRetainingCapacity();
    }

    fn push(w: *Watch, e: Event) void {
        w.ready.append(w.gpa, e) catch {
            std.log.warn("event dropped: out of memory", .{});
            freeEvent(w.gpa, e);
        };
    }

    /// The first value in a quiet period goes at once; later ones wait for
    /// the end of the window, where the newest goes.
    fn coalesce(w: *Watch, key: Key) void {
        const h = &w.holds[@intFromEnum(key)];
        if (h.sent_at) |at| if (w.now_ms - at < m.coalesce_ms) {
            h.held = true;
            return;
        };
        h.sent_at = w.now_ms;
        h.held = false;
        w.emit(key);
    }

    fn emit(w: *Watch, key: Key) void {
        switch (key) {
            .title => w.pushCopy(.title, w.term.getTitle() orelse ""),
            .cwd => w.pushCopy(.cwd, w.term.getPwd() orelse ""),
            .progress => w.push(.{ .progress = w.progress orelse .{ .state = .remove } }),
            .bell => w.push(.bell),
        }
    }

    fn pushCopy(w: *Watch, comptime tag: std.meta.Tag(Event), value: []const u8) void {
        const copy = w.gpa.dupe(u8, value) catch return;
        w.push(@unionInit(Event, @tagName(tag), copy));
    }

    fn setStatus(w: *Watch, state: m.RunState, failed: bool) void {
        if (w.status.state == state and w.status.failed == failed) return;
        w.status = .{ .state = state, .failed = failed };
        w.push(.{ .status = w.status });
    }

    fn startRun(w: *Watch, by_progress: bool) void {
        if (w.status.state == .running) return;
        w.run_by_progress = by_progress;
        w.setStatus(.running, false);
    }

    fn mark(w: *Watch, e: SemanticPrompt) void {
        switch (e.kind) {
            .prompt_start => {
                // A continuation or right prompt is part of the same prompt.
                if (e.prompt_kind != .primary) return;
                w.push(.{ .mark = .{ .kind = .prompt } });
            },
            .input_start => w.push(.{ .mark = .{ .kind = .input } }),
            .output_start => {
                w.setCommand(if (e.command.len > 0) w.gpa.dupe(u8, e.command) catch null else inputText(w.gpa, &w.term));
                w.push(.{ .mark = .{ .kind = .output, .command = w.dupeCommand() } });
                w.startRun(false);
            },
            .command_end => {
                w.push(.{ .mark = .{ .kind = .end, .command = w.dupeCommand(), .exit_code = e.exit_code } });
                w.setCommand(null);
                if (w.status.state == .running) w.setStatus(.done, false);
            },
            else => {},
        }
    }

    fn setCommand(w: *Watch, command: ?[]u8) void {
        if (w.command) |c| w.gpa.free(c);
        w.command = command;
    }

    fn dupeCommand(w: *Watch) ?[]const u8 {
        const c = w.command orelse return null;
        return w.gpa.dupe(u8, c) catch null;
    }

    fn report(w: *Watch, r: ProgressReport) void {
        const state: m.ProgressState = switch (r.state) {
            .remove => .remove,
            .set => .set,
            .@"error" => .@"error",
            .indeterminate => .indeterminate,
            .pause => .pause,
        };
        w.progress = if (state == .remove) null else .{ .state = state, .percent = r.progress };
        w.coalesce(.progress);
        switch (state) {
            .set, .indeterminate => w.startRun(true),
            // v1's rule: error ends the run as a failure, whatever started it.
            .@"error" => if (w.status.state == .running) w.setStatus(.done, true),
            // Remove and pause end only a run that a report started: a
            // command that 133;C started ends at 133;D.
            .remove, .pause => if (w.status.state == .running and w.run_by_progress) w.setStatus(.done, false),
            .unknown => {},
        }
    }

    fn fromHandler(h: *Handler) *Watch {
        return @fieldParentPtr("term", h.terminal);
    }

    fn onTitle(h: *Handler) void {
        fromHandler(h).coalesce(.title);
    }

    fn onPwd(h: *Handler) void {
        fromHandler(h).coalesce(.cwd);
    }

    fn onBell(h: *Handler) void {
        fromHandler(h).coalesce(.bell);
    }

    fn onProgress(h: *Handler, r: ProgressReport) void {
        fromHandler(h).report(r);
    }

    fn onSemanticPrompt(h: *Handler, e: SemanticPrompt) void {
        fromHandler(h).mark(e);
    }

    /// A full reset clears the title and the cwd with no callback, and ends
    /// the current command with no 133;D.
    fn onReset(h: *Handler) void {
        const w = fromHandler(h);
        w.coalesce(.title);
        w.coalesce(.cwd);
        w.setCommand(null);
    }
};

fn freeEvent(gpa: std.mem.Allocator, e: Event) void {
    switch (e) {
        .title, .cwd => |s| gpa.free(s),
        .mark => |mk| if (mk.command) |c| gpa.free(c),
        else => {},
    }
}

/// The text of the input cells from the prompt above the cursor to the
/// cursor: what the user typed, with no prompt text, a line for each row
/// that does not wrap. Null when the screen has no prompt or no input.
///
/// Not `PageList.highlightSemanticContent`: it ends the input at the first
/// output cell, and the empty cells after the first row of a command that
/// spans rows are output cells.
pub fn inputText(gpa: std.mem.Allocator, term: *ghostty_vt.Terminal) ?[]u8 {
    const screen = term.screens.active;
    // With no prompt ever seen, the search below walks the whole screen.
    if (!screen.semantic_prompt.seen) return null;
    const cursor = screen.cursor.page_pin.*;
    var prompts = cursor.promptIterator(.left_up, null);
    const prompt = prompts.next() orelse return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var cells = prompt.cellIterator(.right_down, cursor);
    var last: ?ghostty_vt.Pin = null;
    while (cells.next()) |p| {
        if (last) |l| if (l.node != p.node or l.y != p.y) {
            trimEndSpaces(&out);
            if (!l.rowAndCell().row.wrap) out.append(gpa, '\n') catch return null;
        };
        last = p;
        const rac = p.rowAndCell();
        const cell = rac.cell;
        if (cell.semantic_content != .input) continue;
        if (cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;
        if (!cell.hasText()) {
            out.append(gpa, ' ') catch return null;
            continue;
        }
        appendCodepoint(gpa, &out, cell.codepoint()) catch return null;
        if (cell.hasGrapheme()) if (p.grapheme(cell)) |cps| {
            for (cps) |cp| appendCodepoint(gpa, &out, cp) catch return null;
        };
    }
    const text = std.mem.trim(u8, out.items, " \n");
    if (text.len == 0) {
        out.deinit(gpa);
        return null;
    }
    const result = gpa.dupe(u8, text) catch null;
    out.deinit(gpa);
    return result;
}

fn trimEndSpaces(out: *std.ArrayList(u8)) void {
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
}

fn appendCodepoint(gpa: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try out.appendSlice(gpa, buf[0..n]);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A watch on a small terminal, and a stream that parses into it.
const Fixture = struct {
    w: Watch,
    stream: ghostty_vt.TerminalStream,

    fn init(f: *Fixture) !void {
        f.w = .init(testing.allocator, try ghostty_vt.Terminal.init(testing.io, testing.allocator, .{ .cols = 40, .rows = 8 }));
        f.stream = f.w.term.vtStream();
        f.w.install(&f.stream.handler);
    }

    fn deinit(f: *Fixture) void {
        f.stream.deinit();
        f.w.deinit();
    }

    fn feed(f: *Fixture, data: []const u8, now: i64) void {
        f.w.feed(&f.stream, data, now);
    }

    /// The events that are ready, minus the heartbeat, as tags.
    fn tags(f: *Fixture) ![]std.meta.Tag(Event) {
        var out: std.ArrayList(std.meta.Tag(Event)) = .empty;
        for (f.w.ready.items) |e| if (e != .activity) try out.append(testing.allocator, e);
        return out.toOwnedSlice(testing.allocator);
    }

    fn only(f: *Fixture, comptime tag: std.meta.Tag(Event)) ![]@FieldType(Event, @tagName(tag)) {
        var out: std.ArrayList(@FieldType(Event, @tagName(tag))) = .empty;
        for (f.w.ready.items) |e| if (e == tag) try out.append(testing.allocator, @field(e, @tagName(tag)));
        return out.toOwnedSlice(testing.allocator);
    }
};

test "events: a title, a cwd and a bell go out at once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]2;vim notes\x07\x1b]7;file://host/tmp/a%20b\x07\x07", 0);
    const titles = try f.only(.title);
    defer testing.allocator.free(titles);
    try testing.expectEqual(1, titles.len);
    try testing.expectEqualStrings("vim notes", titles[0]);
    const cwds = try f.only(.cwd);
    defer testing.allocator.free(cwds);
    try testing.expectEqualStrings("file://host/tmp/a%20b", cwds[0]);
    const tags = try f.tags();
    defer testing.allocator.free(tags);
    try testing.expectEqualSlices(std.meta.Tag(Event), &.{ .title, .cwd, .bell }, tags);
}

test "events: a title flood coalesces to the first and the newest" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    for (0..1000) |i| f.feed(try std.fmt.bufPrint(&buf, "\x1b]0;title {d}\x07", .{i}), 3);
    try testing.expectEqual(3 + m.coalesce_ms, f.w.deadline().?);
    // Not yet: the window is still open.
    f.w.flush(3 + m.coalesce_ms - 1);
    var titles = try f.only(.title);
    try testing.expectEqual(1, titles.len);
    try testing.expectEqualStrings("title 0", titles[0]);
    testing.allocator.free(titles);

    f.w.flush(3 + m.coalesce_ms);
    titles = try f.only(.title);
    defer testing.allocator.free(titles);
    try testing.expectEqual(2, titles.len);
    try testing.expectEqualStrings("title 999", titles[1]);
    try testing.expectEqual(null, f.w.deadline());
}

test "events: a title after a quiet window goes at once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]2;a\x07", 0);
    f.feed("\x1b]2;b\x07", m.coalesce_ms);
    const titles = try f.only(.title);
    defer testing.allocator.free(titles);
    try testing.expectEqual(2, titles.len);
    try testing.expectEqual(null, f.w.deadline());
}

test "events: the heartbeat goes once in its window and drops the rest" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("a", 0);
    f.feed("b", 10);
    f.feed("c", m.activity_ms - 1);
    f.feed("d", m.activity_ms);
    var n: usize = 0;
    for (f.w.ready.items) |e| {
        if (e == .activity) n += 1;
    }
    try testing.expectEqual(2, n);
    try testing.expectEqual(null, f.w.deadline());
}

test "events: marks carry the command and the exit code, and the status follows" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // A shell that sends no command line: the input cells give it.
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07make  test\r\n\x1b]133;C\x07", 0);
    f.feed("ok\r\n\x1b]133;D;2\x07", 1);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    try testing.expectEqual(4, marks.len);
    try testing.expectEqual(.prompt, marks[0].kind);
    try testing.expectEqual(.input, marks[1].kind);
    try testing.expectEqual(.output, marks[2].kind);
    try testing.expectEqualStrings("make  test", marks[2].command.?);
    try testing.expectEqual(.end, marks[3].kind);
    try testing.expectEqualStrings("make  test", marks[3].command.?);
    try testing.expectEqual(2, marks[3].exit_code.?);

    const statuses = try f.only(.status);
    defer testing.allocator.free(statuses);
    try testing.expectEqual(2, statuses.len);
    try testing.expectEqual(.running, statuses[0].state);
    // A nonzero exit is not a failed run.
    try testing.expectEqual(m.Status{ .state = .done }, statuses[1]);
}

test "events: the shell's own command line wins over the input cells" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C;cmdline_url=ls%20-la\x07", 0);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    try testing.expectEqualStrings("ls -la", marks[2].command.?);
}

test "events: a command typed over two rows reads as two lines, without the continuation prompt" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07echo a \\\r\n\x1b]133;P;k=c\x07> \x1b]133;B\x07b\r\n\x1b]133;C\x07", 0);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    // The continuation prompt is no `prompt` mark.
    try testing.expectEqual(.prompt, marks[0].kind);
    try testing.expectEqual(.input, marks[1].kind);
    try testing.expectEqual(.input, marks[2].kind);
    try testing.expectEqual(.output, marks[3].kind);
    try testing.expectEqualStrings("echo a \\\nb", marks[3].command.?);
}

test "events: an end with no command running changes no status" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;D;0\x07\x1b]133;A\x07$ ", 0);
    const statuses = try f.only(.status);
    defer testing.allocator.free(statuses);
    try testing.expectEqual(0, statuses.len);
    try testing.expectEqual(.idle, f.w.status.state);
}

test "events: progress error ends the run as failed, and remove keeps it red" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]9;4;1;40\x07", 0);
    f.feed("\x1b]9;4;2\x07", 100);
    f.feed("\x1b]9;4;0\x07", 200);
    const statuses = try f.only(.status);
    defer testing.allocator.free(statuses);
    try testing.expectEqual(2, statuses.len);
    try testing.expectEqual(.running, statuses[0].state);
    try testing.expectEqual(m.Status{ .state = .done, .failed = true }, statuses[1]);
    const reports = try f.only(.progress);
    defer testing.allocator.free(reports);
    try testing.expectEqual(3, reports.len);
    try testing.expectEqual(m.Progress{ .state = .set, .percent = 40 }, reports[0]);
    try testing.expectEqual(.@"error", reports[1].state);
    try testing.expectEqual(.remove, reports[2].state);
    try testing.expectEqual(null, f.w.progress);
}

test "events: progress remove ends only a run that a report started" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07cargo build\r\n\x1b]133;C\x07", 0);
    f.feed("\x1b]9;4;3\x07", 100);
    f.feed("\x1b]9;4;0\x07", 200);
    try testing.expectEqual(.running, f.w.status.state);
    f.feed("\x1b]133;D;0\x07", 300);
    try testing.expectEqual(m.Status{ .state = .done }, f.w.status);

    // With no mark, set then remove is a whole run.
    f.feed("\x1b]9;4;1;5\x07", 400);
    try testing.expectEqual(.running, f.w.status.state);
    f.feed("\x1b]9;4;0\x07", 500);
    try testing.expectEqual(m.Status{ .state = .done }, f.w.status);
}

test "events: a new client gets the current state" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var out: std.ArrayList(Event) = .empty;
    defer out.deinit(testing.allocator);
    try f.w.current(&out);
    try testing.expectEqual(0, out.items.len);

    f.feed("\x1b]2;htop\x07\x1b]7;file:///srv\x07\x1b]9;4;1;70\x07", 0);
    try f.w.current(&out);
    try testing.expectEqual(4, out.items.len);
    try testing.expectEqualStrings("htop", out.items[0].title);
    try testing.expectEqualStrings("file:///srv", out.items[1].cwd);
    try testing.expectEqual(m.Progress{ .state = .set, .percent = 70 }, out.items[2].progress);
    try testing.expectEqual(.running, out.items[3].status.state);
}

test "events: a full reset sends an empty title and cwd" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]2;x\x07", 0);
    f.feed("\x1bc", 100);
    const titles = try f.only(.title);
    defer testing.allocator.free(titles);
    try testing.expectEqual(2, titles.len);
    try testing.expectEqualStrings("", titles[1]);
}
