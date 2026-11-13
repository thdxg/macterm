//! Tests of the model core: the shared tree fixtures, every tree operation,
//! the model's operations, validation, and the JSON file.

const std = @import("std");
const testing = std.testing;
const tree = @import("tree.zig");
const model = @import("model.zig");
const file = @import("file.zig");

const Node = tree.Node;
const Model = model.Model;

// ── Helpers ─────────────────────────────────────────────────────────────────

fn mkPane(id: []const u8) tree.Pane {
    return .{ .id = id, .session = id };
}

fn pane(id: []const u8) Node {
    return .{ .pane = mkPane(id) };
}

fn split(a: std.mem.Allocator, id: []const u8, dir: tree.Dir, ratio: f64, first: Node, second: Node) !Node {
    const s = try a.create(tree.Split);
    s.* = .{ .id = id, .dir = dir, .ratio = ratio, .first = first, .second = second };
    return .{ .split = s };
}

/// A model with one project `p` and an arena allocator for building trees.
fn newModel() !Model {
    var m = Model.init(testing.allocator);
    errdefer m.deinit();
    try m.addProject(.{ .id = "p", .name = "P", .path = "/p" });
    return m;
}

/// Tab `t` in workspace `p`: H(a, V(b, c)), split ids s1 and s2.
fn threePaneTab(m: *Model, tab_id: []const u8, a: []const u8, b: []const u8, c: []const u8, s1: []const u8, s2: []const u8) !void {
    const arena = m.arena.allocator();
    const root = try split(arena, s1, .horizontal, 0.5, pane(a), try split(arena, s2, .vertical, 0.5, pane(b), pane(c)));
    try m.createTab("p", tab_id, null, root, null, true);
}

fn paneOrder(m: *Model, tab_id: []const u8) ![]const []const u8 {
    return tree.paneIds(m.arena.allocator(), &m.findTab(tab_id).?.root);
}

fn expectOrder(m: *Model, tab_id: []const u8, want: []const []const u8) !void {
    const got = try paneOrder(m, tab_id);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

fn expectFocus(m: *Model, tab_id: []const u8, want: []const u8) !void {
    try testing.expectEqualStrings(want, m.findTab(tab_id).?.focused.?);
}

fn expectValid(m: *const Model) !void {
    const fault = try model.validate(testing.allocator, &m.data);
    if (fault) |f| {
        std.debug.print("fault: {s}\n", .{f.text()});
        return error.TestUnexpectedResult;
    }
}

// ── The shared fixtures ─────────────────────────────────────────────────────

const fixture_text = @embedFile("trees.json");

fn fixtureNode(a: std.mem.Allocator, v: std.json.Value, next_split: *usize) !Node {
    switch (v) {
        .string => |name| return pane(name),
        .object => |o| {
            next_split.* += 1;
            const id = try std.fmt.allocPrint(a, "fx-s{d}", .{next_split.*});
            const dir: tree.Dir = if (std.mem.eql(u8, o.get("dir").?.string, "horizontal")) .horizontal else .vertical;
            const ratio: f64 = switch (o.get("ratio").?) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => unreachable,
            };
            return split(a, id, dir, ratio, try fixtureNode(a, o.get("first").?, next_split), try fixtureNode(a, o.get("second").?, next_split));
        },
        else => return error.BadFixture,
    }
}

/// Fails when the tree and the fixture differ. With `erase_names`, a pane
/// name does not count.
fn expectTreeEquals(v: std.json.Value, n: *const Node, erase_names: bool, where: []const u8) !void {
    switch (v) {
        .string => |name| {
            try testing.expect(n.* == .pane);
            if (!erase_names) {
                testing.expectEqualStrings(name, n.pane.id) catch |e| {
                    std.debug.print("case: {s}\n", .{where});
                    return e;
                };
            }
        },
        .object => |o| {
            if (n.* != .split) {
                std.debug.print("case: {s}: want a split\n", .{where});
                return error.TestUnexpectedResult;
            }
            const s = n.split;
            const want_dir: tree.Dir = if (std.mem.eql(u8, o.get("dir").?.string, "horizontal")) .horizontal else .vertical;
            try testing.expectEqual(want_dir, s.dir);
            const want_ratio: f64 = switch (o.get("ratio").?) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => unreachable,
            };
            testing.expectApproxEqAbs(want_ratio, s.ratio, 1e-9) catch |e| {
                std.debug.print("case: {s}\n", .{where});
                return e;
            };
            try expectTreeEquals(o.get("first").?, &s.first, erase_names, where);
            try expectTreeEquals(o.get("second").?, &s.second, erase_names, where);
        },
        else => return error.BadFixture,
    }
}

