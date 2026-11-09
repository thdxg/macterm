//! The session's own events (design/003 §5, design/004 §6).
//!
//! `Watch` holds the session's terminal and listens to what the terminal
//! parses: the title, the cwd, the OSC 133 marks, the OSC 9;4 progress, the
//! OSC 7501 program status and the bell. It coalesces them (the rules are on `messages.coalesce_ms`),
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
const ProgramStatus = ghostty_vt.osc.Command.ProgramStatus;
const program_status = ghostty_vt.osc.program_status;

/// One event that waits to go out. The slices belong to the `Watch`.
pub const Event = union(enum) {
    title: []const u8,
    cwd: []const u8,
    mark: struct { kind: m.MarkKind, command: ?[]const u8 = null, exit_code: ?i32 = null },
    progress: m.Progress,
    bell,
    activity,
    status: m.Status,
    /// Every program status record, from `Watch.programRecords`.
    program: []m.ProgramRecord,
};

/// The values that coalesce.
const Key = enum { title, cwd, progress, program, bell };

/// A program status record, and when it last changed.
const Record = struct {
    rec: m.ProgramRecord,
    changed: u64,
};

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
    /// An input mark came, and no output or end mark since: the input
    /// cells above the cursor are the user's command.
    at_input: bool = false,
    /// The program status records (OSC 7501), oldest first. Their slices
    /// belong to the watch.
    records: std.ArrayList(Record) = .empty,
    /// Counts the record changes, to find the least recently changed one.
    record_seq: u64 = 0,
    /// Bytes for the pty: the reply to an OSC 7501 support query.
    reply: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, term: ghostty_vt.Terminal) Watch {
        return .{ .gpa = gpa, .term = term };
    }

    pub fn deinit(w: *Watch) void {
        w.clearReady();
        w.ready.deinit(w.gpa);
        if (w.command) |c| w.gpa.free(c);
        for (w.records.items) |r| freeRecord(w.gpa, r.rec);
        w.records.deinit(w.gpa);
        w.reply.deinit(w.gpa);
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
        // Also makes the terminal answer the OSC 7501 support query.
        handler.effects.program_status = &onProgramStatus;
        handler.effects.write_pty = &onWritePty;
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
    /// The slices belong to the terminal and stay valid until it parses,
    /// except the `program` records: free them with `freeProgram`.
    pub fn current(w: *Watch, out: *std.ArrayList(Event)) !void {
        if (w.term.getTitle()) |t| if (t.len > 0) try out.append(w.gpa, .{ .title = t });
        if (w.term.getPwd()) |p| if (p.len > 0) try out.append(w.gpa, .{ .cwd = p });
        if (w.progress) |p| try out.append(w.gpa, .{ .progress = p });
        if (w.status.state != .idle) try out.append(w.gpa, .{ .status = w.status });
        if (w.records.items.len > 0) {
            const records = try w.programRecords();
            out.append(w.gpa, .{ .program = records }) catch |err| {
                freeProgram(w.gpa, records);
                return err;
            };
        }
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
            .program => w.push(.{ .program = w.programRecords() catch return }),
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
                w.at_input = false;
                w.endPromptRecords();
                // A new prompt ends the command, also when the shell sent no
                // 133;D (after a full reset, for one).
                if (w.status.state == .running and !w.run_by_progress) {
                    w.setCommand(null);
                    w.setStatus(.done, false);
                }
                w.push(.{ .mark = .{ .kind = .prompt } });
            },
            .input_start => {
                w.at_input = true;
                w.push(.{ .mark = .{ .kind = .input } });
            },
            .output_start => {
                // A 133;C with no input mark before it (in a file that
                // `cat` prints) has no command to read.
                const command = if (e.command.len > 0)
                    w.gpa.dupe(u8, e.command) catch null
                else if (w.at_input)
                    inputText(w.gpa, &w.term)
                else
                    null;
                w.at_input = false;
                w.setCommand(command);
                w.push(.{ .mark = .{ .kind = .output, .command = w.dupeCommand() } });
                w.startRun(false);
                // The command owns the run now: a progress report that
                // started it does not end it.
                w.run_by_progress = false;
            },
            .command_end => {
                w.at_input = false;
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

    /// Applies one report: a `clear` removes the record and the records
    /// under it (every record with no id), any other state replaces the
    /// record.
    fn programReport(w: *Watch, r: ProgramStatus.Report) void {
        const id = r.readOption(.id) orelse "";
        if (r.state == .clear) {
            if (!w.removeRecords(id, .clear)) return;
        } else {
            w.putRecord(id, r) catch {
                std.log.warn("program status dropped: out of memory", .{});
                return;
            };
        }
        w.coalesce(.program);
    }

    fn putRecord(w: *Watch, id: []const u8, r: ProgramStatus.Report) !void {
        var rec: m.ProgramRecord = .{
            .state = switch (r.state) {
                .idle => .idle,
                .working => .working,
                .done => .done,
                .blocked => .blocked,
                .@"error" => .@"error",
                .clear => unreachable,
            },
            .kind = if (r.readOption(.kind)) |k| switch (k) {
                .permission => .permission,
                .question => .question,
                .auth => .auth,
            } else null,
            .progress = r.readOption(.progress),
        };
        errdefer freeRecord(w.gpa, rec);
        rec.id = try w.gpa.dupe(u8, id);
        if (r.readOption(.app)) |a| rec.app = try w.gpa.dupe(u8, a);
        rec.title = try decodeText(w.gpa, r, .title);
        rec.msg = try decodeText(w.gpa, r, .msg);

        w.record_seq += 1;
        for (w.records.items) |*old| if (std.mem.eql(u8, old.rec.id, id)) {
            freeRecord(w.gpa, old.rec);
            old.* = .{ .rec = rec, .changed = w.record_seq };
            return;
        };
        try w.records.ensureUnusedCapacity(w.gpa, 1);
        if (w.records.items.len >= m.max_program_records) {
            var oldest: usize = 0;
            for (w.records.items, 0..) |o, i| {
                if (o.changed < w.records.items[oldest].changed) oldest = i;
            }
            freeRecord(w.gpa, w.records.orderedRemove(oldest).rec);
        }
        w.records.appendAssumeCapacity(.{ .rec = rec, .changed = w.record_seq });
    }

    const Removal = enum {
        /// The record `id` and the records under it; every record for "".
        clear,
        /// The records of a program that no longer runs.
        prompt,
    };

    /// True if a record went.
    fn removeRecords(w: *Watch, id: []const u8, how: Removal) bool {
        var removed = false;
        var i: usize = 0;
        while (i < w.records.items.len) {
            const rec = w.records.items[i].rec;
            const goes = switch (how) {
                .clear => id.len == 0 or (std.mem.startsWith(u8, rec.id, id) and
                    (rec.id.len == id.len or rec.id[id.len] == '/')),
                // `working` and `blocked` must go at a new shell prompt;
                // `idle` may, and goes, so that no record outlives its
                // program. `done` and `error` wait for the user.
                .prompt => rec.state != .done and rec.state != .@"error",
            };
            if (!goes) {
                i += 1;
                continue;
            }
            freeRecord(w.gpa, w.records.orderedRemove(i).rec);
            removed = true;
        }
        return removed;
    }

    fn endPromptRecords(w: *Watch) void {
        if (w.removeRecords("", .prompt)) w.coalesce(.program);
    }

    /// A copy of every record, with the `app` that each one inherits.
    fn programRecords(w: *Watch) ![]m.ProgramRecord {
        const out = try w.gpa.alloc(m.ProgramRecord, w.records.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| freeRecord(w.gpa, r);
            w.gpa.free(out);
        }
        for (w.records.items) |r| {
            const app = w.inheritedApp(r.rec.id);
            out[n] = try dupeRecord(w.gpa, r.rec, app);
            n += 1;
        }
        return out;
    }

    /// The `app` of the record `id`, else of its nearest ancestor that has
    /// one. The root record is the ancestor of every other record.
    fn inheritedApp(w: *const Watch, id: []const u8) ?[]const u8 {
        var at: ?[]const u8 = id;
        while (at) |path| {
            for (w.records.items) |r| if (std.mem.eql(u8, r.rec.id, path)) {
                if (r.rec.app) |a| return a;
                break;
            };
            at = if (path.len == 0)
                null
            else if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash|
                path[0..slash]
            else
                "";
        }
        return null;
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

    fn onProgramStatus(h: *Handler, r: ProgramStatus.Report) void {
        fromHandler(h).programReport(r);
    }

    /// Keeps only the OSC 7501 support reply. The terminal of the client that
    /// shows the pane answers every other query, and a second answer would
    /// reach the program as input. That terminal does not answer this one.
    fn onWritePty(h: *Handler, data: []const u8) void {
        if (!std.mem.startsWith(u8, data, "\x1b]7501;")) return;
        const w = fromHandler(h);
        w.reply.appendSlice(w.gpa, data) catch {};
    }

    fn onSemanticPrompt(h: *Handler, e: SemanticPrompt) void {
        fromHandler(h).mark(e);
    }

    /// A full reset clears the title and the cwd with no callback. The run
    /// ends at the next 133;D or prompt. The terminal cleared the program
    /// status records before this, through `onProgramStatus`.
    fn onReset(h: *Handler) void {
        const w = fromHandler(h);
        w.coalesce(.title);
        w.coalesce(.cwd);
    }
};

fn freeEvent(gpa: std.mem.Allocator, e: Event) void {
    switch (e) {
        .title, .cwd => |s| gpa.free(s),
        .mark => |mk| if (mk.command) |c| gpa.free(c),
        .program => |records| freeProgram(gpa, records),
        else => {},
    }
}

/// Frees the records of a `program` event.
pub fn freeProgram(gpa: std.mem.Allocator, records: []m.ProgramRecord) void {
    for (records) |r| freeRecord(gpa, r);
    gpa.free(records);
}

fn freeRecord(gpa: std.mem.Allocator, r: m.ProgramRecord) void {
    gpa.free(r.id);
    if (r.app) |a| gpa.free(a);
    if (r.title) |t| gpa.free(t);
    if (r.msg) |t| gpa.free(t);
}

/// A copy of `r` that owns its slices, with `app` in place of its own.
fn dupeRecord(gpa: std.mem.Allocator, r: m.ProgramRecord, app: ?[]const u8) !m.ProgramRecord {
    var out: m.ProgramRecord = .{ .state = r.state, .kind = r.kind, .progress = r.progress };
    errdefer freeRecord(gpa, out);
    out.id = try gpa.dupe(u8, r.id);
    if (app) |a| out.app = try gpa.dupe(u8, a);
    if (r.title) |t| out.title = try gpa.dupe(u8, t);
    if (r.msg) |t| out.msg = try gpa.dupe(u8, t);
    return out;
}

/// The decoded text of `title` or `msg`, or null when the report has none.
fn decodeText(gpa: std.mem.Allocator, r: ProgramStatus.Report, comptime key: ProgramStatus.Option) !?[]u8 {
    if (r.readOption(key) == null) return null;
    var buf: [program_status.max_msg_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    r.writeText(key, &writer) catch unreachable;
    return try gpa.dupe(u8, writer.buffered());
}

/// The most rows above the cursor that `inputText` reads.
pub const max_input_rows = 100;

/// The text of the input cells from the prompt above the cursor to the
/// cursor: what the user typed, with no prompt text, a line for each row
/// that does not wrap. Null when no prompt starts in the `max_input_rows`
/// above the cursor, or when there is no input.
///
/// Not `PageList.highlightSemanticContent`: it ends the input at the first
/// output cell, and the empty cells after the first row of a command that
/// spans rows are output cells.
pub fn inputText(gpa: std.mem.Allocator, term: *ghostty_vt.Terminal) ?[]u8 {
    const screen = term.screens.active;
    // With no prompt ever seen, the search below walks the whole screen.
    if (!screen.semantic_prompt.seen) return null;
    const cursor = screen.cursor.page_pin.*;
    var prompts = cursor.promptIterator(.left_up, cursor.up(max_input_rows));
    const prompt = prompts.next() orelse return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var cells = prompt.cellIterator(.right_down, cursor);
    var last: ?ghostty_vt.Pin = null;
    while (cells.next()) |p| {
        if (last) |l| if (l.node != p.node or l.y != p.y) {
            // A space at the end of a row that wraps is part of the command.
            if (!l.rowAndCell().row.wrap) {
                trimEndSpaces(&out);
                out.append(gpa, '\n') catch return null;
            }
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
    f.feed("\x1b]2;x\x07\x1b]7;file:///a\x07", 0);
    f.feed("\x1bc", 100);
    const titles = try f.only(.title);
    defer testing.allocator.free(titles);
    try testing.expectEqual(2, titles.len);
    try testing.expectEqualStrings("", titles[1]);
    const cwds = try f.only(.cwd);
    defer testing.allocator.free(cwds);
    try testing.expectEqual(2, cwds.len);
    try testing.expectEqualStrings("", cwds[1]);
}

test "events: a new prompt ends a command that had no end mark" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07reset\r\n\x1b]133;C\x07\x1bc", 0);
    try testing.expectEqual(.running, f.w.status.state);
    f.feed("\x1b]133;A\x07$ ", 100);
    try testing.expectEqual(m.Status{ .state = .done }, f.w.status);
}

test "events: an output mark with no input mark before it reads no command" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07cat log\r\n\x1b]133;C\x07", 0);
    // The file that `cat` prints holds marks of its own.
    f.feed("\x1b]133;C\x07old output\r\n", 1);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    try testing.expectEqualStrings("cat log", marks[2].command.?);
    try testing.expectEqual(null, marks[3].command);
}

test "events: a command that wraps keeps the space at the end of the row" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // 40 columns: "$ " and 37 characters, then a space in the last column.
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa b\r\n\x1b]133;C\x07", 0);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa b", marks[2].command.?);
}

