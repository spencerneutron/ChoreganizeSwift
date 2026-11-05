# Completion effects: behaviour and triggers

Decided 2026-11-05 with the product owner, in the wash-lab playground. Items marked **proposed** were not stated by the owner and need a yes before they are built. Items marked **open** are investigations.

## 1. Vocabulary

- **Day page**: one day in the Work view (`DayPage`). It renders wherever `DayPage` is used: the iPhone pager, the iPad and iPhone Duo two-day spread, the Calendar's day page, and the Mac.
- **Section**: a group of chores on a day page. With "Group tasks by" off there is one section (the dated one); with grouping on, one per group. Each section is one card on iOS. The one-offs section and the day's action rows are not sections for these effects.
- **Section progress**: done ÷ total of that section's chores for that day.
- **Rim**: the light on a section card's edge (effect 2).
- **Flourish**: the rim's full retrace when a section is finished.
- **Wash**: the background nebula (effect 1).
- **Local action**: the user's own tap on this page: a row toggle, Mark all done, or a confirmed photo check-off. A sync from another household member, a widget completion, a page load and Finish Day are not local actions.

## 2. The wash (whole day)

### 2.1 Trigger
- Fires when the **last open chore of the day** is completed by a **local action**, i.e. the day's "complete" state goes false → true with a local completion in the previous 3 s, on an unlocked day. Implemented: `WashTrigger.shouldWash` and the `onChange(of: dayComplete)` in `DayPage`.
- **Completing one section when other sections still have open chores does not fire the wash.** That section gets its rim flourish only. Only the absolute final completed task of the day, which by definition finishes the last section, fires the wash.
- Finish Day never fires it (it locks the day; it is not a completion).
- **Proposed:** any unlocked day page can fire it, not only today, since the action is the user's and the page is the one they are looking at. **Proposed:** unchecking and re-checking the last chore fires it again (the rule is edge-based), rate-limited to once per 30 s per page.

### 2.2 What plays
- Shader iteration 06 "night haze": `ChoreWash.metal`, look 1 (calm), motion 1 (roll-through), 8.0 s, seed random per play.
- It enters at the lower trailing corner, slows through the middle of the screen (fast-slow-fast, never reverses), and leaves at the upper leading corner with a soft tail; the tail clears the far corner at the end of the 8 s. A star-like glow sits off the entry corner and spills a little light ahead of the gas.
- Light mode: the gas tints its way over the page. Dark mode: a dusky lavender haze arrives with the front and the gas deepens out of it, with lightness compressed into the same contrast band as day.
- Colours: amber `#FFC233`, lavender `#AEB4FF`, honey `#FFD978`, mixed in OKLab inside the shader.
- Strength 1.0 on iOS, 0.55 on the Mac (its rows have no cards).

### 2.3 Where it draws
- Behind the cards, over the page's whole background, edge to edge (the layer ignores safe areas). The cards stay opaque; nothing draws over text.
- Implemented today as the `DayPage` List's background (`scrollContentBackground(.hidden)` + `CompletionWashLayer`).

