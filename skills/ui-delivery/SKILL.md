---
name: ui-delivery
description: Deliver a complete web or phone interface from brief through visual implementation and device-aware review. Use for building or redesigning product screens, responsive web pages, PWAs, or native iOS/Android UI when visual quality and usable behavior both matter.
---

# UI delivery

Use the project's existing framework, design system, assets, and product language unless the user asks for a redesign. Treat a phone-sized web page, an installed PWA, and a native app as different surfaces. Match the platform before choosing components or verification tools.

## Establish the design contract

Before editing, inspect the current screen or nearest sibling, tokens, typography, components, navigation, and any reference image or Figma design the user supplied. State the screen's audience, primary task, visual direction, platform, and the one or two flows that must work. For an existing product, preserve its design language unless the request changes it. If the product has no design system, make a small coherent token set while building the requested surface; do not install a component library by default.

Plan the states that affect the layout: initial, loading, empty, error, success, and long or translated content where relevant. Include dark mode only when the product supports or requests it. Choose real copy and assets whenever available; identify placeholders clearly.

## Build for the surface

### Web and PWA

- Use semantic HTML and the project's established components. When available, use a specialist design skill such as `impeccable` for direction and polish or `design-taste-frontend` for a landing page or portfolio. Use `shadcn` only when it is available and the project uses shadcn/ui.
- Compose from reusable tokens for type, color, spacing, radius, and motion. Make the first viewport's hierarchy clear, then make the full flow work. Avoid decorative effects that obscure content or controls.
- Design responsive behavior deliberately: what moves, stacks, collapses, scrolls, or stays visible. Check narrow phones, a larger phone, tablet when relevant, and desktop. Do not shrink a desktop composition until it fits.
- On touch screens, account for safe areas, browser chrome, keyboard, scroll containment, input zoom, and pointer capability. Use `mobile-native` when available for a web app on phones or a PWA. Keep zoom enabled.

### Native iOS and Android

- Prefer platform navigation and controls over recreating them from web components. In Expo or React Native projects, use the matching Expo guidance available in the environment for native UI, navigation, design system, and animation. Use `animate-expo` when available for custom motion or gestures. Check the project's Expo SDK before applying version-specific advice.
- In SwiftUI projects, use the project's native component and navigation conventions, Apple Human Interface Guidelines, and `write-swift` when available. For Android-native work, follow the project's Compose and Material conventions.
- Account for safe areas, dynamic text, system appearance, keyboard, permission states, touch targets, and accessibility labels. Verify iOS and Android separately when both ship; visual similarity does not establish behavioral parity.

## Verify the result

Use a bounded review: build, inspect the affected flow at the shipped device classes, fix the defects found, and confirm the fixes once. Capture real rendered evidence where tools permit.

Check visual hierarchy, alignment, text wrapping, image crops, long content, empty and error states, and any promised motion. Exercise the primary flow with keyboard and touch. Use `accessibility-audit` when available for web WCAG work; include names, focus, contrast, reflow, target size, and reduced motion in ordinary UI review too. Automated scans are triage, not proof of accessibility.

For web, browser device emulation is a useful first pass; use a real phone for browser chrome, safe areas, touch, and keyboard behavior when one is available. For native apps, inspect a device or emulator build and state which platforms and builds were actually checked. Never claim real-device verification from screenshots or emulation alone.

Report the implemented surface, the important design choices, what you exercised, and any meaningful unverified device or platform behavior. Attach or link the rendered evidence when available.

## Tool routing

- Figma reference: use a connected Figma design-to-code workflow when the user supplies a Figma design and that workflow is available.
- Browser iteration: use the browser tool available in the environment; use Playwright for repeatable interaction checks when available and appropriate.
- Imagery: use supplied brand assets first. Generate custom imagery only when the brief benefits from it and the image tool is available.
- Motion: use `animate` for web or `animate-expo` for Expo when available; add motion only when it clarifies feedback, state, or spatial change.

Do not replace a project's framework, install a large library, or create a separate design artifact merely to follow this skill. The user's requested deliverable and existing project conventions decide the scope.
