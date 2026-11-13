//! The split tree of one tab (design/010 §1) and the operations on it.
//!
//! A tree is a `Node`: a pane, or a split of two nodes. The operations here
//! know nothing of tabs or projects. They never read pixels: a direction
//! comes from the caller. Memory comes from the allocator that the caller
//! gives, and the caller passes an arena (`Model` does). A removed split is
//! not freed one by one; the arena frees it.
//!
//! Ids are plain text (a UUID, or a short name in a test). A pane id is its
//! session id (design/004).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Dir = enum { horizontal, vertical };

/// The side of a split that a node takes along the split's axis: `first` is
/// the left of a horizontal split and the top of a vertical one.
pub const Position = enum { first, second };

/// The edge of a pane that a dropped pane lands on (v1 `PaneDropZone`).
pub const Zone = enum {
    left,
    right,
    top,
    bottom,

    pub fn dir(z: Zone) Dir {
        return switch (z) {
            .left, .right => .horizontal,
            .top, .bottom => .vertical,
        };
    }

    pub fn position(z: Zone) Position {
        return switch (z) {
            .left, .top => .first,
            .right, .bottom => .second,
        };
    }
};

pub const Attention = enum { none, done, failed };

/// A ratio never goes below this or above `max_ratio` (v1 `settingRatio`).
pub const min_ratio: f64 = 0.15;
pub const max_ratio: f64 = 0.85;

pub const Pane = struct {
    id: []const u8,
    /// The session name, verbatim. It never changes (design/010 §1).
    session: []const u8,
    /// `null` is this Mac; else the ssh destination.
    host: ?[]const u8 = null,
    slug: []const u8 = "",
    origin_path: []const u8 = "",
    cwd: ?[]const u8 = null,
    host_session_dir: ?[]const u8 = null,
    attention: Attention = .none,
};

pub const Split = struct {
    id: []const u8,
    dir: Dir,
    ratio: f64 = 0.5,
    first: Node,
    second: Node,
};

pub const Node = union(enum) {
    pane: Pane,
    split: *Split,
};

pub const Error = error{OutOfMemory};

// ── Reading ─────────────────────────────────────────────────────────────────

pub fn findPane(node: *const Node, id: []const u8) ?*const Pane {
    return switch (node.*) {
        .pane => |*p| if (std.mem.eql(u8, p.id, id)) p else null,
        .split => |s| findPane(&s.first, id) orelse findPane(&s.second, id),
    };
}

pub fn findPaneMut(node: *Node, id: []const u8) ?*Pane {
    return switch (node.*) {
        .pane => |*p| if (std.mem.eql(u8, p.id, id)) p else null,
        .split => |s| findPaneMut(&s.first, id) orelse findPaneMut(&s.second, id),
    };
}

pub fn contains(node: *const Node, id: []const u8) bool {
    return findPane(node, id) != null;
}

pub fn findSplit(node: *const Node, id: []const u8) ?*Split {
    return switch (node.*) {
        .pane => null,
        .split => |s| if (std.mem.eql(u8, s.id, id)) s else findSplit(&s.first, id) orelse findSplit(&s.second, id),
    };
}

pub fn paneCount(node: *const Node) usize {
    return switch (node.*) {
        .pane => 1,
        .split => |s| paneCount(&s.first) + paneCount(&s.second),
    };
}

/// The first pane in tree order (first before second).
pub fn firstPane(node: *const Node) *const Pane {
    return switch (node.*) {
        .pane => |*p| p,
        .split => |s| firstPane(&s.first),
    };
}

/// Appends every pane in tree order.
pub fn collectPanes(a: Allocator, node: *const Node, out: *std.ArrayList(*const Pane)) Error!void {
    switch (node.*) {
        .pane => |*p| try out.append(a, p),
        .split => |s| {
            try collectPanes(a, &s.first, out);
            try collectPanes(a, &s.second, out);
        },
    }
}

