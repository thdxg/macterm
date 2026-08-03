#!/usr/bin/env bash
# Report how a GhosttyKit bump changes the part of ghostty.h that Macterm
# actually uses.
#
# Why this exists: `ghostty-internal` is not a supported external API (see the
# GhosttyKit note in AGENTS.md), so a bump can move anything. The header is
# ~1200 lines and a week of upstream churn touches plenty of it, almost none of
# which we call — telling a reviewer to "skim the compare view" means the few
# lines that matter are buried. This filters the diff down to the symbols our
# own sources reference.
#
# Usage: ghosttykit-api-diff.sh OLD_HEADER NEW_HEADER [OLD_TAG NEW_TAG]
# Writes markdown to stdout. Exits 0 even when it finds breaking changes — it is
# a reporting tool, and the build/test jobs are what actually gate the bump.
#
# The design rule here is that a FALSE NEGATIVE is the only unacceptable
# outcome: a reviewer who reads "no relevant change" and merges is worse off
# than one who reads noise. Everything below prefers over-reporting, and
# anything it cannot determine statically is said out loud rather than counted
# as unchanged.
set -euo pipefail

# Byte collation, so `sort` and `comm` agree. BSD `sort` honours locale
# collation while BSD `comm` compares bytes, and under a UTF-8 locale that
# disagreement invents phantom removals in the enum add/remove diff (real case:
# inserting GHOSTTY_ACTION_RENDER_ZZ reported RENDERER_HEALTH as removed).
export LC_ALL=C

OLD_HEADER="${1:?usage: $0 OLD_HEADER NEW_HEADER [OLD_TAG NEW_TAG]}"
NEW_HEADER="${2:?usage: $0 OLD_HEADER NEW_HEADER [OLD_TAG NEW_TAG]}"
OLD_TAG="${3:-old}"
NEW_TAG="${4:-new}"

for f in "$OLD_HEADER" "$NEW_HEADER"; do
  [[ -f "$f" ]] || { echo "error: no such header: $f" >&2; exit 1; }
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/macterm-apidiff.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# ── Every identifier in each header, for exact membership tests ──────────────
# Substring matching is not good enough for the removal verdict: 14 of the
# symbols we use are proper prefixes of other identifiers in the header
# (`ghostty_surface_free` inside `ghostty_surface_free_text`,
# `GHOSTTY_ACTION_OPEN_URL` inside `GHOSTTY_ACTION_OPEN_URL_KIND_TEXT`, …), so a
# genuine removal would be masked by the longer name and report as ✅.
ids() { grep -ohE '[A-Za-z_][A-Za-z0-9_]*' "$1" | sort -u; }
ids "$OLD_HEADER" > "$work/ids_old.txt"
ids "$NEW_HEADER" > "$work/ids_new.txt"

# ── The symbols we actually depend on ────────────────────────────────────────
# Both cases matter and they behave differently: lowercase `ghostty_*` are
# functions and types (a removal or signature change is a compile error), while
# uppercase `GHOSTTY_*` are enum constants and macros — Swift imports those by
# name, so a renumbering compiles silently.
{
  grep -rhoE '\bghostty_[a-z0-9_]+' --include='*.swift' "$ROOT/Macterm" "$ROOT/CLI" 2>/dev/null || true
  grep -rhoE '\bGHOSTTY_[A-Z0-9_]+' --include='*.swift' "$ROOT/Macterm" "$ROOT/CLI" 2>/dev/null || true
} | sort -u > "$work/candidates.txt"

# Keep only names the header actually defines. Without this the count includes
# things that merely look like header symbols — GHOSTTY_BIN_DIR and
# GHOSTTY_RESOURCES_DIR are environment variable names we set, not API.
sort -u "$work/ids_old.txt" "$work/ids_new.txt" > "$work/ids_any.txt"
comm -12 "$work/candidates.txt" "$work/ids_any.txt" > "$work/used.txt"

used_count=$(wc -l < "$work/used.txt" | tr -d ' ')
if [[ "$used_count" == "0" ]]; then
  echo "error: no ghostty_* symbol from $ROOT/{Macterm,CLI} appears in either header — has the source layout or the header moved?" >&2
  exit 1
fi