### 2.4 iPhone Duo and iPad spreads (owner rule)
- When two day pages share the inner display, **the wash transits the whole display, not one page**, whichever page's completion fired it. It must never stop at the fold or at the midline, in either the left or the right case.
- Implementation: lift the layer from `DayPage` to the spread container (the two-page `WeekView` layout and the Calendar's two pages on Duo), sized to the full spread, and let the completing page raise the event (a preference key or an `AppModel` value with the start date and seed). On a single-page layout the container is the page itself, so iPhone behaviour is unchanged. The entry corner stays the lower trailing corner of the whole display.

### 2.5 Timing with the rim
- The last section's flourish and the wash start together and share the 8 s clock (§3.4), so the rim finishes while the gas lingers mid-screen.

### 2.6 Reduce Motion, Low Power, haptics, accessibility
- Reduce Motion or Low Power Mode: no shader. The amber-to-lavender gradient fades in to 0.7 over 0.4 s and is gone by 1.4 s (`CompletionWashLayer.fade`).
- Haptic: `WashHaptics` (a soft Core Haptics swell, success-notification fallback; none on Mac).
- The layer is `allowsHitTesting(false)` and `accessibilityHidden(true)`. **Proposed:** post a VoiceOver announcement "Day complete" when the wash fires, since the celebration is otherwise invisible to VoiceOver.

## 3. The section rim (per section)

### 3.1 At rest
- Each section card carries a hairline (1.4 pt) on its edge, drawn as a **fraction of the perimeter equal to the section's progress**, starting at the lower trailing corner and running along the bottom, up the leading side, across the top and down the trailing side.
- Stroke opacity grows with progress (0.25 at the first completion to 0.60 at 100 %); a faint halo outside the edge grows with it (0 to 0.14 at 100 %).
- A finished section keeps its full rim ("completed day borders stay in place") until one of its chores is unchecked.
- Colour: **honey `#FFD978` by day, lavender `#AEB4FF` by night.** Honey on black read as gaudy; lavender sits inside the night wash's own haze.

### 3.2 Changes between levels
- Any change of progress, up or down, **eases** the rim from the old fraction to the new one (about 0.25 s, ease-out). It never steps. This includes unchecking, Mark all done, photo check-off and synced changes from other members.

### 3.3 The light
- The halo **emits from the edge outward and never into the card**: brightest on the border, falling off smoothly like a diffuse strip light, with no visible band or second edge. Demo: a 3 pt stroke on the edge blurred at two radii (σ 6 and σ 18) and masked to the outside of the card. App: see §3.6.
- Keep it gentle. Peak halo opacity during a flourish 0.40; at rest 0.14.

### 3.4 The flourish (section finished)
- When a section reaches 100 % by a local action, the rim is **retraced round the whole perimeter** from the lower trailing corner, over the resting rim, with a small bright head at the drawing tip, regardless of the level it had before. The retrace runs from 0.8 s to 5.8 s on the 8 s clock (the wash's clock when the day also completes; its own clock otherwise), then the halo rises briefly (to 0.40 by 7.4 s) and settles to the resting values.
- A section finished by a synced change (another member) eases to 100 % without the flourish (**proposed**).
- Reduce Motion: no retrace and no head; the rim cross-fades to 100 % over 0.3 s.
- **Proposed:** a light `.selection` haptic when the head completes the loop.

### 3.5 What does not get a rim
- The day's action rows (Mark all done, Check off with a photo, Finish Day, Unlock Day, Log completions): they are controls.
- The one-offs section, the Quick Add ghost, the Edit tab's rows, and the Mac's rows (no cards; **open:** whether the Mac gets a hairline under the section header instead).

### 3.6 Implementation plan (not built)
- Draw the rim in the wash's layer, which already sits behind the cards: pass each visible section card's frame and corner radius plus its fraction, flourish progress and halo level as a `floatArray` argument; per pixel, compute the rounded-rectangle signed distance, light the outside with `exp(-d / falloff)` (two falloffs for near and far), and gate the hairline by arc length along the boundary for the fraction. This is resolution-independent and costs nothing where no card is near.
- Section frames come from `onGeometryChange` on each section (in the List's coordinate space); the layer reads them from a preference.
- The resting rim means the shader layer is alive at rest with a one-frame draw per change; the `TimelineView` runs only during a flourish or wash. Alternative if simpler: a SwiftUI `RoundedRectangle` stroke with `.trim(from:to:)` and two blurred strokes masked outside, which is the demo's construction.

## 4. The toggles (approved)

- `PromiseToggleStyle` on the Work rows: off track `#E8DFC8` light / `#433D31` dark (the system switch grey warmed a hint toward gold; it must not read as active), on track `#7370CF` light / `#8285DF` dark (4.1:1 and 3.5:1 against the white thumb). Only the control toggles, not the row.
- Restores what the system switch gives: the toggle trait and On/Off value, a selection haptic, a checkmark/circle glyph under Differentiate Without Color. Locked rows dim the control.
- Mac: a 16 pt ring that fills with a check.
- To ship: remove the `ToggleLook` flag (or keep it for a Developer toggle) and make the style the default on the Work rows. **Open:** VoiceOver wording for a Button-based toggle (test on device), the Mac look (compiled only).

## 5. Open investigations

1. **Colour-blind check.** Simulate protan, deutan and tritan vision on the rim (honey/lavender against the cards) and on the toggles. Low concern as long as colour stays sparse and state also reads by position, fill and lightness; the rim is a progress fraction (shape) and the toggle thumb moves.
2. **The action rows' system blue.** Investigate whether the system tint on Mark all done / Finish Day etc. should stay (the accessibility default; the `AccentColor` asset is empty), or be brought into the day language, for example the on-lavender as the app accent or only on the Work action rows. Check 4.5:1 text contrast on the cards in both appearances and the HIG on tinted text buttons before changing anything.
3. **Mac rim** (§3.5) and **VoiceOver announcements** (§2.6, §3.4).
4. **Device cost.** The wash is about 54 noise lookups per covered pixel; profile on the oldest supported iPhone with Xcode's GPU tools before release. The `look` parameter can trade quality for cost if needed.
5. **120 Hz.** The app does not set `CADisableMinimumFrameDurationOnPhone`; an app-wide decision.