/// The pane ids in tree order.
pub fn paneIds(a: Allocator, node: *const Node) Error![]const []const u8 {
    var list: std.ArrayList(*const Pane) = .empty;
    try collectPanes(a, node, &list);
    const ids = try a.alloc([]const u8, list.items.len);
    for (list.items, ids) |p, *id| id.* = p.id;
    return ids;
}

/// The pane after (or, with `backward`, before) `id` in tree order, wrapping
/// at the ends. Null when `id` is not in the tree. A tree of one pane gives
/// that pane.
pub fn nextPane(a: Allocator, node: *const Node, id: []const u8, backward: bool) Error!?[]const u8 {
    const ids = try paneIds(a, node);
    for (ids, 0..) |candidate, i| {
        if (!std.mem.eql(u8, candidate, id)) continue;
        const n = ids.len;
        return ids[if (backward) (i + n - 1) % n else (i + 1) % n];
    }
    return null;
}

// ── Copying ─────────────────────────────────────────────────────────────────

/// A deep copy of `node` in `a`: every string and every split.
pub fn clone(a: Allocator, node: Node) Error!Node {
    switch (node) {
        .pane => |p| return .{ .pane = try clonePane(a, p) },
        .split => |s| {
            const copy = try a.create(Split);
            copy.* = .{
                .id = try a.dupe(u8, s.id),
                .dir = s.dir,
                .ratio = s.ratio,
                .first = try clone(a, s.first),
                .second = try clone(a, s.second),
            };
            return .{ .split = copy };
        },
    }
}

pub fn clonePane(a: Allocator, p: Pane) Error!Pane {
    return .{
        .id = try a.dupe(u8, p.id),
        .session = try a.dupe(u8, p.session),
        .host = if (p.host) |h| try a.dupe(u8, h) else null,
        .slug = try a.dupe(u8, p.slug),
        .origin_path = try a.dupe(u8, p.origin_path),
        .cwd = if (p.cwd) |c| try a.dupe(u8, c) else null,
        .host_session_dir = if (p.host_session_dir) |c| try a.dupe(u8, c) else null,
        .attention = p.attention,
    };
}

// ── Changing ────────────────────────────────────────────────────────────────

/// The leaf that holds pane `id`, or null.
fn leaf(node: *Node, id: []const u8) ?*Node {
    return switch (node.*) {
        .pane => |p| if (std.mem.eql(u8, p.id, id)) node else null,
        .split => |s| leaf(&s.first, id) orelse leaf(&s.second, id),
    };
}

/// Wraps pane `dest` in a new split with `node` at `position`. False, and
/// the tree unchanged, when `dest` is not in the tree. The split gets
/// ratio 0.5.
pub fn insertBeside(
    a: Allocator,
    root: *Node,
    dest: []const u8,
    node: Node,
    split_id: []const u8,
    dir: Dir,
    position: Position,
) Error!bool {
    const target = leaf(root, dest) orelse return false;
    const s = try a.create(Split);
    const old = target.*;
    s.* = .{
        .id = split_id,
        .dir = dir,
        .first = if (position == .first) node else old,
        .second = if (position == .first) old else node,
    };
    target.* = .{ .split = s };
    return true;
}

/// Wraps the whole tree in a new split with `node` at `position` (a drop on
/// the edge of the tab).
pub fn insertAtRoot(
    a: Allocator,
    root: *Node,
    node: Node,
    split_id: []const u8,
    dir: Dir,
    position: Position,
) Error!void {
    const s = try a.create(Split);
    const old = root.*;
    s.* = .{
        .id = split_id,
        .dir = dir,
        .first = if (position == .first) node else old,
        .second = if (position == .first) old else node,
    };
    root.* = .{ .split = s };
}

pub const Removal = enum { removed, only_pane, not_found };

/// Takes pane `id` out of the tree: its sibling takes the place of their
/// split. A tree with only that pane is left alone (`only_pane`): the caller
/// closes the tab.
pub fn remove(root: *Node, id: []const u8) Removal {
    switch (root.*) {
        .pane => |p| return if (std.mem.eql(u8, p.id, id)) .only_pane else .not_found,
        .split => return if (removeIn(root, id)) .removed else .not_found,
    }
}