/// New panes and splits for `tree.makeGrid`: n1, n2, ... and g1, g2, ...
const Gen = struct {
    a: std.mem.Allocator,
    panes: usize = 0,
    splits: usize = 0,

    pub fn newPane(g: *Gen) !tree.Pane {
        g.panes += 1;
        const id = try std.fmt.allocPrint(g.a, "n{d}", .{g.panes});
        return mkPane(id);
    }

    pub fn newSplitId(g: *Gen) ![]const u8 {
        g.splits += 1;
        return std.fmt.allocPrint(g.a, "g{d}", .{g.splits});
    }
};

test "the tree fixtures" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, fixture_text, .{});
    const cases = doc.object.get("cases").?.array.items;
    try testing.expect(cases.len >= 10);

    for (cases) |c| {
        const o = c.object;
        const name = o.get("name").?.string;
        const op = o.get("op").?.string;
        var counter: usize = 0;
        var root = try fixtureNode(a, o.get("before").?, &counter);
        const erase = if (o.get("erase_names")) |e| e.bool else false;

        if (std.mem.eql(u8, op, "split")) {
            const dir: tree.Dir = if (std.mem.eql(u8, o.get("dir").?.string, "horizontal")) .horizontal else .vertical;
            const pos: tree.Position = if (std.mem.eql(u8, o.get("position").?.string, "first")) .first else .second;
            const done = try tree.insertBeside(a, &root, o.get("target").?.string, pane(o.get("new").?.string), "fx-new", dir, pos);
            try testing.expect(done);
        } else if (std.mem.eql(u8, op, "remove")) {
            const result = tree.remove(&root, o.get("pane").?.string);
            try testing.expectEqualStrings(o.get("result").?.string, @tagName(result));
        } else if (std.mem.eql(u8, op, "rebalance")) {
            tree.rebalance(&root);
        } else if (std.mem.eql(u8, op, "swap")) {
            try testing.expect(tree.swap(&root, o.get("x").?.string, o.get("y").?.string));
        } else if (std.mem.eql(u8, op, "insert")) {
            const zone = std.meta.stringToEnum(tree.Zone, o.get("zone").?.string).?;
            const node = try fixtureNode(a, o.get("node").?, &counter);
            const done = try tree.insertBeside(a, &root, o.get("dest").?.string, node, "fx-new", zone.dir(), zone.position());
            try testing.expect(done);
        } else if (std.mem.eql(u8, op, "grid")) {
            var gen: Gen = .{ .a = a };
            const created = try tree.makeGrid(a, &root, o.get("source").?.string, @intCast(o.get("rows").?.integer), @intCast(o.get("columns").?.integer), &gen);
            try testing.expectEqual(@as(usize, @intCast(o.get("rows").?.integer * o.get("columns").?.integer - 1)), created.items.len);
        } else {
            std.debug.print("unknown op {s} in case {s}\n", .{ op, name });
            return error.BadFixture;
        }
        try expectTreeEquals(o.get("after").?, &root, erase, name);
    }
}

// ── Tree operations ─────────────────────────────────────────────────────────

test "a ratio is clamped, and a NaN is one half" {
    try testing.expectEqual(@as(f64, 0.15), tree.clampRatio(0.0));
    try testing.expectEqual(@as(f64, 0.85), tree.clampRatio(2.0));
    try testing.expectEqual(@as(f64, 0.5), tree.clampRatio(std.math.nan(f64)));
    try testing.expectEqual(@as(f64, 0.4), tree.clampRatio(0.4));
}

