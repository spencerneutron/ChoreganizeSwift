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
- A change in which chores the page shows (a scope switch, a sync adding or removing chores) is never a completion, even within 3 s of the user's last tap; the wash and the rim flourishes ignore that update.
- The Mac's photo check-off sheet posts `choreganizeLocalCompletion` before it records, so today's page counts it as the user's action.
- Any unlocked day page can fire it, not only today, since the action is the user's and the page is the one they are looking at. Unchecking and re-checking the last chore fires it again (the rule is edge-based), at most once per 30 s per page (`WashTrigger.refireInterval`). Both approved 2026-11-05. A chore added to the day (Quick Add, another device) re-arms it at once: finishing new work is never held back by the limit (owner, 2026-11-05).

### 2.2 What plays
- Shader iteration 06 "night haze": `ChoreWash.metal`, look 1 (calm), motion 1 (roll-through), 8.0 s, seed random per play.
- It enters at the lower trailing corner, slows through the middle of the screen (fast-slow-fast, never reverses), and leaves at the upper leading corner with a soft tail; the tail clears the far corner at the end of the 8 s. A star-like glow sits off the entry corner and spills a little light ahead of the gas.
- Light mode: the gas tints its way over the page. Dark mode: a dusky lavender haze arrives with the front and the gas deepens out of it, with lightness compressed into the same contrast band as day.
- Colours: amber `#FFC233`, lavender `#AEB4FF`, honey `#FFD978`, mixed in OKLab inside the shader.
- Strength 1.0 on iOS, 0.55 on the Mac (its rows have no cards).

### 2.3 Where it draws
- Behind the cards, over the page's whole background, edge to edge (the layer ignores safe areas). The cards stay opaque; nothing draws over text.
- Implemented today as the `DayPage` List's background (`scrollContentBackground(.hidden)` + `CompletionWashLayer`).

### 2.3a Paging while it plays (owner rule, 2026-11-05)
- While a wash plays, the Work view's side-to-side paging and the iPhone Duo's day rail are held still, on every device; each day's list still scrolls vertically. The wash is drawn by the page, so a swipe would carry it away mid-play. Under Reduce Motion or Low Power the hold lasts only as long as the fade (1.4 s).

### 2.4 iPhone Duo and iPad spreads (owner rule)
- When two day pages share the inner display, **the wash transits the whole display, not one page**, whichever page's completion fired it. It must never stop at the fold or at the midline, in either the left or the right case.
- Implemented: the completing `DayPage` raises a `WashRequest` preference (start, seed); the container draws it with `completionWashHost(base:)` (WeekView's pager pages; the Calendar's two pages, whose base is grouped up to the fold and plain after). A page outside a host (the Mac, a pushed Calendar day) draws its own. The entry corner is the lower trailing corner of the whole display. The host keeps a wash to its end even if the page that raised it is rebuilt meanwhile (tapping another day in the Calendar mid-wash).

### 2.5 Timing with the rim
- The last section's flourish and the wash start together and share the 8 s clock (§3.4), so the rim finishes while the gas lingers mid-screen.

### 2.6 Reduce Motion, Low Power, haptics, accessibility
- Reduce Motion or Low Power Mode: no shader. The amber-to-lavender gradient fades in to 0.7 over 0.4 s and is gone by 1.4 s (`CompletionWashLayer.fade`).
- Haptic: `WashHaptics` (a soft Core Haptics swell, success-notification fallback; none on Mac).
- The layer is `allowsHitTesting(false)` and `accessibilityHidden(true)`. A VoiceOver announcement "Day complete" posts when the wash fires, since the celebration is otherwise invisible to VoiceOver (approved 2026-11-05).

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
- A section finished by a synced change (another member) eases to 100 % without the flourish (approved 2026-11-05). VoiceOver hears "<section> complete" on a flourish, unless the day finished with it ("Day complete" then).
- Reduce Motion: no retrace and no head; the rim cross-fades to 100 % over 0.3 s.
- Not built: a light `.selection` haptic when the head completes the loop (was proposed; not taken up).

### 3.5 What does not get a rim
- The day's action rows (Mark all done, Check off with a photo, Finish Day, Unlock Day, Log completions): they are controls.
- The one-offs section, the Quick Add ghost, the Edit tab's rows, and the Mac's rows (no cards; **open:** whether the Mac gets a hairline under the section header instead).

