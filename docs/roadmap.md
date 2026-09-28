# Roadmap

## Overview

What is being built, what comes next, and what is not scheduled. Released versions and their host-visible API changes are recorded in the [changelog](../CHANGELOG.md); the acceptance criteria every change must keep are listed under [architecture → Design invariants](architecture.md#design-invariants).

## Delivered

The glow styles and quota-exhaustion alert are implemented; their release history is in the [changelog](../CHANGELOG.md).

## Near-term queue

- Running and terminal turn evidence for Cursor, Antigravity and OpenCode. Their providers supply usage observations only; Cursor and Antigravity finish turns through [completion hooks](session-lifecycle.md#completion-hooks), and OpenCode's persisted messages carry no lifecycle signal.
- Keep the bundle's `CFBundleShortVersionString` equal to the release tag, checked before tagging.
- A CI step that fails when the root `THIRD_PARTY_NOTICES.txt` and the bundled copy differ, and that checks the notices file is present in the built bundle.

## Later

Not scheduled.

- ChatGPT chat quota.
- Grok team accounts; the credits proxy does not report their quota.
- VS Code IDE usage integrations. GitHub Copilot CLI usage is already supported; this item refers to IDE-side support.
