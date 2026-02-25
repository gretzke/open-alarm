# Liquid Glass audit — OpenAlarm (2026-02-26)

## Scope
Review current SwiftUI usage against Apple’s Liquid Glass guidance (as available via local Xcode AdditionalDocumentation + current in-app implementation).

## What’s already good

1. **Interactive glass usage exists in key controls**
   - Alarm list `+` control uses `.glassEffect(.regular.tint(...).interactive(), in: Circle())`.
   - Alarm/Nap save controls use interactive tinted glass circles.
   - Popover actions use interactive glass on rounded rects.

2. **Toolbar/popover behavior direction is aligned**
   - Actions increasingly use morphable floating controls and contextual popovers.

3. **Visual hierarchy is consistent in major surfaces**
   - Primary action is cyan-tinted and secondary controls are lower emphasis.

---

## Gaps / inconsistencies vs Liquid Glass style direction

### A) “Glass cards” are not actually Liquid Glass
`oaGlassCard()` currently uses manual fill/stroke/shadow (`OAColor.glassFill`, `OAColor.glassStroke`) rather than `glassEffect` material.

**Impact:** Looks glass-like, but does not get native Liquid Glass optical behavior (adaptive blur/reflection/interactivity).

**Recommendation:**
- Keep static card style where appropriate, but add a true liquid variant for surfaces that should read as interactive containers.
- Consider `oaLiquidCard()` using `.glassEffect(.regular, in: RoundedRectangle(...))`.

### B) Component vocabulary is mixed
Across onboarding/settings, some controls still use classic “filled rounded rectangle + shadow” while others use Liquid Glass.

**Impact:** App feels stylistically split between old and new design language.

**Recommendation:**
- Introduce reusable button variants and apply consistently:
  - `OAGlassButtonStyle.regular`
  - `OAGlassButtonStyle.prominent` (tinted)
- Use these in onboarding CTAs, settings row actions, and try-out button.

### C) No `GlassEffectContainer` where multiple nearby glass controls exist
Popover groups (and potential clusters) currently apply glass effects individually only.

**Impact:** Misses native blending/morphing opportunities and can be less optimal visually/perf-wise.

**Recommendation:**
- Wrap clustered glass controls in `GlassEffectContainer(spacing: ...)` where practical.

### D) Some tints/foreground pairings may be over-opinionated
Custom text colors on tinted glass can reduce adaptability versus system defaults.

**Recommendation:**
- Prefer system-like foreground hierarchy (`textPrimary`/default label) on tinted glass, reserve explicit danger coloring for destructive-only contexts.

### E) Inconsistent use of system glass button components
No `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` usage yet.

**Recommendation:**
- Test replacing some custom controls with native glass styles first (especially simpler buttons).
- Keep custom only where shape/placement truly requires it.

---

## Priority fixes

### P1 (high)
1. Standardize button system (prominent + regular glass variants).
2. Migrate remaining filled/shadow CTA buttons (onboarding/settings/try-out) to Liquid Glass variants.
3. Add `GlassEffectContainer` to clustered popover actions.

### P2 (medium)
1. Introduce true `oaLiquidCard()` and selectively migrate interactive cards.
2. Re-audit contrast in dark mode with tinted glass.

### P3 (low)
1. Evaluate replacing selected custom controls with `.buttonStyle(.glass/.glassProminent)` for closer platform fidelity.

---

## Suggested implementation approach

1. Build reusable style primitives first.
2. Migrate one screen at a time (Alarm list → Editor popovers → Settings → Onboarding).
3. Snapshot/regression check after each screen migration.
4. Keep a strict “no mixed old/new CTA style in same surface” rule.
