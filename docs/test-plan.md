# Macterm Test Plan

Comprehensive plan for a model-layer test suite. The goal is to catch regressions in tree operations, tab/focus lifecycle, persistence, palette ranking, and hotkey parsing — the areas where recent bugs actually lived — without trying to render UI or drive libghostty.

## Guiding principles

1. **Test the model, not the view.** Every recent bug (HV-close swap, quick-terminal close crash, pane swap on tree reshape) was traceable to a pure function on `SplitNode` / `TerminalTab` / `AppState`. The SwiftUI layer is a thin projection of that state.
2. **No libghostty, no NSView.** `Pane.nsView` is an `Optional` — tests leave it `nil` and every tree/lifecycle op is a no-op on the AppKit side. Do not mock `GhosttyTerminalNSView`; its interactions belong to manual smoke-testing.
3. **Invariants over examples.** Prefer asserting structural properties (pane-id set preservation, focus always valid, ratios in bounds) over asserting specific ratios or positional shapes. Property-style invariant tests catch the whole class of "accidental tree mutation" bugs.
4. **One file per type under test.** Mirror the source tree — `MactermTests/Model/SplitNodeTests.swift`, etc.
5. **Fast.** Whole suite must run in well under a second so `mise run test` fits into the pre-commit loop.

## Target setup

Add a `.testTarget` to `Package.swift`:

```swift
.testTarget(
    name: "MactermTests",
    dependencies: ["Macterm"],
    path: "MactermTests"
)
```

Create a new top-level directory `MactermTests/` with subfolders mirroring `Macterm/`:

```
MactermTests/
├── App/
│   ├── AppStateTests.swift
│   ├── HotkeysTests.swift
│   └── RecencyStackTests.swift
├── Model/
│   ├── PaneTests.swift
│   ├── SplitNodeTests.swift
│   ├── SplitNodeResizeTests.swift
│   ├── SplitNodeGeometryTests.swift
│   ├── SplitNodeRebalanceTests.swift
│   ├── TerminalTabTests.swift
│   └── WorkspaceTests.swift
├── Palette/
│   └── PaletteEngineTests.swift
├── Persistence/
│   └── WorkspaceSerializerTests.swift
└── Support/
    ├── TreeBuilder.swift          # `tree(H(p("l1"), V(p("r1"), p("r2"))))` DSL
    ├── TreeRenderer.swift         # SplitNode -> "H(l1, V(r1, r2))" for snapshot asserts
    └── TestFixtures.swift         # Named Pane factories, stock trees
```

Add `test` task to `mise.toml`:

```toml
[tasks.test]
description = "Run unit tests"
run = "swift test"
```

Hook into `check:fix` so CI fails on regressions.

## Test helpers (write these first)

### TreeBuilder

A small DSL so tree construction doesn't dominate test code:

```swift
func pane(_ name: String) -> (String, SplitNode)    // returns (name, .pane(Pane))
func H(_ a: (String, SplitNode), _ b: (String, SplitNode), ratio: CGFloat = 0.5) -> (String, SplitNode)
func V(_ a: (String, SplitNode), _ b: (String, SplitNode), ratio: CGFloat = 0.5) -> (String, SplitNode)
```

Paired with a name→UUID lookup the test can use instead of chasing `Pane.id` through the tree:

```swift
let (tree, ids) = build(H(pane("l1"), V(pane("r1"), pane("r2"))))
// ids["l1"], ids["r1"], ids["r2"]
```

### TreeRenderer

Render a `SplitNode` back to the DSL string: `H(l1, V(r1, r2))`. Assertions on tree topology become one-liners:

```swift
XCTAssertEqual(render(after), "V(r1, r2)")
```

### Pane helpers

`Pane.nsView` is always nil in tests. If a test needs `needsConfirmQuit()` or `currentPwd`, add a tiny protocol on the Pane so we can inject stub values — **only if a specific test needs it**. Don't prematurely abstract.