test "nextPane wraps in tree order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try split(a, "s1", .horizontal, 0.5, pane("a"), try split(a, "s2", .vertical, 0.5, pane("b"), pane("c")));
    try testing.expectEqualStrings("b", (try tree.nextPane(a, &root, "a", false)).?);
    try testing.expectEqualStrings("a", (try tree.nextPane(a, &root, "c", false)).?);
    try testing.expectEqualStrings("c", (try tree.nextPane(a, &root, "a", true)).?);
    try testing.expectEqual(@as(?[]const u8, null), try tree.nextPane(a, &root, "z", false));
    const single = pane("only");
    try testing.expectEqualStrings("only", (try tree.nextPane(a, &single, "only", false)).?);
}

test "a grid of fewer than two cells or from an unknown pane does nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var gen: Gen = .{ .a = a };
    var root = pane("a");
    try testing.expectEqual(@as(usize, 0), (try tree.makeGrid(a, &root, "a", 1, 1, &gen)).items.len);
    try testing.expectEqual(@as(usize, 0), (try tree.makeGrid(a, &root, "a", 0, 3, &gen)).items.len);
    try testing.expectEqual(@as(usize, 0), (try tree.makeGrid(a, &root, "z", 2, 2, &gen)).items.len);
    try testing.expect(root == .pane);
}

test "setRatio finds a split by id and clamps" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root = try split(a, "s1", .horizontal, 0.5, pane("a"), try split(a, "s2", .vertical, 0.5, pane("b"), pane("c")));
    try testing.expect(tree.setRatio(&root, "s2", 0.99));
    try testing.expectEqual(@as(f64, 0.85), tree.findSplit(&root, "s2").?.ratio);
    try testing.expect(!tree.setRatio(&root, "zz", 0.5));
}

// ── Model operations ────────────────────────────────────────────────────────

test "create a tab: the focus is the first pane and the tab is active" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try expectOrder(&m, "t1", &.{ "a", "b", "c" });
    try expectFocus(&m, "t1", "a");
    try testing.expectEqualStrings("t1", m.findWorkspace("p").?.active_tab.?);
    try expectValid(&m);
}

test "create a tab refuses a used id and changes nothing" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    const before = m.findWorkspace("p").?.tabs.len;
    // A pane id in use, a split id in use, a tab id in use, and a pane twice.
    try testing.expectError(error.DuplicateId, m.createTab("p", "t2", null, pane("b"), null, true));
    const arena = m.arena.allocator();
    try testing.expectError(error.DuplicateId, m.createTab("p", "t2", null, try split(arena, "s1", .horizontal, 0.5, pane("x"), pane("y")), null, true));
    try testing.expectError(error.DuplicateId, m.createTab("p", "t1", null, pane("x"), null, true));
    try testing.expectError(error.DuplicateId, m.createTab("p", "t2", null, try split(arena, "q", .horizontal, 0.5, pane("x"), pane("x")), null, true));
    try testing.expectError(error.NotFound, m.createTab("nope", "t2", null, pane("x"), null, true));
    try testing.expectEqual(before, m.findWorkspace("p").?.tabs.len);
    try expectValid(&m);
}

test "split a pane: the new pane is focused and a zoom ends" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.zoom("t1", "b");
    try testing.expectEqualStrings("b", m.zoomedPane("t1").?);
    try m.splitPane("t1", "b", mkPane("d"), "s3", .horizontal, .second, null, true, false);
    try expectOrder(&m, "t1", &.{ "a", "b", "d", "c" });
    try expectFocus(&m, "t1", "d");
    try testing.expectEqual(@as(?[]const u8, null), m.zoomedPane("t1"));
    try expectValid(&m);
}

test "split with no focus keeps the focus and the zoom" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.zoom("t1", "c");
    try m.splitPane("t1", "a", mkPane("d"), "s3", .vertical, .first, 0.3, false, false);
    try expectFocus(&m, "t1", "c");
    try testing.expectEqualStrings("c", m.zoomedPane("t1").?);
    try testing.expectEqual(@as(f64, 0.3), tree.findSplit(&m.findTab("t1").?.root, "s3").?.ratio);
}

test "split with rebalance makes every ratio even" {
    var m = try newModel();
    defer m.deinit();
    const arena = m.arena.allocator();
    try m.createTab("p", "t1", null, try split(arena, "s1", .horizontal, 0.2, pane("a"), pane("b")), null, true);
    try m.splitPane("t1", "b", mkPane("c"), "s2", .horizontal, .second, 0.9, true, true);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), tree.findSplit(&m.findTab("t1").?.root, "s1").?.ratio, 1e-9);
    try testing.expectEqual(@as(f64, 0.5), tree.findSplit(&m.findTab("t1").?.root, "s2").?.ratio);
}

