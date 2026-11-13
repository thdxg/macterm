//! The model on the Mac server (design/010 §1): projects, workspaces, tabs
//! and their split trees, and the operations that change them.
//!
//! `Data` is what goes to disk (`file.zig`). `Model` is `Data` plus the
//! state that stays in memory: the zoomed pane of each tab, the focus
//! history of each tab, and the tab history of each workspace.
//!
//! **Every operation checks first and changes after.** An operation that
//! returns an error leaves the model as it was (design/010 §7), so a caller
//! never sees half of a change (out of memory is the one exception). Inputs are copied into the
//! model's arena, so a caller keeps its own memory.
//!
//! The model never grows smaller while it runs: a changed list or a removed
//! tab leaves its old memory in the arena. An edit costs some bytes. The
//! server loads the file again when it starts, and that gives a clean arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tree = @import("tree.zig");

pub const Node = tree.Node;
pub const Pane = tree.Pane;

/// The version of the file that this build writes (design/010 §2).
pub const version: u32 = 1;

pub const Kind = enum { project, pinned, scratch, quick, widget };

pub const Project = struct {
    id: []const u8,
    name: []const u8,
    /// A local path, or `user@host:dir`.
    path: []const u8,
    color: ?[]const u8 = null,
    sort_order: i64 = 0,
    /// Unix time in milliseconds.
    created_at: i64 = 0,
};

pub const Tab = struct {
    id: []const u8,
    custom_title: ?[]const u8 = null,
    root: Node,
    focused: ?[]const u8 = null,
};

pub const Workspace = struct {
    /// For a `project` workspace, the project's id. Any other kind has an
    /// id of its own (the fixed ids of the pinned and the scratch workspace,
    /// a widget's id).
    id: []const u8,
    kind: Kind,
    tabs: []Tab = &.{},
    active_tab: ?[]const u8 = null,
};

pub const Selection = struct {
    active_project: ?[]const u8 = null,
};

/// What `model.json` holds.
pub const Data = struct {
    version: u32 = version,
    epoch_hint: u64 = 0,
    imported_v1: bool = false,
    projects: []Project = &.{},
    workspaces: []Workspace = &.{},
    selection: Selection = .{},
};

pub const Error = error{
    OutOfMemory,
    /// An id in the request is not in the model.
    NotFound,
    /// A new id is already in use.
    DuplicateId,
    /// The request cannot be done to this model (the same pane as source and
    /// target, a pane that is not in the tab, ...).
    BadRequest,
};

/// The most recent ids first, with no duplicates.
const Recency = struct {
    items: std.ArrayList([]const u8) = .empty,
    limit: usize,

    fn push(r: *Recency, a: Allocator, id: []const u8) Error!void {
        r.remove(id);
        try r.items.insert(a, 0, id);
        if (r.items.items.len > r.limit) r.items.shrinkRetainingCapacity(r.limit);
    }

    fn remove(r: *Recency, id: []const u8) void {
        var i: usize = 0;
        while (i < r.items.items.len) {
            if (std.mem.eql(u8, r.items.items[i], id)) _ = r.items.orderedRemove(i) else i += 1;
        }
    }

    /// Takes the newest id for which `valid` holds, and drops the ids that it
    /// passed.
    fn popValid(r: *Recency, ctx: anytype, valid: anytype) ?[]const u8 {
        while (r.items.items.len > 0) {
            const top = r.items.orderedRemove(0);
            if (valid(ctx, top)) return top;
        }
        return null;
    }
};

pub const pane_history_limit = 20;
pub const tab_history_limit = 50;

pub const CloseResult = enum { pane_removed, tab_closed };

pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    data: Data = .{},
    /// Tab id to its zoomed pane id.
    zoomed: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Tab id to its earlier focus, newest first (design/010 §1).
    pane_history: std.StringHashMapUnmanaged(Recency) = .empty,
    /// Workspace id to its earlier active tabs, newest first.
    tab_history: std.StringHashMapUnmanaged(Recency) = .empty,

    pub fn init(gpa: Allocator) Model {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(m: *Model) void {
        m.arena.deinit();
        m.* = undefined;
    }

    fn alloc(m: *Model) Allocator {
        return m.arena.allocator();
    }

    // ── Lookup ──────────────────────────────────────────────────────────────

    const TabLoc = struct { ws: *Workspace, index: usize };

    pub fn findProject(m: *const Model, id: []const u8) ?*Project {
        for (m.data.projects) |*p| if (std.mem.eql(u8, p.id, id)) return p;
        return null;
    }

    pub fn findWorkspace(m: *const Model, id: []const u8) ?*Workspace {
        for (m.data.workspaces) |*w| if (std.mem.eql(u8, w.id, id)) return w;
        return null;
    }

    fn locateTab(m: *const Model, tab_id: []const u8) ?TabLoc {
        for (m.data.workspaces) |*w| {
            for (w.tabs, 0..) |t, i| if (std.mem.eql(u8, t.id, tab_id)) return .{ .ws = w, .index = i };
        }
        return null;
    }

    pub fn findTab(m: *const Model, tab_id: []const u8) ?*Tab {
        const loc = m.locateTab(tab_id) orelse return null;
        return &loc.ws.tabs[loc.index];
    }

    /// The tab that holds pane `pane_id`.
    pub fn findPaneTab(m: *const Model, pane_id: []const u8) ?*Tab {
        for (m.data.workspaces) |*w| {
            for (w.tabs) |*t| if (tree.contains(&t.root, pane_id)) return t;
        }
        return null;
    }

    pub fn findPane(m: *const Model, pane_id: []const u8) ?*const Pane {
        const t = m.findPaneTab(pane_id) orelse return null;
        return tree.findPane(&t.root, pane_id);
    }

    /// The workspace that holds tab `tab_id`.
    pub fn workspaceOfTab(m: *const Model, tab_id: []const u8) ?*Workspace {
        return (m.locateTab(tab_id) orelse return null).ws;
    }

    pub fn zoomedPane(m: *const Model, tab_id: []const u8) ?[]const u8 {
        return m.zoomed.get(tab_id);
    }

    fn splitInUse(m: *const Model, id: []const u8) bool {
        for (m.data.workspaces) |*w| {
            for (w.tabs) |*t| if (tree.findSplit(&t.root, id) != null) return true;
        }
        return false;
    }

    fn paneInUse(m: *const Model, id: []const u8) bool {
        return m.findPaneTab(id) != null;
    }

    /// Fails with `DuplicateId` when a pane or a split of `node` has an id
    /// that the model has, or that the node has twice.
    fn checkFreshIds(m: *Model, node: *const Node, other: ?*const Node) Error!void {
        const a = m.alloc();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        try m.checkFreshIn(a, node, &seen, other);
    }

    fn checkFreshIn(
        m: *Model,
        a: Allocator,
        node: *const Node,
        seen: *std.StringHashMapUnmanaged(void),
        ignoring: ?*const Node,
    ) Error!void {
        const id = switch (node.*) {
            .pane => |p| p.id,
            .split => |s| s.id,
        };
        if (id.len == 0) return error.BadRequest;
        const gop = try seen.getOrPut(a, id);
        if (gop.found_existing) return error.DuplicateId;
        switch (node.*) {
            .pane => {
                const holder = m.findPaneTab(id);
                if (holder != null and (ignoring == null or &holder.?.root != ignoring.?)) return error.DuplicateId;
            },
            .split => |s| {
                if (m.splitInUse(id) and (ignoring == null or tree.findSplit(ignoring.?, id) == null)) return error.DuplicateId;
                try m.checkFreshIn(a, &s.first, seen, ignoring);
                try m.checkFreshIn(a, &s.second, seen, ignoring);
            },
        }
    }

    // ── Projects and workspaces ─────────────────────────────────────────────

    /// Adds a project and its workspace (kind `project`, the same id).
    pub fn addProject(m: *Model, p: Project) Error!void {
        const a = m.alloc();
        if (p.id.len == 0) return error.BadRequest;
        if (m.findProject(p.id) != null or m.findWorkspace(p.id) != null) return error.DuplicateId;
        const copy: Project = .{
            .id = try a.dupe(u8, p.id),
            .name = try a.dupe(u8, p.name),
            .path = try a.dupe(u8, p.path),
            .color = if (p.color) |c| try a.dupe(u8, c) else null,
            .sort_order = p.sort_order,
            .created_at = p.created_at,
        };
        const projects = try appendOne(Project, a, m.data.projects, copy);
        const workspaces = try appendOne(Workspace, a, m.data.workspaces, .{ .id = copy.id, .kind = .project });
        m.data.projects = projects;
        m.data.workspaces = workspaces;
    }

    /// Adds a workspace that is not a project's: pinned, scratch, quick or
    /// widget.
    pub fn addWorkspace(m: *Model, id: []const u8, kind: Kind) Error!void {
        const a = m.alloc();
        if (kind == .project or id.len == 0) return error.BadRequest;
        if (m.findWorkspace(id) != null or m.findProject(id) != null) return error.DuplicateId;
        m.data.workspaces = try appendOne(Workspace, a, m.data.workspaces, .{ .id = try a.dupe(u8, id), .kind = kind });
    }

    /// Removes a project and its workspace. Returns the panes that left the
    /// model (the caller ends their sessions).
    pub fn removeProject(m: *Model, id: []const u8) Error![]const Pane {
        const a = m.alloc();
        const pi = indexOf(Project, m.data.projects, id) orelse return error.NotFound;
        const wi = indexOf(Workspace, m.data.workspaces, id) orelse return error.NotFound;
        var gone: std.ArrayList(Pane) = .empty;
        for (m.data.workspaces[wi].tabs) |*t| try appendPanes(a, &t.root, &gone);
        for (m.data.workspaces[wi].tabs) |t| m.forgetTab(t.id);
        _ = m.tab_history.remove(id);
        m.data.projects = try removeAt(Project, a, m.data.projects, pi);
        m.data.workspaces = try removeAt(Workspace, a, m.data.workspaces, wi);
        if (m.data.selection.active_project) |sel| {
            if (std.mem.eql(u8, sel, id)) m.data.selection.active_project = null;
        }
        return gone.items;
    }

    pub fn selectProject(m: *Model, id: ?[]const u8) Error!void {
        const a = m.alloc();
        if (id) |wanted| {
            if (m.findProject(wanted) == null) return error.NotFound;
            m.data.selection.active_project = try a.dupe(u8, wanted);
        } else {
            m.data.selection.active_project = null;
        }
    }

    // ── Tabs ────────────────────────────────────────────────────────────────

    /// Makes a tab in workspace `ws_id` at `index` (at the end when null or
    /// too big). `root` is copied. The tab's focus is the first pane. With
    /// `focus`, or when the workspace has no active tab, it becomes the
    /// active tab.
    pub fn createTab(
        m: *Model,
        ws_id: []const u8,
        tab_id: []const u8,
        index: ?usize,
        root: Node,
        title: ?[]const u8,
        focus: bool,
    ) Error!void {
        const a = m.alloc();
        const ws = m.findWorkspace(ws_id) orelse return error.NotFound;
        if (tab_id.len == 0) return error.BadRequest;
        if (m.locateTab(tab_id) != null or m.findWorkspace(tab_id) != null) return error.DuplicateId;
        try m.checkFreshIds(&root, null);
        var copy = try tree.clone(a, root);
        const tab: Tab = .{
            .id = try a.dupe(u8, tab_id),
            .custom_title = if (title) |t| try a.dupe(u8, t) else null,
            .root = copy,
            .focused = tree.firstPane(&copy).id,
        };
        const at = @min(index orelse ws.tabs.len, ws.tabs.len);
        ws.tabs = try insertAt(Tab, a, ws.tabs, at, tab);
        if (focus or ws.active_tab == null) try m.activate(ws, tab.id);
    }

    /// Closes a tab. Returns its panes: they left the model.
    pub fn closeTab(m: *Model, tab_id: []const u8) Error![]const Pane {
        const a = m.alloc();
        const loc = m.locateTab(tab_id) orelse return error.NotFound;
        var gone: std.ArrayList(Pane) = .empty;
        try appendPanes(a, &loc.ws.tabs[loc.index].root, &gone);
        try m.detachTab(loc);
        return gone.items;
    }

    /// Takes the tab out of its workspace and picks the next active tab
    /// (the newest of the history that is still there, else the last tab).
    fn detachTab(m: *Model, loc: TabLoc) Error!void {
        const a = m.alloc();
        const ws = loc.ws;
        const id = ws.tabs[loc.index].id;
        ws.tabs = try removeAt(Tab, a, ws.tabs, loc.index);
        m.forgetTab(id);
        if (m.tab_history.getPtr(ws.id)) |h| h.remove(id);
        const was_active = ws.active_tab != null and std.mem.eql(u8, ws.active_tab.?, id);
        if (!was_active) return;
        if (m.tab_history.getPtr(ws.id)) |h| {
            if (h.popValid(ws, wsHasTab)) |prev| {
                ws.active_tab = prev;
                return;
            }
        }
        ws.active_tab = if (ws.tabs.len > 0) ws.tabs[ws.tabs.len - 1].id else null;
    }

    fn wsHasTab(ws: *const Workspace, id: []const u8) bool {
        for (ws.tabs) |t| if (std.mem.eql(u8, t.id, id)) return true;
        return false;
    }

    fn forgetTab(m: *Model, id: []const u8) void {
        _ = m.zoomed.remove(id);
        _ = m.pane_history.remove(id);
    }

    fn activate(m: *Model, ws: *Workspace, tab_id: []const u8) Error!void {
        const a = m.alloc();
        if (ws.active_tab) |cur| {
            if (!std.mem.eql(u8, cur, tab_id)) {
                const gop = try m.tab_history.getOrPut(a, ws.id);
                if (!gop.found_existing) gop.value_ptr.* = .{ .limit = tab_history_limit };
                try gop.value_ptr.push(a, cur);
            }
        }
        ws.active_tab = tab_id;
    }

    pub fn selectTab(m: *Model, ws_id: []const u8, tab_id: []const u8) Error!void {
        const ws = m.findWorkspace(ws_id) orelse return error.NotFound;
        if (!wsHasTab(ws, tab_id)) return error.NotFound;
        try m.activate(ws, ws.tabs[tabIndex(ws, tab_id)].id);
    }

    fn tabIndex(ws: *const Workspace, id: []const u8) usize {
        for (ws.tabs, 0..) |t, i| if (std.mem.eql(u8, t.id, id)) return i;
        unreachable;
    }

    pub fn renameTab(m: *Model, tab_id: []const u8, title: ?[]const u8) Error!void {
        const a = m.alloc();
        const tab = m.findTab(tab_id) orelse return error.NotFound;
        tab.custom_title = if (title) |t| try a.dupe(u8, t) else null;
    }

    /// Moves a tab inside its workspace to `index` (clamped).
    pub fn reorderTab(m: *Model, tab_id: []const u8, index: usize) Error!void {
        const a = m.alloc();
        const loc = m.locateTab(tab_id) orelse return error.NotFound;
        const tab = loc.ws.tabs[loc.index];
        const without = try removeAt(Tab, a, loc.ws.tabs, loc.index);
        loc.ws.tabs = try insertAt(Tab, a, without, @min(index, without.len), tab);
    }

    /// Moves a tab to another workspace (pinned and scratch included) and
    /// selects it there. Its panes keep their sessions.
    pub fn moveTab(m: *Model, tab_id: []const u8, to_ws: []const u8, index: ?usize) Error!void {
        const a = m.alloc();
        const loc = m.locateTab(tab_id) orelse return error.NotFound;
        const dst = m.findWorkspace(to_ws) orelse return error.NotFound;
        if (dst == loc.ws) return error.BadRequest;
        const tab = loc.ws.tabs[loc.index];
        // Grow the destination first: the only step that can fail after the
        // checks. Nothing has changed if it does.
        const at = @min(index orelse dst.tabs.len, dst.tabs.len);
        const grown = try insertAt(Tab, a, dst.tabs, at, tab);
        const zoomed = m.zoomed.get(tab.id);
        const history = m.pane_history.get(tab.id);
        try m.detachTab(loc);
        dst.tabs = grown;
        if (zoomed) |z| try m.zoomed.put(a, tab.id, z);
        if (history) |h| try m.pane_history.put(a, tab.id, h);
        try m.activate(dst, tab.id);
    }

    // ── Panes ───────────────────────────────────────────────────────────────

    /// Splits pane `target` of a tab: the new pane goes at `position`. The
    /// split's ratio is `ratio` (0.5 when null). With `focus`, the new pane
    /// gets the focus and any zoom ends. With `rebalance`, every ratio of the
    /// tab is even after the split.
    pub fn splitPane(
        m: *Model,
        tab_id: []const u8,
        target: []const u8,
        new_pane: Pane,
        split_id: []const u8,
        dir: tree.Dir,
        position: tree.Position,
        ratio: ?f64,
        focus: bool,
        rebalance: bool,
    ) Error!void {
        const a = m.alloc();
        const tab = m.findTab(tab_id) orelse return error.NotFound;
        if (!tree.contains(&tab.root, target)) return error.NotFound;
        if (new_pane.id.len == 0 or split_id.len == 0) return error.BadRequest;
        if (std.mem.eql(u8, new_pane.id, split_id)) return error.DuplicateId;
        if (m.paneInUse(new_pane.id) or m.splitInUse(split_id)) return error.DuplicateId;
        const pane = try tree.clonePane(a, new_pane);
        const sid = try a.dupe(u8, split_id);
        _ = try tree.insertBeside(a, &tab.root, target, .{ .pane = pane }, sid, dir, position);
        if (ratio) |r| _ = tree.setRatio(&tab.root, sid, r);
        if (rebalance) tree.rebalance(&tab.root);
        if (focus) {
            _ = m.zoomed.remove(tab.id);
            try m.focusIn(tab, pane.id);
        }
    }

    /// Closes pane `pane_id`. The last pane of a tab closes the tab. The
    /// next focus is the newest earlier focus that is still in the tab, else
    /// the first pane. With `rebalance`, every ratio is even after.
    pub fn closePane(m: *Model, pane_id: []const u8, rebalance: bool) Error!CloseResult {
        const tab = m.findPaneTab(pane_id) orelse return error.NotFound;
        if (tree.paneCount(&tab.root) <= 1) {
            _ = try m.closeTab(tab.id);
            return .tab_closed;
        }
        try m.takeOut(tab, pane_id);
        if (rebalance) tree.rebalance(&tab.root);
        return .pane_removed;
    }

    /// Removes a pane from a tab with two panes or more, and fixes the
    /// tab's zoom and focus. Cannot fail after its one allocation.
    fn takeOut(m: *Model, tab: *Tab, pane_id: []const u8) Error!void {
        const a = m.alloc();
        // Reserve the history first: the allocation is the only failure.
        const gop = try m.pane_history.getOrPut(a, tab.id);
        if (!gop.found_existing) gop.value_ptr.* = .{ .limit = pane_history_limit };
        const removal = tree.remove(&tab.root, pane_id);
        std.debug.assert(removal == .removed);
        if (m.zoomed.get(tab.id)) |z| {
            if (std.mem.eql(u8, z, pane_id)) _ = m.zoomed.remove(tab.id);
        }
        gop.value_ptr.remove(pane_id);
        if (tab.focused != null and std.mem.eql(u8, tab.focused.?, pane_id)) {
            const next = gop.value_ptr.popValid(&tab.root, treeHas);
            tab.focused = next orelse tree.firstPane(&tab.root).id;
        }
    }

    fn treeHas(root: *const Node, id: []const u8) bool {
        return tree.contains(root, id);
    }

    /// Focuses a pane. Another pane's zoom ends (v1 `focusPane`).
    pub fn focusPane(m: *Model, pane_id: []const u8) Error!void {
        const tab = m.findPaneTab(pane_id) orelse return error.NotFound;
        try m.focusIn(tab, pane_id);
    }

    fn focusIn(m: *Model, tab: *Tab, pane_id: []const u8) Error!void {
        const a = m.alloc();
        const id = tree.findPane(&tab.root, pane_id).?.id;
        if (tab.focused != null and std.mem.eql(u8, tab.focused.?, id)) return;
        const gop = try m.pane_history.getOrPut(a, tab.id);
        if (!gop.found_existing) gop.value_ptr.* = .{ .limit = pane_history_limit };
        if (tab.focused) |cur| try gop.value_ptr.push(a, cur);
        gop.value_ptr.remove(id);
        if (m.zoomed.get(tab.id)) |z| {
            if (!std.mem.eql(u8, z, id)) _ = m.zoomed.remove(tab.id);
        }
        tab.focused = id;
    }

    /// Focuses the next pane in tree order (the previous one with
    /// `backward`), wrapping. Returns the pane that has the focus.
    pub fn focusNext(m: *Model, tab_id: []const u8, backward: bool) Error![]const u8 {
        const tab = m.findTab(tab_id) orelse return error.NotFound;
        const cur = tab.focused orelse tree.firstPane(&tab.root).id;
        const next = (try tree.nextPane(m.alloc(), &tab.root, cur, backward)) orelse return error.BadRequest;
        try m.focusIn(tab, next);
        return tab.focused.?;
    }

    /// Zooms a pane of the tab, or with null ends the zoom. A zoomed pane
    /// has the focus.
    pub fn zoom(m: *Model, tab_id: []const u8, pane_id: ?[]const u8) Error!void {
        const a = m.alloc();
        const tab = m.findTab(tab_id) orelse return error.NotFound;
        const id = pane_id orelse {
            _ = m.zoomed.remove(tab.id);
            return;
        };
        const pane = tree.findPane(&tab.root, id) orelse return error.NotFound;
        try m.focusIn(tab, pane.id);
        try m.zoomed.put(a, tab.id, pane.id);
    }

    pub fn setRatio(m: *Model, split_id: []const u8, ratio: f64) Error!void {
        for (m.data.workspaces) |*w| {
            for (w.tabs) |*t| if (tree.setRatio(&t.root, split_id, ratio)) return;
        }
        return error.NotFound;
    }

    pub fn rebalanceTab(m: *Model, tab_id: []const u8) Error!void {
        const tab = m.findTab(tab_id) orelse return error.NotFound;
        tree.rebalance(&tab.root);
    }

    /// Swaps the places of two panes of one tab. The focus stays on its pane
    /// (it moves with the pane).
    pub fn swapPanes(m: *Model, x: []const u8, y: []const u8) Error!void {
        const tab = m.findPaneTab(x) orelse return error.NotFound;
        if (!tree.contains(&tab.root, y)) return error.BadRequest;
        if (!tree.swap(&tab.root, x, y)) return error.BadRequest;
    }

    pub fn setAttention(m: *Model, pane_id: []const u8, attention: tree.Attention) Error!void {
        const tab = m.findPaneTab(pane_id) orelse return error.NotFound;
        tree.findPaneMut(&tab.root, pane_id).?.attention = attention;
    }

    /// Moves pane `pane_id` next to pane `dest` on `zone`, in the same tab
    /// or in another. When it is the last pane of its tab, that tab closes.
    /// The moved pane gets the focus.
    pub fn movePane(
        m: *Model,
        pane_id: []const u8,
        dest: []const u8,
        zone: tree.Zone,
        split_id: []const u8,
        rebalance: bool,
    ) Error!void {
        const a = m.alloc();
        if (std.mem.eql(u8, pane_id, dest)) return error.BadRequest;
        const src = m.findPaneTab(pane_id) orelse return error.NotFound;
        const dst = m.findPaneTab(dest) orelse return error.NotFound;
        if (split_id.len == 0) return error.BadRequest;
        if (m.splitInUse(split_id) or std.mem.eql(u8, split_id, pane_id)) return error.DuplicateId;
        const pane = tree.findPane(&src.root, pane_id).?.*;
        const sid = try a.dupe(u8, split_id);
        const src_id = src.id;
        const dst_id = dst.id;
        if (src == dst) {
            try m.takeOut(src, pane_id);
        } else if (tree.paneCount(&src.root) <= 1) {
            // `closeTab` can fail only on memory; nothing has changed then.
            _ = try m.closeTab(src_id);
        } else {
            try m.takeOut(src, pane_id);
        }
        const into = m.findTab(dst_id).?;
        _ = try tree.insertBeside(a, &into.root, dest, .{ .pane = pane }, sid, zone.dir(), zone.position());
        _ = m.zoomed.remove(dst_id);
        if (rebalance) tree.rebalance(&into.root);
        try m.focusIn(into, pane_id);
    }

    /// Moves pane `pane_id` out of its tab into a new tab `tab_id`, in
    /// workspace `ws_id` (the pane's own when null), after the source tab
    /// when it is in the same workspace. The tab of one pane cannot be
    /// separated.
    pub fn separatePane(m: *Model, pane_id: []const u8, tab_id: []const u8, ws_id: ?[]const u8) Error!void {
        const a = m.alloc();
        const src = m.findPaneTab(pane_id) orelse return error.NotFound;
        if (tree.paneCount(&src.root) <= 1) return error.BadRequest;
        if (tab_id.len == 0) return error.BadRequest;
        if (m.locateTab(tab_id) != null or m.findWorkspace(tab_id) != null) return error.DuplicateId;
        const src_loc = m.locateTab(src.id).?;
        const ws = if (ws_id) |id| (m.findWorkspace(id) orelse return error.NotFound) else src_loc.ws;
        const pane = tree.findPane(&src.root, pane_id).?.*;
        const at = if (ws == src_loc.ws) src_loc.index + 1 else ws.tabs.len;
        const new_tab: Tab = .{ .id = try a.dupe(u8, tab_id), .root = .{ .pane = pane }, .focused = pane.id };
        const grown = try insertAt(Tab, a, ws.tabs, at, new_tab);
        try m.takeOut(src, pane_id);
        ws.tabs = grown;
        try m.activate(ws, new_tab.id);
    }

    /// Puts the whole tree of tab `src_id` into tab `dst_id`, next to pane
    /// `target` on `zone`, or, with a null `target`, at the edge of the tab.
    /// The source tab closes with no pane lost. The first pane of the
    /// merged tree gets the focus, and any zoom of the destination ends.
    pub fn mergeTab(
        m: *Model,
        src_id: []const u8,
        dst_id: []const u8,
        target: ?[]const u8,
        zone: tree.Zone,
        split_id: []const u8,
        rebalance: bool,
    ) Error!void {
        const a = m.alloc();
        if (std.mem.eql(u8, src_id, dst_id)) return error.BadRequest;
        const src_loc = m.locateTab(src_id) orelse return error.NotFound;
        const dst0 = m.findTab(dst_id) orelse return error.NotFound;
        if (target) |t| if (!tree.contains(&dst0.root, t)) return error.NotFound;
        if (split_id.len == 0) return error.BadRequest;
        if (m.splitInUse(split_id)) return error.DuplicateId;
        const sid = try a.dupe(u8, split_id);
        const moved = src_loc.ws.tabs[src_loc.index].root;
        try m.detachTab(src_loc);
        const dst = m.findTab(dst_id).?;
        if (target) |t| {
            _ = try tree.insertBeside(a, &dst.root, t, moved, sid, zone.dir(), zone.position());
        } else {
            try tree.insertAtRoot(a, &dst.root, moved, sid, zone.dir(), zone.position());
        }
        _ = m.zoomed.remove(dst_id);
        if (rebalance) tree.rebalance(&dst.root);
        try m.focusIn(dst, tree.firstPane(&moved).id);
    }

    /// Splits pane `source` into a `rows` x `columns` grid (see
    /// `tree.makeGrid`). Returns the new panes' ids. The source keeps the
    /// focus. The new ids come from `gen`; a new id that is in use fails with
    /// `DuplicateId` and changes nothing.
    pub fn makeGrid(
        m: *Model,
        tab_id: []const u8,
        source: []const u8,
        rows: usize,
        columns: usize,
        gen: anytype,
    ) ![]const []const u8 {
        const a = m.alloc();
        const tab = m.findTab(tab_id) orelse return error.NotFound;
        if (!tree.contains(&tab.root, source)) return error.NotFound;
        var trial = try tree.clone(a, tab.root);
        const created = try tree.makeGrid(a, &trial, source, rows, columns, gen);
        if (created.items.len == 0) return error.BadRequest;
        try m.checkFreshIds(&trial, &tab.root);
        tab.root = trial;
        _ = m.zoomed.remove(tab.id);
        try m.focusIn(tab, source);
        return created.items;
    }

    // ── Panes that left ─────────────────────────────────────────────────────

    fn appendPanes(a: Allocator, node: *const Node, out: *std.ArrayList(Pane)) Error!void {
        var list: std.ArrayList(*const Pane) = .empty;
        try tree.collectPanes(a, node, &list);
        for (list.items) |p| try out.append(a, p.*);
    }
};