## Tests by area

### Model/SplitNodeTests — tree structure ops

Covers `splitting`, `removing`, `findPane`, `contains`, `allPanes`. This is where the HV-close bug lived.

- `splitting_replaces_leaf_with_branch` — split a single pane returns a branch with original + new pane
- `splitting_preserves_other_panes_ids` — split deep in tree; all non-target ids unchanged
- `splitting_returns_new_pane_id` — returned id matches the new leaf in the tree
- `splitting_nonexistent_pane_is_noop` — returns `(self, nil)`, tree unchanged
- `splitting_first_vs_second_position` — `.first` places new pane on left/top
- `removing_leaf_from_simple_split_collapses_branch` — `H(a,b)` remove `a` → `pane(b)`
- `removing_only_pane_returns_nil` — removing root leaf gives `nil`
- `removing_from_mixed_HV_preserves_correct_panes` — **regression**: `H(l1, V(r1,r2))` remove `l1` → `V(r1, r2)` with r1 and r2 intact
- `removing_deep_leaf_preserves_branch_shape` — deep removal doesn't scramble sibling identity
- `findPane_returns_same_instance` — pointer identity, not just id equality
- `contains_matches_allPanes` — `contains(paneID:)` iff `allPanes()` contains it
- `allPanes_ordering_is_stable_across_ratio_changes` — changing a ratio doesn't reorder panes

### Model/SplitNodeResizeTests — resize math

Covers `resizing` and `applyResize`.

- `resize_right_adjusts_nearest_horizontal_ancestor`
- `resize_up_adjusts_nearest_vertical_ancestor`
- `resize_skips_non_matching_axis_ancestors` — resize-right through a V branch walks up to the H ancestor
- `resize_clamps_to_bounds` — ratio stays within [0.15, 0.85]
- `resize_on_root_leaf_is_noop`
- `resize_sign_matches_direction` — right/down increase ratio, left/up decrease

### Model/SplitNodeGeometryTests — paneFrames + nearestPane

Covers the frame math used for directional focus.

- `paneFrames_single_pane_fills_rect`
- `paneFrames_horizontal_split_ratio` — a `0.3` horizontal split gives frames with widths `0.3` and `0.7`
- `paneFrames_nested_splits_compose_correctly`
- `paneFrames_returns_id_for_each_pane` — count matches `allPanes().count`
- `nearestPane_from_top_left_in_HV_grid` — picks the right neighbor
- `nearestPane_returns_nil_when_no_candidates` — e.g. going `.up` from the topmost pane
- `nearestPane_tiebreak_prefers_closer_center`

### Model/SplitNodeRebalanceTests — auto-tiling

Covers `rebalanced` and `tileUnits`.

- `rebalance_sets_5050_for_simple_split`
- `rebalance_gives_equal_share_to_three_same_axis_panes` — `H(a, H(b, c))` → outer ratio 1/3, inner 1/2
- `rebalance_different_axis_descendants_count_as_one_cell` — `H(a, V(b, c))` → outer ratio 1/2
- `rebalance_is_idempotent` — applying twice yields the same tree
- `tileUnits_leaf_is_one`

### Model/TerminalTabTests — the refactored mutation API

Covers the methods we just unified: `split`, `resize`, `removePane`, `focusPane`, `nextFocusAfterClose`.

- `split_on_focused_pane_focuses_new_pane` — after `split(focused, .horizontal)`, `focusedPaneID` is the new pane
- `split_pushes_old_focus_to_history`
- `removePane_only_pane_returns_onlyPaneLeft_and_destroys_surface`
- `removePane_middle_pane_reshapes_tree_and_advances_focus_via_history`
- `removePane_of_unfocused_leaves_focus_alone`
- `removePane_notFound_is_noop`
- `removePane_prunes_history`
- `nextFocusAfterClose_prefers_most_recent_valid` — history ordering honored
- `nextFocusAfterClose_falls_back_to_first_pane_when_history_empty`
- `focusPane_ignores_no_change`
- `focusPane_updates_history_on_switch`
- **Regression test**: the HV-close bug scenario end-to-end on `TerminalTab` — build `H(l1, V(r1, r2))`, `removePane(l1)`, assert the remaining panes are exactly `r1` and `r2` (same instances, not new ones)