test "split refuses what it cannot do and changes nothing" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try testing.expectError(error.NotFound, m.splitPane("t1", "zz", mkPane("d"), "s3", .horizontal, .second, null, true, false));
    try testing.expectError(error.NotFound, m.splitPane("tx", "a", mkPane("d"), "s3", .horizontal, .second, null, true, false));
    try testing.expectError(error.DuplicateId, m.splitPane("t1", "a", mkPane("b"), "s3", .horizontal, .second, null, true, false));
    try testing.expectError(error.DuplicateId, m.splitPane("t1", "a", mkPane("d"), "s2", .horizontal, .second, null, true, false));
    try testing.expectError(error.DuplicateId, m.splitPane("t1", "a", mkPane("d"), "d", .horizontal, .second, null, true, false));
    try expectOrder(&m, "t1", &.{ "a", "b", "c" });
}

test "close a pane: the next focus is the previous focus, else the first pane" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.focusPane("c");
    try m.focusPane("b");
    // History, newest first: c, a. Closing b gives the focus to c.
    try testing.expectEqual(model.CloseResult.pane_removed, try m.closePane("b", false));
    try expectFocus(&m, "t1", "c");
    try expectOrder(&m, "t1", &.{ "a", "c" });
    // A pane that is not focused: the focus stays.
    try testing.expectEqual(model.CloseResult.pane_removed, try m.closePane("a", false));
    try expectFocus(&m, "t1", "c");
    try expectValid(&m);
}

test "close skips a history entry that left the tree" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.focusPane("b");
    try m.focusPane("c");
    // History: b, a. Close b (not focused), then close c: a is next.
    _ = try m.closePane("b", false);
    _ = try m.closePane("c", false);
    try expectFocus(&m, "t1", "a");
}

test "close a zoomed pane ends the zoom" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.zoom("t1", "b");
    _ = try m.closePane("b", false);
    try testing.expectEqual(@as(?[]const u8, null), m.zoomedPane("t1"));
}

test "close the last pane closes the tab and the next tab is the previous one" {
    var m = try newModel();
    defer m.deinit();
    try m.createTab("p", "t1", null, pane("a"), null, true);
    try m.createTab("p", "t2", null, pane("b"), null, true);
    try m.createTab("p", "t3", null, pane("c"), null, true);
    try m.selectTab("p", "t2");
    // History, newest first: t3, t1. Closing t2 (active) gives t3.
    try testing.expectEqual(model.CloseResult.tab_closed, try m.closePane("b", false));
    try testing.expectEqualStrings("t3", m.findWorkspace("p").?.active_tab.?);
    try testing.expectEqual(@as(usize, 2), m.findWorkspace("p").?.tabs.len);
    try testing.expectError(error.NotFound, m.closePane("b", false));
    try expectValid(&m);
}

test "close the only tab leaves no active tab" {
    var m = try newModel();
    defer m.deinit();
    try m.createTab("p", "t1", null, pane("a"), null, true);
    const gone = try m.closeTab("t1");
    try testing.expectEqual(@as(usize, 1), gone.len);
    try testing.expectEqualStrings("a", gone[0].id);
    try testing.expectEqual(@as(?[]const u8, null), m.findWorkspace("p").?.active_tab);
}

test "focus next and previous wrap, and a zoom follows another focus away" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try testing.expectEqualStrings("b", try m.focusNext("t1", false));
    try testing.expectEqualStrings("c", try m.focusNext("t1", false));
    try testing.expectEqualStrings("a", try m.focusNext("t1", false));
    try testing.expectEqualStrings("c", try m.focusNext("t1", true));
    try m.zoom("t1", "c");
    _ = try m.focusNext("t1", false);
    try testing.expectEqual(@as(?[]const u8, null), m.zoomedPane("t1"));
}