# ── Enum members with their effective C values ───────────────────────────────
# Emits: <enum_name>\t<value>\t<member>
#
# The value must be simulated, not assumed to be the position: members carry an
# explicit `= N` and in C every implicit member after one continues from it.
# Anything that cannot be evaluated yields `?`, and `?` is reported explicitly
# rather than compared — two `?`s must never read as "unchanged".
enum_values() {
  # Normalize first so the parser sees one element per line:
  #   - drop /* … */ comments, which otherwise hide a member behind a leading
  #     token (`/* reserved */ GHOSTTY_X,`) and take its slot out of the count
  #   - join a line whose initializer continues on the next (`= <newline> 7,`)
  #   - break a closing `}` off a member line, so `GHOSTTY_X } name;` still
  #     closes the enum instead of leaking into the next block
  awk '
    { gsub(/\/\*[^*]*\*\//, "") }
    pend != "" { $0 = pend " " $0; pend = "" }
    /=[[:space:]]*$/ { pend = $0; next }
    {
      # One element per line, whatever the source formatting: break after `{`
      # and each `,`, and before `}`. This is what makes a single-line
      # `typedef enum { A, B } name;` parse at all (previously the whole line
      # was consumed by the typedef rule and the enum vanished from both
      # sides — which silently disabled the renumber check), and it also
      # detaches a closing brace that shares a line with its last member.
      gsub(/\{/, "{\n"); gsub(/,/, ",\n"); gsub(/\}/, "\n}")
      print
    }
    END { if (pend != "") print pend }
  ' "$1" | awk '
    # Hand-rolled rather than gawk`s strtonum(): macOS ships the one-true-awk,
    # where strtonum is undefined and the whole script dies.
    function hex2dec(s,   digits, out, i, c, p) {
      digits = "0123456789abcdef"
      sub(/^0[xX]/, "", s); s = tolower(s); out = 0
      for (i = 1; i <= length(s); i++) {
        p = index(digits, substr(s, i, 1)) - 1
        if (p < 0) return "?"
        out = out * 16 + p
      }
      return out
    }
    function value_of(init,   a, b) {
      sub(/^[[:space:]]+/, "", init); sub(/[[:space:]]+$/, "", init)
      sub(/[uUlL]+$/, "", init)                      # 5U, 3L
      if (init ~ /^0[xX][0-9a-fA-F]+$/) return hex2dec(init)
      if (init ~ /^-?[0-9]+$/)          return init + 0
      # `1 << N` is the only expression form the header uses, and it covers the
      # whole of ghostty_input_mods_e — 9 constants we consume. Left unevaluated
      # they were all `?`, which made that enum permanently unwatchable.
      if (init ~ /^[0-9]+[[:space:]]*<<[[:space:]]*[0-9]+$/) {
        a = init; sub(/[[:space:]]*<<.*$/, "", a)
        b = init; sub(/^[0-9]+[[:space:]]*<<[[:space:]]*/, "", b)
        return (a + 0) * (2 ^ (b + 0))
      }
      return "?"
    }
    /typedef[[:space:]]+enum/ { in_enum = 1; n = 0; next_val = 0; delete m; delete v; next }
    in_enum && /^[[:space:]]*}/ {
      name = $0
      sub(/^[[:space:]]*}[[:space:]]*/, "", name); sub(/[[:space:]]*;.*$/, "", name)
      if (name == "") name = "(anonymous)"
      for (i = 0; i < n; i++) if (m[i] ~ /^GHOSTTY_/) print name "\t" v[i] "\t" m[i]
      in_enum = 0
      next
    }
    # EVERY member occupies a slot, not just the GHOSTTY_-prefixed ones. Counting
    # only the prefixed ones let an inserted member renumber everything after it
    # while the report claimed nothing moved.
    in_enum && /^[[:space:]]*[A-Za-z_]/ {
      line = $0; sub(/^[[:space:]]*/, "", line)
      member = line; sub(/[^A-Za-z0-9_].*$/, "", member)
      if (line ~ /=/) {
        init = line
        sub(/^[^=]*=[[:space:]]*/, "", init); sub(/[[:space:]]*,.*$/, "", init)
        next_val = value_of(init)
      }
      m[n] = member; v[n] = next_val; n++
      if (next_val != "?") next_val = next_val + 1
      next
    }
  '
}