// ── Slices that grow ────────────────────────────────────────────────────────

fn appendOne(comptime T: type, a: Allocator, old: []T, item: T) Error![]T {
    return insertAt(T, a, old, old.len, item);
}

fn insertAt(comptime T: type, a: Allocator, old: []T, at: usize, item: T) Error![]T {
    const out = try a.alloc(T, old.len + 1);
    @memcpy(out[0..at], old[0..at]);
    out[at] = item;
    @memcpy(out[at + 1 ..], old[at..]);
    return out;
}

fn removeAt(comptime T: type, a: Allocator, old: []T, at: usize) Error![]T {
    const out = try a.alloc(T, old.len - 1);
    @memcpy(out[0..at], old[0..at]);
    @memcpy(out[at..], old[at + 1 ..]);
    return out;
}

fn indexOf(comptime T: type, items: []const T, id: []const u8) ?usize {
    for (items, 0..) |it, i| if (std.mem.eql(u8, it.id, id)) return i;
    return null;
}

// ── Validation ──────────────────────────────────────────────────────────────

/// The first fault of a model: where it is (`workspaces[1].tabs[0].root.first`)
/// and what is wrong. A fixed buffer, so a fault needs no allocator.
pub const Fault = struct {
    buf: [200]u8 = undefined,
    len: usize = 0,

    pub fn text(f: *const Fault) []const u8 {
        return f.buf[0..f.len];
    }

    fn make(comptime fmt: []const u8, args: anytype) Fault {
        var f: Fault = .{};
        const s = std.fmt.bufPrint(&f.buf, fmt, args) catch f.buf[0..];
        f.len = s.len;
        return f;
    }
};