test "zoom a pane focuses it, and null ends the zoom" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.zoom("t1", "c");
    try expectFocus(&m, "t1", "c");
    try testing.expectEqualStrings("c", m.zoomedPane("t1").?);
    try m.zoom("t1", null);
    try testing.expectEqual(@as(?[]const u8, null), m.zoomedPane("t1"));
    try testing.expectError(error.NotFound, m.zoom("t1", "zz"));
}

test "setRatio and rebalance a tab" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.setRatio("s1", 0.7);
    try testing.expectEqual(@as(f64, 0.7), tree.findSplit(&m.findTab("t1").?.root, "s1").?.ratio);
    try m.rebalanceTab("t1");
    try testing.expectEqual(@as(f64, 0.5), tree.findSplit(&m.findTab("t1").?.root, "s1").?.ratio);
    try testing.expectError(error.NotFound, m.setRatio("zz", 0.5));
}

test "swap two panes of one tab" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.swapPanes("a", "c");
    try expectOrder(&m, "t1", &.{ "c", "b", "a" });
    try testing.expectError(error.BadRequest, m.swapPanes("a", "a"));
    try m.createTab("p", "t2", null, pane("x"), null, false);
    try testing.expectError(error.BadRequest, m.swapPanes("a", "x"));
}

test "move a pane inside a tab" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.movePane("a", "c", .bottom, "s3", false);
    // a leaves the root; b and c remain in V(b, c); a goes below c.
    try expectOrder(&m, "t1", &.{ "b", "c", "a" });
    try expectFocus(&m, "t1", "a");
    try expectValid(&m);
}

test "move a pane to another tab; its tab closes when it was the last pane" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.createTab("p", "t2", null, pane("x"), null, true);
    try m.movePane("x", "b", .left, "s3", true);
    try testing.expectEqual(@as(?*model.Tab, null), m.findTab("t2"));
    try expectOrder(&m, "t1", &.{ "a", "x", "b", "c" });
    try expectFocus(&m, "t1", "x");
    try testing.expectEqual(@as(usize, 1), m.findWorkspace("p").?.tabs.len);
    try expectValid(&m);
}

test "move a pane to another tab when its own tab has more panes" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.createTab("p", "t2", null, pane("x"), null, true);
    try m.movePane("a", "x", .right, "s3", false);
    try expectOrder(&m, "t1", &.{ "b", "c" });
    try expectOrder(&m, "t2", &.{ "x", "a" });
    try expectFocus(&m, "t2", "a");
    try expectValid(&m);
}

test "move refuses a missing or equal pane and a used split id" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try testing.expectError(error.BadRequest, m.movePane("a", "a", .left, "s3", false));
    try testing.expectError(error.NotFound, m.movePane("a", "zz", .left, "s3", false));
    try testing.expectError(error.NotFound, m.movePane("zz", "a", .left, "s3", false));
    try testing.expectError(error.DuplicateId, m.movePane("a", "b", .left, "s2", false));
    try expectOrder(&m, "t1", &.{ "a", "b", "c" });
}

test "separate a pane into a new tab after its tab" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.createTab("p", "t9", null, pane("z"), null, false);
    try m.separatePane("c", "t2", null);
    const ws = m.findWorkspace("p").?;
    try testing.expectEqualStrings("t1", ws.tabs[0].id);
    try testing.expectEqualStrings("t2", ws.tabs[1].id);
    try testing.expectEqualStrings("t9", ws.tabs[2].id);
    try testing.expectEqualStrings("t2", ws.active_tab.?);
    try expectOrder(&m, "t1", &.{ "a", "b" });
    try expectOrder(&m, "t2", &.{"c"});
    try expectFocus(&m, "t2", "c");
    try testing.expectError(error.BadRequest, m.separatePane("c", "t3", null));
    try expectValid(&m);
}

test "merge a tab beside a pane, and at the edge" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    const arena = m.arena.allocator();
    try m.createTab("p", "t2", null, try split(arena, "s5", .vertical, 0.5, pane("x"), pane("y")), null, false);
    try m.createTab("p", "t3", null, pane("w"), null, false);
    try m.mergeTab("t2", "t1", "a", .right, "s6", false);
    try expectOrder(&m, "t1", &.{ "a", "x", "y", "b", "c" });
    try expectFocus(&m, "t1", "x");
    try testing.expectEqual(@as(?*model.Tab, null), m.findTab("t2"));
    try m.mergeTab("t3", "t1", null, .top, "s7", true);
    try expectOrder(&m, "t1", &.{ "w", "a", "x", "y", "b", "c" });
    try expectFocus(&m, "t1", "w");
    try expectValid(&m);
}

