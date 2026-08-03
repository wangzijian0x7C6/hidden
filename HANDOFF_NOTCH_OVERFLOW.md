# Handoff: Hidden Bar notch overflow

## Goal

On a notched MacBook, keep the native menu bar items that fit on the right and mirror only the items displaced past the notch into the left menu-bar area. The left-side items should look and behave like their native counterparts.

## Repository state

- Worktree: `/Users/wangzijian/Documents/Codex/2026-07-22/00-00-23-59-im-current-3/work/hidden-notch-overflow`
- Fork: `https://github.com/wangzijian0x7C6/hidden`
- Upstream: `https://github.com/dwarvesf/hidden`
- Branch: `agent/notch-overflow-bar`
- Draft PR: `https://github.com/wangzijian0x7C6/hidden/pull/1`
- Current commit and installed build: `913a880`
- Worktree was clean when this handoff was written.
- Current app: `/Applications/Hidden Bar.app`
- Signature: ad hoc, bundle ID `com.dwarvesv.minimalbar`; every replacement can require Accessibility and Screen Recording authorization again.

## Current result

Working:

- Items that fit remain native on the right.
- Only items whose native window lies left of `NSScreen.auxiliaryTopRightArea.minX` are mirrored left of the notch.
- Mirrored icons use their real menu-bar pixels, not application icons.
- The proxy panel avoids the current foreground application's menu items by reading their AX frames.
- Typical expand time after authorization is about 0.18–0.34 seconds.

Not working:

- Clicking a mirrored item does not reliably activate it. The user reports that the pointer moves away and the item does not open.
- `Command`-drag behavior has code but is not verified as usable/native-equivalent.
- The left side is still a proxy `NSPanel`, not genuine `NSStatusItem` windows. Exact native parity must be simulated.

## Important evidence

Runtime log: `/tmp/hidden-notch-6F2C.log`

Latest successful geometry on a 1440×932 display:

```text
separator={{1035, 0}, {25, 29}}
expandCollapse={{1060, 0}, {21, 29}}
rightArea={{798, 904}, {642, 28}}
overflowCount=4 or 6
leftArea={{308, 904}, {326, 28}}
panel visible=true
```

The 80ms delay at `StatusBarController.swift:572` is load-bearing. Removing it captured the still-collapsed 2885pt separator at a negative X coordinate and produced `items=0`. The earlier 40ms and 160ms delays were unnecessary and remain removed.

Offscreen pixels require both:

1. Private `CGSGetProcessMenuBarWindowList` to obtain the actual menu-bar window IDs.
2. `CGImage(windowListFromArrayScreenBounds:windowArray:imageOption:)`; `CGWindowListCreateImage(...optionIncludingWindow...)` returned no pixels for offscreen items.

Do not regress either mechanism.

## Relevant code

- Expand/capture/show pipeline: `hidden/Features/StatusBar/StatusBarController.swift:539`
- Overflow selection: `StatusBarController.swift:643`
- Native window image + AX association: `StatusBarController.swift:740`
- AX cache and scan: `StatusBarController.swift:813`
- Private menu-bar window enumeration: `StatusBarController.swift:998`
- Click path: `StatusBarController.swift:1208`
- Synthetic Command-drag path: `StatusBarController.swift:1223`
- Proxy panel positioning: `hidden/Features/StatusBar/HiddenItemsBarPanelController.swift:84`
- Foreground application menu boundary: `HiddenItemsBarPanelController.swift:116`
- Proxy mouse handling: `HiddenItemsBarPanelController.swift:376`

## Click defect: current understanding

The old implementation posted mouse events at the original offscreen coordinates, which visibly moved the pointer. That code was removed.

The current click path is:

```swift
if let element = item.accessibilityElement ?? accessibilityElement(for: item) {
    AXUIElementPerformAction(element, kAXPressAction as CFString)
}
```

Despite this, the user still observes pointer movement and no activation. Do not assume `AXPress` is correct merely because it returns. Likely candidates, in order:

1. The frame-only AX match selects the wrong `AXExtrasMenuBar` child after items move.
2. `AXPress` for the correct offscreen status item is implemented by the source app as a virtual pointer action and opens at an unusable/offscreen anchor.
3. The proxy view misclassifies a small movement as a click or drag; instrument `mouseDown`/`mouseUp` classification.

Build one tight diagnostic before changing behavior. Log under one new tag:

- proxy item/window ID and source rect;
- matched AX element frame and source PID;
- `AXUIElementPerformAction` return code;
- cursor position immediately before and 100ms after;
- whether `moveHiddenItem` was entered.

One user click should distinguish all three hypotheses. Do not issue another build based only on a guess.

## Recommended interaction direction

For native-like activation, study the already cloned Ice implementation:

```text
/Users/wangzijian/Documents/Codex/2026-07-21/zha/work/Ice-macos26/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift
```

Ice does not rely solely on `AXPress`. For an offscreen item it temporarily moves the real status item into usable native menu-bar space, posts item-specific click events, then restores the item. Its relevant methods are `temporarilyShow`, `postClickEvents`, and `postMoveEvents`.

The smallest robust next design is probably:

1. Retain the proxy only for display.
2. On click, temporarily move the real item to a visible right-side slot, click it natively, then restore it after the menu closes.
3. On Command-drag, translate proxy source/target into the same real-item move operation.

Do not copy Ice's GPL code into this repository. Reimplement only the required behavior or resolve licensing first.

## Build and install

There is no local full Xcode. Pushing the branch triggers `.github/workflows/build.yml` on a macOS runner and uploads artifact `Hidden-Bar-notch-overflow`.

Typical sequence:

```text
git push origin agent/notch-overflow-bar
gh run list --repo wangzijian0x7C6/hidden --branch agent/notch-overflow-bar
gh run watch <run-id> --repo wangzijian0x7C6/hidden --exit-status
```

Download the artifact, unzip the outer artifact and inner `Hidden-Bar-notch-overflow.zip`, verify with `codesign --verify --deep --strict`, back up `/Applications/Hidden Bar.app`, replace it, and restart.

Latest successful workflow run: `30783084098`.

## Cleanup before release

The branch still contains temporary diagnostics. Before declaring complete:

- Remove `notchDebug` and all `[DEBUG-NOTCH-6F2C]` calls.
- Remove `/tmp/hidden-notch-6F2C.log` creation.
- Remove obsolete capture shield/separator overlay code if no longer used.
- Re-run the original click, Command-drag, long-Chrome-menu overlap, and expand-latency scenarios.
- Package only after those checks pass.