/// Checks that `data` is a model: ids that are not empty and are not used
/// twice, ratios inside 0..1, a `focused` pane that is in its tree, an
/// `active_tab` that is in its workspace, and project workspaces that match
/// their projects. Returns the first fault, or null.
pub fn validate(gpa: Allocator, data: *const Data) Allocator.Error!?Fault {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    if (data.version == 0 or data.version > version) return Fault.make("version: {d}", .{data.version});

    for (data.projects, 0..) |p, i| {
        if (p.id.len == 0) return Fault.make("projects[{d}].id: empty", .{i});
        if ((try seen.getOrPut(a, p.id)).found_existing) return Fault.make("projects[{d}].id: duplicate", .{i});
    }
    var project_workspaces: usize = 0;
    var tabs_seen: std.StringHashMapUnmanaged(void) = .empty;
    var nodes_seen: std.StringHashMapUnmanaged(void) = .empty;
    var ws_seen: std.StringHashMapUnmanaged(void) = .empty;
    for (data.workspaces, 0..) |w, wi| {
        if (w.id.len == 0) return Fault.make("workspaces[{d}].id: empty", .{wi});
        if ((try ws_seen.getOrPut(a, w.id)).found_existing) return Fault.make("workspaces[{d}].id: duplicate", .{wi});
        if (w.kind == .project) {
            project_workspaces += 1;
            var found = false;
            for (data.projects) |p| found = found or std.mem.eql(u8, p.id, w.id);
            if (!found) return Fault.make("workspaces[{d}].id: no project", .{wi});
        } else if ((try seen.getOrPut(a, w.id)).found_existing) {
            return Fault.make("workspaces[{d}].id: also a project", .{wi});
        }
        for (w.tabs, 0..) |t, ti| {
            if (t.id.len == 0) return Fault.make("workspaces[{d}].tabs[{d}].id: empty", .{ wi, ti });
            if ((try tabs_seen.getOrPut(a, t.id)).found_existing) {
                return Fault.make("workspaces[{d}].tabs[{d}].id: duplicate", .{ wi, ti });
            }
            var path: [96]u8 = undefined;
            const prefix = std.fmt.bufPrint(&path, "workspaces[{d}].tabs[{d}].root", .{ wi, ti }) catch path[0..];
            if (try validateNode(a, &t.root, prefix, &nodes_seen)) |f| return f;
            if (t.focused) |f| {
                if (!tree.contains(&t.root, f)) return Fault.make("workspaces[{d}].tabs[{d}].focused: not in the tab", .{ wi, ti });
            }
        }
        if (w.active_tab) |at| {
            if (!Model.wsHasTab(&w, at)) return Fault.make("workspaces[{d}].active_tab: not in the workspace", .{wi});
        }
    }
    if (project_workspaces != data.projects.len) return Fault.make("workspaces: a project has no workspace", .{});
    if (data.selection.active_project) |id| {
        var found = false;
        for (data.projects) |p| found = found or std.mem.eql(u8, p.id, id);
        if (!found) return Fault.make("selection.active_project: no such project", .{});
    }
    return null;
}

fn validateNode(
    a: Allocator,
    node: *const Node,
    path: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
) Allocator.Error!?Fault {
    switch (node.*) {
        .pane => |p| {
            if (p.id.len == 0) return Fault.make("{s}.id: empty", .{path});
            if (p.session.len == 0) return Fault.make("{s}.session: empty", .{path});
            if ((try seen.getOrPut(a, p.id)).found_existing) return Fault.make("{s}.id: duplicate", .{path});
        },
        .split => |s| {
            if (s.id.len == 0) return Fault.make("{s}.id: empty", .{path});
            if ((try seen.getOrPut(a, s.id)).found_existing) return Fault.make("{s}.id: duplicate", .{path});
            if (!(s.ratio > 0 and s.ratio < 1)) return Fault.make("{s}.ratio: outside 0 to 1", .{path});
            var buf: [128]u8 = undefined;
            const first = std.fmt.bufPrint(&buf, "{s}.first", .{path}) catch buf[0..];
            if (try validateNode(a, &s.first, first, seen)) |f| return f;
            const second = std.fmt.bufPrint(&buf, "{s}.second", .{path}) catch buf[0..];
            return validateNode(a, &s.second, second, seen);
        },
    }
    return null;
}
