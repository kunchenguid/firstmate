---
name: ui-task-brief
description: >-
  Agent-only procedure for briefing delegated UI work.
  Load before writing a ship or scout brief for a website, product interface, responsive phone web experience, PWA, or native iOS/Android screen.
user-invocable: false
metadata:
  internal: true
---

# UI task briefs

Use this skill when the captain's request concerns the experience people see or use.
The task lifecycle, scope authority, and brief scaffold remain owned by `AGENTS.md` sections 7 and 11.
This skill owns only the UI-specific evidence and acceptance details placed in `## Firstmate spec`.

## Identify the actual surface

Read the project's existing UI conventions and the captain's references before drafting.
Identify whether the target is a responsive website, PWA, Expo or React Native app, SwiftUI app, Android-native app, or a combination.
Name the specific screen or flow, its audience, the primary user action, and the existing design system or closest styled sibling.
If the captain asked for refinement, preserve the established brand and behavior; if the captain asked for redesign, state what is free to change and what product truth remains fixed.
Do not infer a new framework, component library, or visual direction from the availability of a skill.

## Make the brief executable

Add only the task-relevant items below to `## Firstmate spec`:

- The reference screen, design file, tokens, components, copy, and assets to reuse or inspect.
- The primary flow and the states that change the layout, such as loading, empty, error, success, long content, or an open keyboard.
- The required responsive behavior or native-platform differences, including safe areas, navigation, touch, dynamic text, and system appearance when relevant.
- Any existing skill or tool the worker can actually access that will help, such as a design skill, Figma connector, browser, or Expo guidance.
- The visual evidence and interaction checks that will establish completion: rendered desktop and phone views for responsive web, and the relevant iOS/Android builds for native work.

For a phone web surface, request a browser-emulated pass and a real-phone pass when hardware is available.
For native work, name which operating systems ship and ask the worker to state which devices, emulators, and builds were actually checked.
Never describe emulation as proof of real-device behavior.
Include keyboard, focus, semantics, contrast, text scaling, touch target, and reduced-motion checks in the relevant flow; ask for a full accessibility audit only when the captain's scope warrants one.

Keep the captain's request as the acceptance boundary.
Do not add a cross-app redesign, a library migration, speculative features, or an unrequested component-system extraction to a narrow UI task.
If the worker discovers a larger opportunity, have it report the opportunity separately.

## Evaluate the result

Review the worker's rendered evidence and exercised flow, not just a passing build or a confident description.
Compare the result with the requested design direction and existing product language.
Ask for a focused correction when a visible defect or required state is missing.
Distinguish actual phone or device testing from browser emulation, and relay any unverified platform behavior to the captain.
Use the existing captain-hold and visual-review contracts when the captain must choose among genuinely different designs.
