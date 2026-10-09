# ASD-STE100 rewrite plan

Working file. Delete it in the last commit of the rewrite.

## Goal

Write all user-facing prose in ASD-STE100 style. Work top-down: rewrite the documents that frame the project first. Rewrite the detailed documents last. By then the terms are fixed.

## Tools and limits

- Skill: `asd-ste100` (https://github.com/danyuchn/asd-ste100-skill), installed in `.claude/skills/asd-ste100/`. `.claude/` is gitignored, so the skill stays local. AGENTS.md names the source URL for other contributors.
- Linter: `python3 .claude/skills/asd-ste100/scripts/ste-lint.py <file>`. It checks sentence structure only. It does not check the official dictionary.
- The official ~900-word dictionary is not in the skill. We apply the rules as "plain word, one meaning". We never claim dictionary compliance.
- The work is done in this session, by one agent, with no subagents. Each file is read whole before it is rewritten.

## Baseline (linter, hard violations)

| Size | Files |
|---|---|
| Very large | AGENTS.md 507 |
| Medium | passwords 39, website/README 23, CLI doc 19, extensions doc 17, palette doc 16, widgets doc 12 |
| Small | CONTRIBUTING 10, extensions/README 8, README 6, all other docs 0–7 |

Goal: 0 hard violations in every Markdown file. Advisory findings (passive voice, compound tenses) get a human decision.

## Rules for every file

1. Read the whole file first. Read the code it describes if a sentence makes a claim about behavior.
2. Pick the mode. Strict: procedures, errors, CLI output, Settings text, agent skills. STE-flavored: README, concept prose, PR text.
3. Keep facts, conditions, numbers and hedges exactly. Never turn "may" into a fact.
4. Do not change code identifiers, commands, flags, key names, paths, product names or heading text that other files link to (see "Pinned strings").
5. Use the project glossary (Phase 0). One name for one thing in every file.
6. Run the linter. Fix hard violations. Review advisory ones.
7. Commit one file group at a time. The subject line says why, not what.

## Phase 0: Decisions and glossary (no prose changes yet)

- Write a short glossary. It holds only Macterm-specific terms (project, tab, pane, session, workspace, mirror, pinned tab, extension, widget, layout, and similar) and words that are ambiguous. It does not define technical terms a reader can look up.
- List the ambiguous words we replace everywhere (for example "attach", "detach", "surface", "daemon") and the one word we use instead.
- The decisions are under "Decisions".
- Output: `WRITING.md` at the repo root (done in PR 0). Later phases follow it.

## Phase 1: Identity (what Macterm is)

Highest level. Every later document borrows its wording.

1. `README.md`: tagline, feature list, install, links.
2. `website/public/index.html`: hero, feature copy, FAQ. The page has no FAQ now. `website/check-seo.mjs` still fails if FAQ markup and its JSON-LD ever differ, so run `bun run check:seo` after an edit.
3. `website/docs/pages/00-introduction.md` and `10-installation.md`.
4. Page `description:` front matter in all docs pages (used for SEO and link cards). Do these after the pages they describe, in Phase 3.

## Phase 2: Contributor-facing entry points

1. `CONTRIBUTING.md`.
2. `.github/pull_request_template.md`, `.github/ISSUE_TEMPLATE/*.yml`, `.github/release.yml` category names.
3. `website/README.md` and `extensions/README.md`.
4. `CODE_OF_CONDUCT.md`: see open question 3.

## Phase 3: User documentation, by concept (broad to narrow)

Order follows how a new user learns the product.

1. Core model: `60-session-persistence`, `55-pinned-tabs`, `50-declarative-layouts`.
2. Daily use: `30-command-palette`, `85-shortcuts`, `40-quick-terminal`, `47-finder-and-dock`.
3. Setup: `20-configuration`.
4. Features: `45-desktop-widgets`, `45-passwords`, `70-remote-projects`.
5. Extensions: `35-extensions`, then `extensions/*/README.md`, `extensions/*/extension.yaml` descriptions, and the prose inside `extensions/*/palettes/*.yaml` (renamed from `palette.yaml` in #531).
6. Reference and recipes: `80-cli`, `90-cookbook`.

Constraint: docs headings make URL anchors. `DocsLink.swift` links to some of them and `DocsLinkTests` fails when one moves. Keep heading text, or change the Swift case in the same commit.
Constraint: captioned palette examples in the docs are parsed by `CustomPaletteFileTests`. Example YAML stays valid.

## Phase 4: In-app text

1. First run: `Macterm/App/Tutorial.swift` and `FirstRunSeed.swift` (what a new user reads first).
2. Command titles and menus: `AppCommand.swift`, `AppCommandMenu.swift`, palette scope titles.
3. Settings: `SettingsView.swift` (35 captions), `ExtensionsSettings` (now a grid of cards, #531), `PasswordsSettings`, `ProjectsSettings`, `WidgetsSettings`, `PasswordEditorSheet`.
4. Alerts, toasts and notices: `messageText`/`informativeText`, `AppCommand.unavailableNotice`, quit confirmation, password bubble.
5. Shortcuts and Spotlight: `Macterm/Intents/` titles and descriptions.
6. `Macterm/Info.plist` usage descriptions.

Constraint: `MactermIntentsTests` and `PaletteScopeTests` pin some titles against each other. Update both sides together.

## Phase 5: CLI and agent text

1. CLI help: `CLI/MactermCommand.swift` abstracts and discussions (about 100 strings), `WidgetCommand`, `PaletteCommand`, `SSHCommand`, `TutorCommand`, `Output`.
2. Server messages: error `message` and `action` strings in `ControlHandler.swift`.
3. Agent skills: `Macterm/Control/AgentSkills/*.swift` (about 5,900 words). Do these after the CLI, because they quote it. `AgentSkillsTests` runs every `macterm` line against the real command tree.

Constraint: e2e tests assert on some CLI output text. Search `e2e/` for each changed string before the edit. Run `mise run e2e --verbose` after this phase.

## Phase 6: Machine-readable text and the long tail

1. `assets/*.schema.json` descriptions (shown in editors).
2. `scripts/*.sh` and `scripts/*.py` user-visible messages.
3. `website/src/docs-template.html` and `site.js` strings.
4. `AGENTS.md` (about 18,000 words). It is high-level in scope but has the most detail. Do it last in this list, section by section, after the glossary has been tested on everything else. It also loses its backstory prose in some places: keep every rule, rewrite every sentence.

## Phase 7: Verification

- Linter over every Markdown file: 0 hard violations.
- `mise run format`, `lint`, `test --verbose` (use `--force`, see memory), `e2e --verbose`.
- `node website/build-docs.mjs` and `check-seo.mjs`. Open the built site in the preview browser and check every page.
- Build the app. Read Settings, the first-run tutorial, a few alerts and `macterm --help` for each verb.
- Grep for banned patterns left behind: semicolons in prose, "e.g.", "i.e.", "via", em-dash chains, "—" overuse.
- Delete `STE100-PLAN.md`.

## Pinned strings (do not change without a paired edit)

| String | Where it is pinned |
|---|---|
| Docs heading text | `DocsLink.swift`, `DocsLinkTests`, cross-links between docs pages |
| FAQ text, if the page gets one again | `website/check-seo.mjs` (markup and JSON-LD) |
| Keybind labels | `MactermKeybind` against `AppCommand.title` (`MactermIntentsTests`) |
| Palette scope titles | `PaletteScopeTests` |
| `macterm …` lines in agent skills | `AgentSkillsTests` against the CLI help tree |
| CLI output text | `e2e/*.py` assertions |
| Example palette YAML in docs | `CustomPaletteFileTests` |
| Extension description rules | `PaletteRegistryTests`, `CustomPaletteFileTests` |
| Info.plist keys | `BundledResourcesTests`, services contract tests |

## Decisions

1. Code comments and `///` doc comments stay as they are. The AGENTS.md rule still applies to text written from now on.
2. `CODE_OF_CONDUCT.md` stays as published.
3. Technical terms that a reader can look up (`ssh`, `OSC`, `pty`, `libghostty`) get no definition. The glossary defines only Macterm-specific terms and words that are ambiguous.
4. Stacked PRs, one per phase (see "PR stack").
5. The skill stays local (`.claude/` is gitignored).

## PR stack

Each phase is one branch and one PR. Each branch starts from the previous phase branch.

| PR | Branch | Base | Content |
|---|---|---|---|
| 0 | `ste100/0-rule-and-glossary` | `main` | AGENTS.md rule, this plan, glossary |
| 1 | `ste100/1-identity` | PR 0 | Phase 1 |
| 2 | `ste100/2-contributor` | PR 1 | Phase 2 |
| 3 | `ste100/3-user-docs` | PR 2 | Phase 3 |
| 4 | `ste100/4-app-text` | PR 3 | Phase 4 |
| 5 | `ste100/5-cli-agents` | PR 4 | Phase 5 |
| 6 | `ste100/6-long-tail` | PR 5 | Phase 6 |
| 7 | `ste100/7-verify` | PR 6 | Phase 7 fixes, plan file deleted |

- PRs merge by squash only, so a squash on the base makes the next PR's base differ. After a PR merges, retarget the next PR to `main` and merge `main` into its branch. Never rebase (AGENTS.md rule).
- Review order is PR 0 first. PR 0 contains the glossary, so a reviewer can check the later PRs against it.
- PR 4 and PR 5 change code strings, so they run the full test suite and e2e before they open.