### Model/WorkspaceTests — tab lifecycle

Covers `createTab`, `closeTab`, `selectTab`, `selectNext/Previous`, `recencyOrder`, `peekTab`, `reorderTabs`.

- `createTab_appends_and_selects_it_and_pushes_previous_to_history`
- `closeTab_active_selects_most_recent_from_history`
- `closeTab_active_with_empty_history_selects_last_tab`
- `closeTab_nonactive_leaves_active_alone`
- `closeTab_invalid_id_is_noop`
- `selectNextTab_wraps_around`
- `selectPreviousTab_wraps_around`
- `selectNextTab_single_tab_is_noop`
- `recencyOrder_active_first_then_history_then_unvisited`
- `recencyOrder_prunes_removed_tabs`
- `peekTab_does_not_record_history` — and `selectTab` after peek still has correct history
- `reorderTabs_preserves_ids`

### Model/PaneTests

Small but important.

- `processTitle_defaults_to_shell_name_when_title_blank`
- `processTitle_picks_first_non_path_non_noise_token`
- `processTitle_ignores_paths_and_tilde_prefixes`
- `processTitle_falls_back_when_all_tokens_are_paths`

### App/RecencyStackTests

- `push_moves_existing_to_front`
- `push_bounded_drops_oldest`
- `remove_by_value`
- `popValid_skips_invalid_until_found`
- `prune_keeps_only_listed`
- `top_returns_limited_subset_in_order`
- `init_from_items_preserves_order`

### App/AppStateTests — coarse-grained integration

Construct `AppState` in-memory with a stubbed `WorkspaceStore` (use a subclass that no-ops `save` or an in-memory dict). Exercise top-level commands and assert on tree + focus + tab state.

- `splitPane_modifies_active_tab_and_saves`
- `closePane_last_pane_closes_whole_tab`
- `closePane_middle_pane_advances_focus_from_history`
- `requestClosePane_without_running_process_closes_immediately`
- `closePane_from_non_active_tab_still_works` — regression for the "find tab containing pane" fix
- `focusPaneInDirection_right_from_left_pane_in_H_split`
- `focusPaneInDirection_no_neighbor_is_noop`
- `closeTab_removes_tab_and_destroys_surfaces` (assert `Pane.nsView` nil after — since test panes have nil nsView anyway, the real assertion is the tree is gone and `activeTabID` is valid)
- `selectGlobalTab_next_wraps_across_projects`
- `tab_cycle_commit_records_history_and_selects`
- `removeProject_drops_workspace_and_clears_activeProjectID_when_matching`
- **Regression scenario**: reproduce the HV-close bug through `AppState.closePane` to ensure the integration path is covered

Requires a small refactor: `AppState`'s `WorkspaceStore` is currently a `let` initialized inline. Accept it via an initializer with a default value, then tests can pass an in-memory store. Same for `Preferences.shared` usages — wrap feature flags in a protocol or accept them as parameters where they're consulted (`autoTilingEnabled`). Keep this refactor minimal; only parameterize what tests need to control.

### App/HotkeysTests

Covers `HotkeyRegistry` parsing + matching + display.

- `parse_basic_shortcut` — `"cmd+shift+p"` → modifiers + key
- `parse_handles_arrow_keys` — `"cmd+left"`, etc.
- `parse_rejects_malformed`
- `displayString_renders_modifiers_in_apple_order` — `⌃⌥⇧⌘K`
- `matches_cmd_shift_p_event`
- `matches_is_case_insensitive_for_letter_keys`
- `allCases_has_unique_action_ids` — sanity check that enum cases don't collide
- `selectedShortcutString_falls_back_to_default_when_userdefaults_empty`