test "events: an output mark after a progress report owns the run" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]9;4;3\x07\x1b]133;A\x07$ \x1b]133;B\x07make\r\n\x1b]133;C\x07", 0);
    f.feed("\x1b]9;4;0\x07", 100);
    try testing.expectEqual(.running, f.w.status.state);
    f.feed("\x1b]133;D;0\x07", 200);
    try testing.expectEqual(m.Status{ .state = .done }, f.w.status);
}

/// The records of the last `program` event that is ready.
fn lastProgram(f: *Fixture) ?[]m.ProgramRecord {
    var last: ?[]m.ProgramRecord = null;
    for (f.w.ready.items) |e| if (e == .program) {
        last = e.program;
    };
    return last;
}

fn programEvents(f: *Fixture) usize {
    var n: usize = 0;
    for (f.w.ready.items) |e| n += @intFromBool(e == .program);
    return n;
}

test "events: each program status state becomes a record" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]7501;state=working:app=cargo:progress=40:msg=QnVpbGRpbmc=\x1b\\", 0);
    var records = lastProgram(&f).?;
    try testing.expectEqual(1, records.len);
    try testing.expectEqualStrings("", records[0].id);
    try testing.expectEqual(.working, records[0].state);
    try testing.expectEqual(40, records[0].progress.?);
    try testing.expectEqualStrings("cargo", records[0].app.?);
    try testing.expectEqualStrings("Building", records[0].msg.?);

    // A report replaces its record: no `app` now means none.
    f.feed("\x1b]7501;state=blocked:kind=permission:msg=QWxsb3cgZWRpdD8=\x07", m.coalesce_ms);
    records = lastProgram(&f).?;
    try testing.expectEqual(1, records.len);
    try testing.expectEqual(.blocked, records[0].state);
    try testing.expectEqual(.permission, records[0].kind.?);
    try testing.expectEqual(null, records[0].progress);
    try testing.expectEqual(null, records[0].app);
    try testing.expectEqualStrings("Allow edit?", records[0].msg.?);

    const cases = .{ .{ "done", m.ProgramState.done }, .{ "error", m.ProgramState.@"error" }, .{ "idle", m.ProgramState.idle } };
    inline for (cases, 2..) |c, i| {
        f.feed("\x1b]7501;state=" ++ c[0] ++ ":progress=50:kind=auth\x07", @intCast(i * m.coalesce_ms));
        records = lastProgram(&f).?;
        try testing.expectEqual(1, records.len);
        // Progress goes with working and blocked only, kind with blocked.
        try testing.expectEqual(c[1], records[0].state);
        try testing.expectEqual(null, records[0].kind);
        try testing.expectEqual(null, records[0].progress);
    }

    // A state that this build does not know changes nothing.
    const n = programEvents(&f);
    f.feed("\x1b]7501;state=sleeping\x07", 10 * m.coalesce_ms);
    try testing.expectEqual(n, programEvents(&f));
    try testing.expectEqual(.idle, f.w.records.items[0].rec.state);
}