test "merge ends the zoom of the destination and refuses bad requests" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.createTab("p", "t2", null, pane("x"), null, false);
    try m.zoom("t1", "a");
    try testing.expectError(error.BadRequest, m.mergeTab("t1", "t1", null, .left, "s3", false));
    try testing.expectError(error.NotFound, m.mergeTab("t2", "t1", "zz", .left, "s3", false));
    try testing.expectError(error.DuplicateId, m.mergeTab("t2", "t1", "a", .left, "s2", false));
    try testing.expect(m.findTab("t2") != null);
    try m.mergeTab("t2", "t1", "a", .left, "s3", false);
    try testing.expectEqual(@as(?[]const u8, null), m.zoomedPane("t1"));
}

test "make a grid" {
    var m = try newModel();
    defer m.deinit();
    try m.createTab("p", "t1", null, pane("a"), null, true);
    var gen: Gen = .{ .a = m.arena.allocator() };
    const created = try m.makeGrid("t1", "a", 2, 2, &gen);
    try testing.expectEqual(@as(usize, 3), created.len);
    try expectOrder(&m, "t1", &.{ "a", "n2", "n1", "n3" });
    try expectFocus(&m, "t1", "a");
    try expectValid(&m);
}

test "a grid with a used id fails and changes nothing" {
    var m = try newModel();
    defer m.deinit();
    try m.createTab("p", "t1", null, pane("a"), null, true);
    try m.createTab("p", "t2", null, pane("n2"), null, true);
    var gen: Gen = .{ .a = m.arena.allocator() };
    try testing.expectError(error.DuplicateId, m.makeGrid("t1", "a", 2, 2, &gen));
    try expectOrder(&m, "t1", &.{"a"});
    var gen2: Gen = .{ .a = m.arena.allocator() };
    try testing.expectError(error.BadRequest, m.makeGrid("t1", "a", 1, 1, &gen2));
    try testing.expectError(error.NotFound, m.makeGrid("t1", "zz", 2, 2, &gen2));
}

test "move a tab to another workspace keeps its tree and selects it" {
    var m = try newModel();
    defer m.deinit();
    try m.addWorkspace("pinned", .pinned);
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.createTab("p", "t2", null, pane("x"), null, false);
    try m.focusPane("c");
    try m.moveTab("t1", "pinned", null);
    try testing.expectEqual(@as(usize, 1), m.findWorkspace("p").?.tabs.len);
    try testing.expectEqualStrings("t2", m.findWorkspace("p").?.active_tab.?);
    try testing.expectEqualStrings("t1", m.findWorkspace("pinned").?.active_tab.?);
    try expectOrder(&m, "t1", &.{ "a", "b", "c" });
    try expectFocus(&m, "t1", "c");
    try testing.expectError(error.BadRequest, m.moveTab("t1", "pinned", null));
    try testing.expectError(error.NotFound, m.moveTab("t1", "nope", null));
    try expectValid(&m);
}

test "reorder tabs" {
    var m = try newModel();
    defer m.deinit();
    try m.createTab("p", "t1", null, pane("a"), null, true);
    try m.createTab("p", "t2", null, pane("b"), null, true);
    try m.createTab("p", "t3", null, pane("c"), null, true);
    try m.reorderTab("t3", 0);
    const ws = m.findWorkspace("p").?;
    try testing.expectEqualStrings("t3", ws.tabs[0].id);
    try testing.expectEqualStrings("t1", ws.tabs[1].id);
    try m.reorderTab("t3", 99);
    try testing.expectEqualStrings("t3", m.findWorkspace("p").?.tabs[2].id);
}

