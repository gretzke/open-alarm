# OpenAlarm — Design Spec (v0)

Last updated: 2026-02-23

## 1) Product visual direction

OpenAlarm should feel like a native, modern Apple app:

- **Primary style:** pronounced liquid-glass UI language
- **Base theme:** always dark, **pure black** (`#000000`)
- **Tone:** playful, friendly, airy
- **Platform target:** latest iOS (AlarmKit era; iOS 26+)

No light mode in v0.

---

## 2) IA / navigation (MVP)

Use a **floating glass pill tab bar** with 2 tabs:

1. **Alarm**
2. **Settings**

No Sleep tab yet.

---

## 3) Color system

### Core colors

- `color.bg.base`: `#000000` (OLED-first pure black)
- `color.text.primary`: `#F5F5F7`
- `color.text.secondary`: `#8E8E93`

### Brand + interactive cyan

- `color.brand.cyan`: `#85D9E7` (logo-matched cyan)
- `color.action.cyan`: `#64D2FF` (interactive accent)
- `color.action.cyan.active`: `#32C5FF`

### Contextual system colors

- `color.success`: `#30D158`
- `color.warning`: `#FFD60A`
- `color.danger`: `#FF453A` (Apple danger red)

### Glass treatments

- `glass.fill.default`: `rgba(255,255,255,0.08)`
- `glass.stroke.default`: `rgba(133,217,231,0.22)`
- `glass.glow.default`: `rgba(100,210,255,0.20)`

Notes:
- Surfaces remain black-first; glass should elevate elements without raising full-screen brightness.
- Default active controls use **cyan fill + glow**.

---

## 4) Typography

- Typeface: **SF Pro Rounded**
- Dynamic Type: **fully supported** (no hardcoded fixed sizes that break scaling)
- Leverage semantic text styles (`.largeTitle`, `.title2`, `.body`, `.caption`, etc.)

Accessibility expectation:
- Users scale text in iOS Settings; app respects those preferences.

---

## 5) Shape language + spacing

Friendly/bubbly geometry:

- `radius.card`: **24pt**
- `radius.button`: **20pt**
- `radius.chip`: **14pt**
- Pill CTAs: capsule/full rounded where appropriate

Spacing system (airy):

- base unit: 8pt
- common paddings: 16 / 20 / 24
- section gaps: 24–32

---

## 6) Component style

### Buttons

- Default style: **glass button + cyan accent**
- Active state: cyan fill + cyan glow
- Secondary actions: glass only, no strong fill
- Destructive actions: Apple danger red (`#FF453A`)

### Cards / panels

- Pronounced glass depth
- Subtle cyan-tinted 1px stroke
- Edge glow enabled (soft, not neon)

### Tab bar

- Floating glass pill style
- Selected tab: cyan fill + glow
- Unselected tabs: glass + muted text/icon

### Icons

- Use supplied brand icon as source for app identity
- UI iconography should stay native (SF Symbols where possible)

---

## 7) Motion + haptics

- Motion style: **subtle fluid animations**
- Use spring/interactive transitions conservatively
- Avoid noisy or distracting motion at night

Haptics:
- **Subtle haptics on key actions only** (tab switch, primary confirm, critical toggles)

---

## 8) Accessibility + comfort constraints

- Pure black base for nighttime comfort / OLED efficiency
- Respect Dynamic Type
- Keep contrast strong for key interaction states
- Keep glare low outside active controls

---

## 9) Out of scope for this phase

Deferred intentionally:

- Detailed alarm ring + mission screen design system
- Mission-specific high-contrast interaction patterns

Those will be designed in a dedicated next phase.

---

## 10) Implementation order (recommended)

1. Add shared design tokens (colors, radii, glass constants)
2. Build base theme wrappers for SwiftUI
3. Implement floating 2-tab shell (Alarm/Settings)
4. Restyle current skeleton screen with v0 language
5. Validate Dynamic Type + contrast + dark comfort