enum_values "$OLD_HEADER" | sort -t'	' -k3,3 > "$work/enums_old.tsv"
enum_values "$NEW_HEADER" | sort -t'	' -k3,3 > "$work/enums_new.tsv"

val_of() { awk -F'\t' -v s="$2" '$3 == s { print $2; exit }' "$1"; }

# ── Report ──────────────────────────────────────────────────────────────────
echo "### GhosttyKit API review — \`${OLD_TAG}\` → \`${NEW_TAG}\`"
echo
echo "Filtered to the **${used_count}** \`ghostty_*\`/\`GHOSTTY_*\` symbols Macterm's own sources reference and the header defines."
echo

# 1. Vanished symbols — a build error, named here so a red CI run isn't a mystery.
: > "$work/gone.txt"
while IFS= read -r sym; do
  if grep -qxF -- "$sym" "$work/ids_old.txt" && ! grep -qxF -- "$sym" "$work/ids_new.txt"; then
    echo "$sym" >> "$work/gone.txt"
  fi
done < "$work/used.txt"

if [[ -s "$work/gone.txt" ]]; then
  echo "#### ❌ Symbols we use that no longer exist"
  echo
  sed 's/^/- `/; s/$/`/' "$work/gone.txt"
  echo
  echo "This will fail the build. Either the API moved and our call sites need updating, or a fork patch stopped applying."
  echo
else
  echo "#### ✅ No symbol we use was removed"
  echo
fi

# 2. Renumbered enum constants. The quiet one: Swift imports these by name, so
#    the source still compiles.
: > "$work/renumbered.tsv"
: > "$work/unknown.txt"
while IFS= read -r sym; do
  case "$sym" in GHOSTTY_*) ;; *) continue ;; esac
  o=$(val_of "$work/enums_old.tsv" "$sym")
  n=$(val_of "$work/enums_new.tsv" "$sym")
  [[ -z "$o" || -z "$n" ]] && continue
  if [[ "$o" == "?" || "$n" == "?" ]]; then
    # Never silently equal. An unevaluated initializer is reported as such so it
    # can't masquerade as "value unchanged".
    printf '%s\t%s\t%s\n' "$sym" "$o" "$n" >> "$work/unknown.txt"
  elif [[ "$o" != "$n" ]]; then
    printf '%s\t%s\t%s\n' "$sym" "$o" "$n" >> "$work/renumbered.tsv"
  fi
done < "$work/used.txt"

if [[ -s "$work/renumbered.tsv" ]]; then
  n_renum=$(wc -l < "$work/renumbered.tsv" | tr -d ' ')
  echo "#### ⚠️ ${n_renum} enum constant(s) we use changed numeric value"
  echo

  # Show the cause before the effect. A renumber is nearly always somebody
  # inserting a member earlier in the same enum, and that member is usually one
  # we don't reference — so it gets filtered out of the diff section below and
  # the shift looks unexplained. Name it here.
  cut -f1 "$work/renumbered.tsv" > "$work/renum_syms.txt"
  awk -F'\t' 'NR==FNR { want[$1]; next } $3 in want { print $1 }' \
    "$work/renum_syms.txt" "$work/enums_old.tsv" "$work/enums_new.tsv" 2>/dev/null | sort -u > "$work/affected_enums.txt"
  # Both sides, so a renamed enum shows as removed-there/added-here rather than
  # every member reading as "added".
  awk -F'\t' 'NR==FNR { want[$1]; next } $3 in want { print $1 }' \
    "$work/renum_syms.txt" "$work/enums_old.tsv" | sort -u >> "$work/affected_enums.txt"
  sort -u -o "$work/affected_enums.txt" "$work/affected_enums.txt"

  while IFS= read -r en; do
    awk -F'\t' -v e="$en" '$1 == e { print $3 }' "$work/enums_old.tsv" | sort -u > "$work/mo.txt"
    awk -F'\t' -v e="$en" '$1 == e { print $3 }' "$work/enums_new.tsv" | sort -u > "$work/mn.txt"
    added=$(comm -13 "$work/mo.txt" "$work/mn.txt" || true)
    removed=$(comm -23 "$work/mo.txt" "$work/mn.txt" || true)
    [[ -z "$added$removed" ]] && continue
    echo "\`$en\`:"
    [[ -n "$added" ]] && sed 's/^/- added `/; s/$/`/' <<< "$added"
    [[ -n "$removed" ]] && sed 's/^/- **removed** `/; s/$/`/' <<< "$removed"
    echo
  done < "$work/affected_enums.txt"

  echo "<details><summary>Affected constants (${n_renum})</summary>"
  echo
  echo "| symbol | ${OLD_TAG} | ${NEW_TAG} |"
  echo "|---|---|---|"
  awk -F'\t' '{ printf "| `%s` | %s | %s |\n", $1, $2, $3 }' "$work/renumbered.tsv"
  echo
  echo "</details>"
  echo
  echo "Harmless as long as the header and the archive stay paired — the xcframework ships them together, and \`setup.sh\` only ever installs both from one release. Never pair one with the other's, and treat any hardcoded raw value as suspect. A **removed** member is the one to look at closely."
  echo