### 3.6 Implementation (built 2026-11-05)
- As built: one `colorEffect` view per section card (`SectionRimView`, shader `sectionRim` in `SectionRim.metal`): a signed distance to the rounded card, the hairline and a half-Gaussian halo outside it, gated by arc length for the fraction, a bright head during the flourish. It draws in `DayPage`'s background, behind the List, so it only ever shows outside the opaque card.
- Card rects: each chore row's `listRowBackground` (the card colour, as before) reports its global frame to an `@Observable` `SectionRimTracker`, keyed by the chore. The section's current chore order is applied when the card is read: the card is the longest run of rows that sit flush one under the next, with the others estimated at the run's average row height. (Recording each row's index when it reported let a chore added above a row leave a stale index, which stretched the card into the next section.) The layer subtracts its own global origin. Card corner radius 25 pt on iOS 26+, 10 pt before (measured on iOS 27; iOS 26.x and iPad not measured).
- Section keys: the section title, made unique ("No Room#1") because titles can repeat.
- Reduce Motion or Low Power Mode: no retrace, no head; levels cross-fade.

The plan it followed:
- Draw the rim in the wash's layer, which already sits behind the cards: pass each visible section card's frame and corner radius plus its fraction, flourish progress and halo level as a `floatArray` argument; per pixel, compute the rounded-rectangle signed distance, light the outside with `exp(-d / falloff)` (two falloffs for near and far), and gate the hairline by arc length along the boundary for the fraction. This is resolution-independent and costs nothing where no card is near.
- Section frames come from `onGeometryChange` on each section (in the List's coordinate space); the layer reads them from a preference.
- The resting rim means the shader layer is alive at rest with a one-frame draw per change; the `TimelineView` runs only during a flourish or wash. Alternative if simpler: a SwiftUI `RoundedRectangle` stroke with `.trim(from:to:)` and two blurred strokes masked outside, which is the demo's construction.

## 4. The toggles and the accent (decided 2026-11-05)

- **The system switch, tinted lavender**: on track `#7370CF` light / `#8285DF` dark (4.2:1 and 3.3:1 against the white thumb). The off track stays the system grey: there is no API to tint it, and the owner chose to keep Apple's switch (its iOS 26 glass thumb, drag, VoiceOver) over the custom `PromiseToggleStyle` (warm-grey off track), which was removed.
- The same pair is the app's **accent** (`AccentColor`, app and widget), replacing system blue everywhere it showed: action rows, the Quick Add ghost, buttons, the tab bar. On the Mac it shows only while the user's system accent is Multicolor; otherwise macOS uses the user's own accent, as it intends. Increase Contrast: `#4B48AE` light (7.4:1 on white, on par with system blue's 7.6:1); dark keeps `#8285DF` so the switch stays 3.3:1 against its thumb.
- Accepted trade-off: white on the dark accent (prominent buttons, the Calendar's today circle) is 3.3:1, against 3.65:1 for system blue. A deeper dark lavender would raise fills and the switch to about 3.6:1 and lower accent text on the dark card from 5.2:1 to about 4.7:1; not changed, as the pair is the owner's pick. As text it reads at least as well as system blue did (4.2:1 vs 4.0:1 on white; 5.2:1 vs 4.7:1 on the dark card).

## 5. Open investigations

1. **Colour-blind check.** Simulate protan, deutan and tritan vision on the rim (honey/lavender against the cards) and on the toggles. Low concern as long as colour stays sparse and state also reads by position, fill and lightness; the rim is a progress fraction (shape) and the toggle thumb moves.
2. **The action rows' system blue.** Resolved: the lavender accent replaces system blue app-wide (§4). Remaining "boilerplate" colour spots, suggested, not built: the calendar's future-day dashes (`Color.blue`), the "done = green" spots (Finish Day check, widget and Mac 100 % green, Insights heatmap, the perfect-day bar).
3. **Mac rim** (§3.5) and **VoiceOver announcements** (§2.6, §3.4).
4. **Device cost.** The wash is about 54 noise lookups per covered pixel; profile on the oldest supported iPhone with Xcode's GPU tools before release. The `look` parameter can trade quality for cost if needed.
5. **120 Hz.** The app does not set `CADisableMinimumFrameDurationOnPhone`; an app-wide decision.