test "events: program status records keep their ids, inherit app, and clear with their children" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]7501;state=working:app=deploy\x07" ++
        "\x1b]7501;state=working:id=deploy:title=dXMtZWFzdA==\x07" ++
        "\x1b]7501;state=blocked:id=deploy/eu:app=eu\x07" ++
        "\x1b]7501;state=done:id=deployer\x07", 0);
    f.w.flush(m.coalesce_ms);
    var records = lastProgram(&f).?;
    try testing.expectEqual(4, records.len);
    try testing.expectEqualStrings("deploy", records[1].id);
    try testing.expectEqualStrings("us-east", records[1].title.?);
    // A record with no `app` takes its nearest ancestor's, the root's here.
    try testing.expectEqualStrings("deploy", records[1].app.?);
    try testing.expectEqualStrings("eu", records[2].app.?);
    try testing.expectEqualStrings("deploy", records[3].app.?);
    // The stored record keeps its own value.
    try testing.expectEqual(null, f.w.records.items[1].rec.app);

    // A clear takes the record and the records under it, not `deployer`.
    f.feed("\x1b]7501;state=clear:id=deploy\x07", 2 * m.coalesce_ms);
    records = lastProgram(&f).?;
    try testing.expectEqual(2, records.len);
    try testing.expectEqualStrings("", records[0].id);
    try testing.expectEqualStrings("deployer", records[1].id);

    // A clear of a record that is not there sends nothing.
    const n = programEvents(&f);
    f.feed("\x1b]7501;state=clear:id=nothing\x07", 4 * m.coalesce_ms);
    try testing.expectEqual(n, programEvents(&f));

    // A clear with no id takes every record.
    f.feed("\x1b]7501;state=clear\x07", 6 * m.coalesce_ms);
    try testing.expectEqual(0, lastProgram(&f).?.len);
    try testing.expectEqual(0, f.w.records.items.len);
}

