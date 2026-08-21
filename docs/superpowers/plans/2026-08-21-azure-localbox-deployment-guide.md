# Azure LocalBox Deployment Guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and publish a public Indonesian GitHub Pages runbook for Azure LocalBox deployment, VM readiness troubleshooting, and Arc agent upgrades.

**Architecture:** A self-contained static `index.html` contains content, styles, and interaction logic. Official Microsoft Learn screenshots are stored in `assets/`, while public commands use placeholders and avoid user-specific identifiers.

**Tech Stack:** HTML5, CSS, vanilla JavaScript, Playwright, GitHub Pages

---

### Task 1: Build the runbook

**Files:**
- Create: `index.html`
- Create: `assets/*.png`

- [ ] Download official Microsoft Learn screenshots for deployment and VM management stages.
- [ ] Create the full responsive runbook with readiness rail, command copy controls, troubleshooting, and citations.
- [ ] Scan generated content for secrets and user-specific identifiers.

### Task 2: Validate the experience

**Files:**
- Test: `index.html`
- Create: `validation/desktop.png`
- Create: `validation/mobile.png`

- [ ] Serve the static site locally.
- [ ] Validate desktop and mobile rendering with Playwright.
- [ ] Check console errors, navigation, command copy controls, responsive fit, and image loading.

### Task 3: Publish and verify

**Files:**
- Publish: `index.html`
- Publish: `assets/`

- [ ] Run the `publish-to-pages` script for `azure-localbox-deployment-guide`.
- [ ] Verify the repository and Pages deployment status.
- [ ] Confirm the live URL returns HTTP 200 and render it at desktop and mobile sizes.
