# Azure LocalBox Deployment Guide Design

## Goal

Publish a public, Indonesian-language GitHub Pages guide for deploying Azure Jumpstart LocalBox, validating Azure Local VM readiness, diagnosing the misleading "23H2 and beyond" empty state, and upgrading Azure Connected Machine agents safely.

## Audience

Azure administrators and lab users deploying `microsoft/azure_arc/azure_jumpstart_localbox` from Windows PowerShell.

## Information Architecture

The guide is a single responsive page with these ordered stages:

1. Verify Azure CLI context and required providers.
2. Clone the official repository and prepare parameters.
3. Supply the VM administrator password through an environment variable.
4. Validate with ARM what-if and deploy the Bicep template.
5. Monitor the Azure Local deployment until all orchestration steps finish.
6. Validate VM management prerequisites: cluster status, Arc resource bridge, custom location, VM operator, logical network, and image.
7. Upgrade Azure Connected Machine agents, including the pre-1.62 MSI path and the 1.62+ `azcmagent upgrade` path.
8. Create and verify an Azure Local VM.

## Visual Direction

Use an operations-runbook aesthetic rather than a marketing landing page: compact navigation, numbered stages, command blocks, status badges, and full-width screenshots. The signature element is a readiness rail that distinguishes host OS readiness from Arc VM control-plane readiness. The page uses the mandatory Clawpilot theme variables, restrained Azure-blue links, and crimson only for active navigation and critical warnings.

## Content Rules

- Do not publish tenant IDs, subscription IDs, passwords, or user-specific resource names.
- Use placeholders in commands and explicitly label them.
- Use official Microsoft Learn screenshots and links for generic portal procedures.
- Explain that Windows Server 24H2 and connected host agents are necessary but not sufficient for Azure Local VM creation.
- State that the observed cluster status `DeploymentInProgress` and missing resource bridge/custom location/VM operator resources are the immediate blocker in this case.
- Explain that agent version 1.60 cannot use `azcmagent upgrade`; upgrade it with the signed MSI, then use `azcmagent upgrade` from version 1.62 onward.

## Interaction And Accessibility

- Sticky stage navigation with active-section highlighting.
- Copy buttons for commands, with accessible labels and status text.
- Expandable troubleshooting checks.
- Keyboard-visible focus, reduced-motion support, and responsive layouts from mobile to desktop.

## Validation

- Validate HTML structure and links locally.
- Test interactions and responsive layout with Playwright at desktop and mobile sizes.
- Confirm no real tenant, subscription, or credential values are present.
- Publish with the `publish-to-pages` skill to `ibranibeny/azure-localbox-deployment-guide`.
- Verify the GitHub Pages URL returns HTTP 200 and capture final desktop/mobile screenshots.