test "events: a full reset clears every program status record" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]7501;state=working\x07\x1b]7501;state=done:id=a\x07", 0);
    f.feed("\x1bc", 100);
    try testing.expectEqual(0, lastProgram(&f).?.len);
    try testing.expectEqual(0, f.w.records.items.len);
}

test "events: a new shell prompt removes the records of the program that ran" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]7501;state=working:id=a\x07\x1b]7501;state=blocked:id=b\x07" ++
        "\x1b]7501;state=idle:id=c\x07\x1b]7501;state=done:id=d\x07\x1b]7501;state=error:id=e\x07", 0);
    // A continuation prompt is the same prompt.
    f.feed("\x1b]133;P;k=c\x07", 100);
    try testing.expectEqual(5, f.w.records.items.len);
    f.feed("\x1b]133;A\x07$ ", 200);
    const records = lastProgram(&f).?;
    try testing.expectEqual(2, records.len);
    try testing.expectEqualStrings("d", records[0].id);
    try testing.expectEqualStrings("e", records[1].id);
}

test "events: program status reports coalesce to the first and the newest" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    for (0..100) |i| f.feed(try std.fmt.bufPrint(&buf, "\x1b]7501;state=working:progress={d}\x07", .{i}), 5);
    try testing.expectEqual(1, programEvents(&f));
    try testing.expectEqual(0, lastProgram(&f).?[0].progress.?);
    f.w.flush(5 + m.coalesce_ms);
    try testing.expectEqual(2, programEvents(&f));
    try testing.expectEqual(99, lastProgram(&f).?[0].progress.?);
}