test "remove a project removes its workspace and lists its panes" {
    var m = try newModel();
    defer m.deinit();
    try m.addProject(.{ .id = "q", .name = "Q", .path = "/q" });
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.selectProject("p");
    const gone = try m.removeProject("p");
    try testing.expectEqual(@as(usize, 3), gone.len);
    try testing.expectEqual(@as(?*model.Project, null), m.findProject("p"));
    try testing.expectEqual(@as(?*model.Workspace, null), m.findWorkspace("p"));
    try testing.expectEqual(@as(?*model.Tab, null), m.findTab("t1"));
    try testing.expectEqual(@as(?[]const u8, null), m.data.selection.active_project);
    try testing.expectError(error.NotFound, m.removeProject("p"));
    try expectValid(&m);
}

test "a project id is not reused, and workspaces other than projects need a kind" {
    var m = try newModel();
    defer m.deinit();
    try testing.expectError(error.DuplicateId, m.addProject(.{ .id = "p", .name = "P2", .path = "/p2" }));
    try testing.expectError(error.BadRequest, m.addWorkspace("w", .project));
    try m.addWorkspace("w", .widget);
    try testing.expectError(error.DuplicateId, m.addWorkspace("w", .quick));
    try testing.expectError(error.DuplicateId, m.addWorkspace("p", .quick));
}

test "attention and rename" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.setAttention("b", .failed);
    try testing.expectEqual(tree.Attention.failed, m.findPane("b").?.attention);
    try m.renameTab("t1", "build");
    try testing.expectEqualStrings("build", m.findTab("t1").?.custom_title.?);
    try m.renameTab("t1", null);
    try testing.expectEqual(@as(?[]const u8, null), m.findTab("t1").?.custom_title);
}

// ── Validation ──────────────────────────────────────────────────────────────

fn faultOf(json: []const u8) ![]const u8 {
    var fault: model.Fault = .{};
    if (file.parse(testing.allocator, json, &fault)) |*m| {
        var mm = m.*;
        mm.deinit();
        return error.TestExpectedFault;
    } else |err| switch (err) {
        error.Invalid => {
            const S = struct {
                var buf: [200]u8 = undefined;
            };
            @memcpy(S.buf[0..fault.len], fault.text());
            return S.buf[0..fault.len];
        },
        else => return err,
    }
}

const base_ok =
    \\{"version":1,"projects":[{"id":"p","name":"P","path":"/p"}],
    \\ "workspaces":[{"id":"p","kind":"project","active_tab":"t1","tabs":[
    \\   {"id":"t1","focused":"a","root":{"split":{"id":"s1","dir":"horizontal","ratio":0.5,
    \\     "first":{"pane":{"id":"a","session":"sa"}},"second":{"pane":{"id":"b","session":"sb"}}}}}]}],
    \\ "selection":{"active_project":"p"}}
;

test "a good file loads" {
    var fault: model.Fault = .{};
    var m = try file.parse(testing.allocator, base_ok, &fault);
    defer m.deinit();
    try expectOrder(&m, "t1", &.{ "a", "b" });
}

test "each fault names its place" {
    const cases = [_]struct { from: []const u8, to: []const u8, want: []const u8 }{
        .{ .from = "\"id\":\"b\"", .to = "\"id\":\"a\"", .want = "workspaces[0].tabs[0].root.second.id: duplicate" },
        .{ .from = "\"id\":\"s1\"", .to = "\"id\":\"b\"", .want = "workspaces[0].tabs[0].root.second.id: duplicate" },
        .{ .from = "\"ratio\":0.5", .to = "\"ratio\":1.5", .want = "workspaces[0].tabs[0].root.ratio: outside 0 to 1" },
        .{ .from = "\"ratio\":0.5", .to = "\"ratio\":0", .want = "workspaces[0].tabs[0].root.ratio: outside 0 to 1" },
        .{ .from = "\"focused\":\"a\"", .to = "\"focused\":\"zz\"", .want = "workspaces[0].tabs[0].focused: not in the tab" },
        .{ .from = "\"active_tab\":\"t1\"", .to = "\"active_tab\":\"zz\"", .want = "workspaces[0].active_tab: not in the workspace" },
        .{ .from = "\"session\":\"sb\"", .to = "\"session\":\"\"", .want = "workspaces[0].tabs[0].root.second.session: empty" },
        .{ .from = "\"active_project\":\"p\"", .to = "\"active_project\":\"zz\"", .want = "selection.active_project: no such project" },
        .{ .from = "\"kind\":\"project\"", .to = "\"kind\":\"pinned\"", .want = "workspaces[0].id: also a project" },
        .{ .from = "\"workspaces\":[{\"id\":\"p\"", .to = "\"workspaces\":[{\"id\":\"zz\"", .want = "workspaces[0].id: no project" },
        .{ .from = "\"id\":\"t1\"", .to = "\"id\":\"\"", .want = "workspaces[0].tabs[0].id: empty" },
    };
    for (cases) |c| {
        const text = try std.mem.replaceOwned(u8, testing.allocator, base_ok, c.from, c.to);
        defer testing.allocator.free(text);
        try testing.expect(!std.mem.eql(u8, text, base_ok));
        try testing.expectEqualStrings(c.want, try faultOf(text));
    }
}