fn removeIn(node: *Node, id: []const u8) bool {
    const s = switch (node.*) {
        .pane => return false,
        .split => |s| s,
    };
    if (s.first == .pane and std.mem.eql(u8, s.first.pane.id, id)) {
        node.* = s.second;
        return true;
    }
    if (s.second == .pane and std.mem.eql(u8, s.second.pane.id, id)) {
        node.* = s.first;
        return true;
    }
    return removeIn(&s.first, id) or removeIn(&s.second, id);
}

/// Swaps the places of panes `x` and `y`. The shape and the ratios stay.
/// False when one is not in the tree or they are the same pane.
pub fn swap(root: *Node, x: []const u8, y: []const u8) bool {
    if (std.mem.eql(u8, x, y)) return false;
    const px = findPaneMut(root, x) orelse return false;
    const py = findPaneMut(root, y) orelse return false;
    std.mem.swap(Pane, px, py);
    return true;
}

/// Sets the ratio of split `id`, clamped to `min_ratio`..`max_ratio`.
pub fn setRatio(root: *Node, id: []const u8, ratio: f64) bool {
    const s = findSplit(root, id) orelse return false;
    s.ratio = clampRatio(ratio);
    return true;
}

pub fn clampRatio(ratio: f64) f64 {
    if (std.math.isNan(ratio)) return 0.5;
    return @min(@max(ratio, min_ratio), max_ratio);
}

/// The cells that a subtree gives along `dir`: a split on the same axis adds
/// its two sides; a pane, or a split on the other axis, is one cell.
pub fn tileUnits(node: *const Node, dir: Dir) usize {
    return switch (node.*) {
        .pane => 1,
        .split => |s| if (s.dir == dir) tileUnits(&s.first, dir) + tileUnits(&s.second, dir) else 1,
    };
}

/// Sets every ratio so that the panes along each axis share the space
/// evenly (v1 `rebalanced`).
pub fn rebalance(node: *Node) void {
    const s = switch (node.*) {
        .pane => return,
        .split => |s| s,
    };
    const left = tileUnits(&s.first, s.dir);
    const right = tileUnits(&s.second, s.dir);
    const total = left + right;
    if (total > 0) s.ratio = @as(f64, @floatFromInt(left)) / @as(f64, @floatFromInt(total));
    rebalance(&s.first);
    rebalance(&s.second);
}

/// Makes a `rows` x `columns` grid out of pane `source`, row by row, the way
/// v1 does: the source is the top-left cell, the new panes come from `gen`
/// (`newPane() !Pane` and `newSplitId() ![]const u8`, both in the arena),
/// and every ratio is even. Returns the new panes' ids in creation order.
/// Nothing changes, and the result is empty, for fewer than two cells or an
/// unknown source.
pub fn makeGrid(
    a: Allocator,
    root: *Node,
    source: []const u8,
    rows: usize,
    columns: usize,
    gen: anytype,
) !std.ArrayList([]const u8) {
    var created: std.ArrayList([]const u8) = .empty;
    if (rows < 1 or columns < 1 or rows * columns < 2) return created;
    if (!contains(root, source)) return created;

    var heads: std.ArrayList([]const u8) = .empty;
    try heads.append(a, source);
    var r: usize = 1;
    while (r < rows) : (r += 1) {
        const pane = try gen.newPane();
        _ = try insertBeside(a, root, heads.items[heads.items.len - 1], .{ .pane = pane }, try gen.newSplitId(), .vertical, .second);
        try heads.append(a, pane.id);
        try created.append(a, pane.id);
    }
    for (heads.items) |head| {
        var current = head;
        var c: usize = 1;
        while (c < columns) : (c += 1) {
            const pane = try gen.newPane();
            _ = try insertBeside(a, root, current, .{ .pane = pane }, try gen.newSplitId(), .horizontal, .second);
            try created.append(a, pane.id);
            current = pane.id;
        }
    }
    rebalance(root);
    return created;
}