test "events: past the most records, the one that changed least recently goes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    for (0..m.max_program_records) |i| f.feed(try std.fmt.bufPrint(&buf, "\x1b]7501;state=idle:id=r{d}\x07", .{i}), 0);
    // r0 changes, so r1 is now the oldest.
    f.feed("\x1b]7501;state=working:id=r0\x07", 0);
    f.feed("\x1b]7501;state=idle:id=new\x07", 0);
    try testing.expectEqual(m.max_program_records, f.w.records.items.len);
    try testing.expectEqualStrings("r0", f.w.records.items[0].rec.id);
    try testing.expectEqualStrings("r2", f.w.records.items[1].rec.id);
    try testing.expectEqualStrings("new", f.w.records.items[m.max_program_records - 1].rec.id);
}

test "events: the session answers the program status query and no other query" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b[c\x1b[6n\x1b]7501;?\x1b\\", 0);
    try testing.expectEqualStrings("\x1b]7501;" ++ program_status.query_reply ++ "\x1b\\", f.w.reply.items);
    f.w.reply.clearRetainingCapacity();
    f.feed("\x1b]7501;?\x07", 1);
    try testing.expectEqualStrings("\x1b]7501;" ++ program_status.query_reply ++ "\x07", f.w.reply.items);
}

test "events: a new client gets the program status records" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]7501;state=working:app=make\x07\x1b]7501;state=blocked:id=x:kind=question\x07", 0);
    var out: std.ArrayList(Event) = .empty;
    defer out.deinit(testing.allocator);
    try f.w.current(&out);
    defer for (out.items) |e| if (e == .program) freeProgram(testing.allocator, e.program);
    const records = out.items[out.items.len - 1].program;
    try testing.expectEqual(2, records.len);
    try testing.expectEqualStrings("make", records[1].app.?);
    try testing.expectEqual(.question, records[1].kind.?);
}