test "a project with no workspace is a fault" {
    const text = "{\"version\":1,\"projects\":[{\"id\":\"p\",\"name\":\"P\",\"path\":\"/p\"}]}";
    try testing.expectEqualStrings("workspaces: a project has no workspace", try faultOf(text));
}

test "a tab id twice is a fault" {
    const text =
        \\{"version":1,"projects":[{"id":"p","name":"P","path":"/p"}],
        \\ "workspaces":[{"id":"p","kind":"project","tabs":[
        \\   {"id":"t1","root":{"pane":{"id":"a","session":"sa"}}},
        \\   {"id":"t1","root":{"pane":{"id":"b","session":"sb"}}}]}]}
    ;
    try testing.expectEqualStrings("workspaces[0].tabs[1].id: duplicate", try faultOf(text));
}

// ── The file ────────────────────────────────────────────────────────────────

test "a model writes and reads back the same" {
    var m = try newModel();
    defer m.deinit();
    try m.addWorkspace("pinned", .pinned);
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.renameTab("t1", "build \"it\"");
    try m.setAttention("c", .done);
    try m.selectProject("p");
    m.data.imported_v1 = true;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try file.write(&m, &out.writer);

    var fault: model.Fault = .{};
    var back = try file.parse(testing.allocator, out.written(), &fault);
    defer back.deinit();
    try testing.expect(back.data.imported_v1);
    try testing.expectEqualStrings("build \"it\"", back.findTab("t1").?.custom_title.?);
    try testing.expectEqual(tree.Attention.done, back.findPane("c").?.attention);
    try testing.expectEqualStrings("p", back.data.selection.active_project.?);
    try testing.expectEqual(@as(usize, 2), back.data.workspaces.len);
    try expectOrder(&back, "t1", &.{ "a", "b", "c" });

    var again: std.Io.Writer.Allocating = .init(testing.allocator);
    defer again.deinit();
    try file.write(&back, &again.writer);
    try testing.expectEqualStrings(out.written(), again.written());
}

test "a newer version is refused, and a bad file is refused" {
    var fault: model.Fault = .{};
    const newer = "{\"version\":99,\"something\":{\"new\":true}}";
    try testing.expectError(error.NewerVersion, file.parse(testing.allocator, newer, &fault));
    try testing.expectEqual(@as(?u32, 99), file.peekVersion(testing.allocator, newer));
    try testing.expectError(error.Syntax, file.parse(testing.allocator, "{not json", &fault));
    try testing.expectError(error.Syntax, file.parse(testing.allocator, "{\"version\":1,\"bogus\":1}", &fault));
    try testing.expectError(error.Invalid, file.parse(testing.allocator, "{\"version\":0}", &fault));
}

test "an empty model writes and reads back" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try file.write(&m, &out.writer);
    var fault: model.Fault = .{};
    var back = try file.parse(testing.allocator, out.written(), &fault);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 0), back.data.projects.len);
}

test "save and load go through a file" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/model.json", .{path_buf[0..dir_len]});
    defer testing.allocator.free(path);

    try file.save(testing.allocator, testing.io, &m, path);
    var fault: model.Fault = .{};
    var back = try file.load(testing.allocator, testing.io, path, &fault);
    defer back.deinit();
    try expectOrder(&back, "t1", &.{ "a", "b", "c" });

    const missing = try std.fmt.allocPrint(testing.allocator, "{s}.none", .{path});
    defer testing.allocator.free(missing);
    var empty = try file.load(testing.allocator, testing.io, missing, &fault);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.data.projects.len);
}