### Persistence/WorkspaceSerializerTests

Round-trip tests — build a workspace, snapshot it, restore it, assert structural equivalence.

- `round_trip_empty_workspace_preserves_project_id`
- `round_trip_single_tab_single_pane_preserves_path_and_title`
- `round_trip_nested_splits_preserves_topology` — render before and after with `TreeRenderer`, assert equal
- `round_trip_ratios_preserved_within_tolerance`
- `round_trip_active_tab_id_preserved_when_valid`
- `round_trip_active_tab_id_falls_back_when_missing`
- `round_trip_custom_tab_title_preserved`
- `restore_skips_workspaces_for_removed_projects` — filters by `validIDs`
- `restore_creates_fresh_pane_ids` — document the known limitation as a test
- `decode_malformed_json_fails_gracefully` — no crash, returns empty

### Palette/PaletteEngineTests

Covers ranking + section composition in `PaletteEngine`, including the path-source branch.

- `empty_query_returns_default_sections`
- `query_matches_project_name_case_insensitive`
- `query_matches_command_title`
- `ranking_prefers_prefix_match_over_substring`
- `ranking_prefers_word_boundary_match`
- `path_prefix_query_shows_directory_source_section` — `"/Users/"` triggers `DirectorySource`
- `tilde_prefix_query_shows_directory_source_section`
- `non_path_query_does_not_show_directory_source`
- `section_headers_appear_only_when_items_present`

`DirectorySource` touches the filesystem — either skip its tests or give it a directory-listing protocol and inject a fake. Prefer the protocol: one small `DirectoryLister` with a fake impl.

## Tests we're explicitly NOT writing (yet)

- `GhosttyTerminalNSView` keyboard/mouse/IME — requires a real window and libghostty. Manual smoke.
- `TerminalPortal` — deleted.
- `FocusRestoration` — timing-dependent retry loop. Could be tested with a clock abstraction, but the value is low; smoke-test it.
- `CommandPalette` UI, `Sidebar` UI, `SplitTreeView` UI — SwiftUI rendering. Snapshot-testing frameworks exist but are brittle. Skip.
- `MactermConfig` parsing/writing — touches `~/.config`. If we add tests, inject a path root.
- `ProjectStore` JSON — could be covered with an in-memory `FileStorage` fake. Low-value, low-risk.

## Rollout order

1. **Week 1 — foundation**: TreeBuilder, TreeRenderer, `SplitNodeTests`, `SplitNodeResizeTests`. These cover the highest-risk area and unblock everything else.
2. **Week 1 — TerminalTab + regression**: `TerminalTabTests` including the HV-close regression test. Guards the refactor we just landed.
3. **Week 2 — Workspace + RecencyStack**: `WorkspaceTests`, `RecencyStackTests`. Covers tab lifecycle, which is the next-most-mutated area.
4. **Week 2 — AppState integration**: After a small refactor to inject `WorkspaceStore`. Integration test of the HV-close bug.
5. **Week 3 — Persistence round-trip**: `WorkspaceSerializerTests`. Guards against silent migration regressions.
6. **Week 3 — Palette + Hotkeys + Geometry**: `PaletteEngineTests`, `HotkeysTests`, `SplitNodeGeometryTests`, `SplitNodeRebalanceTests`. Fill in the rest.

## Success criteria

- Full suite runs in < 1 s on a dev machine.
- `mise run check:fix` runs tests and fails on red.
- The three recent user-reported bugs (HV-close swap, quick-terminal close crash scenario at the model level, split-tree reshape pane swap) each have a named regression test.
- Every `@MainActor @Observable` class in `Macterm/Model/` has its public mutation API covered.
- No test imports `GhosttyKit` or touches libghostty.