fi

if [[ -s "$work/unknown.txt" ]]; then
  n_unk=$(wc -l < "$work/unknown.txt" | tr -d ' ')
  echo "#### ❓ ${n_unk} constant(s) we use have a value this script can't evaluate"
  echo
  echo "| symbol | ${OLD_TAG} | ${NEW_TAG} |"
  echo "|---|---|---|"
  awk -F'\t' '{ printf "| `%s` | %s | %s |\n", $1, $2, $3 }' "$work/unknown.txt"
  echo
  echo "Listed rather than assumed unchanged — check these by hand if the enum was touched."
  echo
fi

# 3. The substance: changed hunks touching our symbols.
#
# Matched per HUNK, with context, not per changed line. A line-local match
# misses the two most common breaking changes in a C header, because neither
# names the symbol on the line that changed: a struct field's type
# (`uintptr_t text_len;` inside `ghostty_text_s`) and a parameter of a
# multi-line prototype (the header has ~20). Both reported "no relevant change"
# before — the one failure mode this script must not have.
diff -U6 "$OLD_HEADER" "$NEW_HEADER" > "$work/full.diff" || true
awk -v used="$work/used.txt" '
  BEGIN { while ((getline l < used) > 0) u[l] }
  /^(---|\+\+\+)/ { next }
  /^@@/ { if (hit) printf "%s\n", buf; buf = $0; hit = 0; next }
  {
    buf = buf "\n" $0
    if (!hit) {
      s = $0
      # Exact identifier membership, not substring: `ghostty_action_s` would
      # otherwise match `ghostty_action_scrollbar_s` and inflate the count.
      while (match(s, /[A-Za-z_][A-Za-z0-9_]*/)) {
        if (substr(s, RSTART, RLENGTH) in u) { hit = 1; break }
        s = substr(s, RSTART + RLENGTH)
      }
    }
  }
  END { if (hit) printf "%s\n", buf }
' "$work/full.diff" > "$work/relevant.diff" || true

if [[ -s "$work/relevant.diff" ]]; then
  echo "#### Changed hunks touching a symbol we use"
  echo
  echo '```diff'
  # Line-bounded, not byte-bounded: a byte cut lands mid-line and glues the
  # truncation marker onto a partial declaration inside the fence.
  head -n 400 "$work/relevant.diff"
  [[ $(wc -l < "$work/relevant.diff") -gt 400 ]] && echo "… truncated; see the compare link"
  echo '```'
  echo
else
  echo "#### No changed hunk touches a symbol we use"
  echo
fi

# `|| true`, never `|| echo 0`: grep -c already prints its count (0 included) and
# *then* exits 1 when nothing matched, so an `echo` fallback appends a second
# line and the footnote renders split in half.
changed=$(grep -cE '^[+-]' "$work/full.diff" 2>/dev/null || true)
hunks=$(grep -cE '^@@' "$work/relevant.diff" 2>/dev/null || true)
echo "<sub>${changed} changed header lines total; ${hunks} hunk(s) touch symbols we use. A green CI run means it builds and the suites pass — not that no behaviour moved.</sub>"
