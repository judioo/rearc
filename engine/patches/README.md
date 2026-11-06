# ReArc patch overlay conventions

This directory holds the **entire** divergence between ReArc's engine and
vanilla upstream Chromium. If it isn't in here (or in the additive overlay
tree described below), it isn't in the engine. Keep it that way — the pin in
`engine/CHROMIUM_PIN` is only cheap to bump while this overlay stays small
and mechanical.

The authoritative description of *what* each patch is for and whether it's
REQUIRED / NICE-TO-HAVE / SHELL-ONLY lives in `engine/docs/ENGINE.md` §4.
This file defines *how* patches are named, ordered, applied, and rebased.

## Layout

```
engine/patches/
  README.md                 # this file
  series                    # ordered list of patches to apply (one per line)
  chrome/
    001-app-host-runloop.patch
    002-tab-strip-shell-model.patch
  content/
    001-webcontents-view-accessor.patch
  build/
    001-framework-branding.patch
```

**Naming:** `<area>/<nnn>-<slug>.patch`

- `<area>` mirrors the Chromium top-level directory the patch primarily
  touches: `chrome/`, `content/`, `components/`, `build/`, `third_party/`,
  `mojo/`, … A patch touching several areas goes under the area of its most
  significant hunk.
- `<nnn>` is a zero-padded sequence number *within the area*. Numbers are
  never reused; a dropped patch leaves a gap.
- `<slug>` is lowercase kebab-case describing the change, not the feature
  (`host-runloop`, not `rearc-shell`).

**`series` file:** one patch path per line, in apply order. Lines starting
with `#` are comments. Order matters only where patches touch the same file;
keep cross-file dependencies to a minimum and note them in a comment.

## Authoring rules

1. **Additive first.** Prefer new files (bridge code under
   `chrome/browser/rearc_bridge/`, new `.mojom` files) over edits to
   upstream files. Additive paths can collide with new upstream files and still require API rebasing.
2. **Minimal, hunk-isolated edits.** When an upstream file must change, keep
   each hunk as small as possible and as far from other ReArc hunks as
   possible. Two patches must never overlap the same hunk region.
3. **No drive-by changes.** A patch does exactly what its slug says. No
   reflowing, no comment churn, no "while I'm here."
4. **Patch header.** Every patch starts with a comment block (in the diff
   itself, as the commit-message-style leading text `git apply` ignores):
   patch ID from ENGINE.md §4, one-paragraph rationale, and the date of the
   last rebase.
5. **No `#ifdef REARC` sprawl.** We patch directly rather than maintaining a
   build-time fork switch. The overlay *is* the fork.
6. **Never patch generated files** (`*.grd`-derived headers, `mojom` outputs,
   version headers). Patch their sources instead.

## How application works

`engine/scripts/fetch.sh` performs a shallow, pinned source/dependency sync
only, with hooks disabled. It preserves local work and refuses a changed HEAD
instead of resetting an existing checkout. Resume by running it again after the
previous process exits. See [FETCH-STATUS.md](../docs/FETCH-STATUS.md).

After sync completes:

1. Run `engine/scripts/fetch.sh --runhooks`.
2. Run `engine/scripts/fetch.sh --apply-overlay`. It rejects additive paths
   already tracked or present in the checkout, copies/stages each new file,
   and applies `series` in order with `git apply --3way --index`.
3. The script commits only the staged overlay/patch changes. A failed patch
   leaves the index for manual resolution; do not rerun sync over that work.
4. Run `engine/scripts/build.sh` for the first compilation attempt.

An empty series and absent overlay leave stock Chromium. P-APP-001 remains a
specification: this bootstrap does not implement an embedding ABI or lifecycle.
A repeated application after an overlay commit is deliberately refused; inspect
and preserve the existing commits rather than resetting them.

## Rebase checklist (Chromium version bump)

Preserve the existing overlay commits and local work before changing the pin.
The bootstrap refuses an existing checkout at another pin; it is not automatic
rebase tooling. Refresh patches against the new pin in a separately prepared
scratch checkout, then run the hooks/application stages. For each failure:

- [ ] Inspect the reject / 3-way conflict. Decide: upstream changed the code
      path (refresh the hunk), upstream renamed/moved the file (re-point the
      patch), or upstream absorbed/obsolete'd the change (drop the patch,
      update ENGINE.md §4).
- [ ] Regenerate the refreshed patch with minimal context
      (`git diff -U3`) and verify it applies cleanly to the new tag in a
      scratch checkout.
- [ ] Check additive bridge code still compiles against renamed upstream
      APIs — overlay files don't "fail to apply," they fail to *build*, so
      run `build.sh` early, not after all patches are refreshed.
- [ ] Re-check `P-APP-001` (runloop) and any patch touching
      `chrome/app/` or `chrome/browser/ui/` — these are the highest-churn
      upstream areas and the usual rebase cost.
- [ ] Update the "last rebased" date in each touched patch header.
- [ ] Full build + smoke test: create tab, navigate, close, favicon+title
      events, space switch, media play/pause/PiP, renderer crash recovery.
- [ ] Commit `CHROMIUM_PIN`, refreshed patches, and any overlay fixes in
      **one commit**.

## Current inventory

No patch files exist yet. The planned inventory, with IDs from `engine/docs/ENGINE.md` §4:

| Planned patch | Area | ID | Class |
|---|---|---|---|
| Host-driven runloop / startup-UI suppression | `chrome/` | `P-APP-001` | REQUIRED |
| Shell tab model + WebContents delegate hooks | `chrome/` | `P-TAB-001` | REQUIRED |
| Bridge mojo interfaces + binder registration | `chrome/`, `mojo/` | `P-MOJO-001` | REQUIRED (v1.1) |
| Navigation/event bridge | `chrome/` | `P-NAV-001` | REQUIRED |
| Native PiP routing | `chrome/` | `P-PIP-001` | NICE-TO-HAVE |
| Per-space storage partitioning | `components/` | `P-PROF-001` | NICE-TO-HAVE |
| Framework/helper branding | `build/`, `chrome/` | `P-BUILD-001` | NICE-TO-HAVE |
