# Xcode 27 mcpbridge Tool Additions

## Verified Environment

- Xcode 26.6: `/Applications/Xcode.app`, build `17F109`, `xcode-tools` server version `24950`
- Xcode 27.0: `/Applications/Xcode_27.app`, build `27A5209h`, `xcode-tools` server version `25245.3`
- MCP protocol: `2025-06-18`

Xcode 26.6's `tools/list` returned 21 tools. Xcode 27.0's `tools/list`
returned 43 tools. No tools were removed; 22 tools were added.

This document is based on the raw `tools/list` descriptors, the `mcp__xcode`
tool metadata exposed to Codex, and light read-oriented runtime checks against
the Xcode 27 MCP server.

## Added Tools

| Category | Tool | Primary purpose |
| --- | --- | --- |
| Scheme / Destination | `XcodeListSchemes` | List workspace schemes and report the active scheme |
| Scheme / Destination | `XcodeSwitchScheme` | Change the active scheme |
| Scheme / Destination | `XcodeListRunDestinations` | List run destinations available to the active scheme |
| Scheme / Destination | `XcodeSwitchRunDestination` | Change the active run destination |
| Run / Debug | `RunProject` | Build and run the active scheme |
| Run / Debug | `StopProject` | Stop the app currently running from Xcode |
| Run / Debug | `GetConsoleOutput` | Read stdout, stderr, and OSLog output for a run session |
| Run / Debug | `InvokeDebuggerCommand` | Send a command to the active LLDB debug session |
| Device Interaction | `DeviceInteractionStartSession` | Start an iOS device or simulator interaction session |
| Device Interaction | `DeviceInteractionInstallAndRun` | Build, install, and run the app on the session device |
| Device Interaction | `DeviceInteractionSynthesize` | Synthesize taps, swipes, typing, and capture UI state |
| Device Interaction | `DeviceInteractionEndSession` | Close a device interaction session |
| Build Settings | `GetFileCompilerFlags` | Read per-file compiler flags |
| Build Settings | `UpdateFileCompilerFlags` | Update, append, or delete per-file compiler flags |
| Localization | `LocalizationPlanner` | Prepare String Catalogs for translation work |
| Localization | `StringCatalogRead` | List keys by translation state for a locale |
| Localization | `StringCatalogContext` | Read source value and usage context for a String Catalog key |
| Localization | `StringCatalogEdit` | Insert a translation into a String Catalog |
| Organizer Diagnostics | `GetTopCrashIssues` | Fetch top crash signatures from Organizer crash reports |
| Organizer Diagnostics | `GetCrashIssueLogs` | Fetch logs and triage context for a crash signature |
| Organizer Diagnostics | `GetTopFieldPerformanceIssues` | Fetch top field performance issue signatures |
| Organizer Diagnostics | `GetFieldPerformanceIssueLogs` | Fetch detailed logs for a performance issue signature |

## Scheme / Destination

### `XcodeListSchemes`

Lists schemes visible in the current workspace and identifies the active scheme.
Each scheme includes `name`, `disambiguatedName`, `isShared`, `isActive`, and
`containerName`.

- Required arguments: `tabIdentifier`
- Main result fields: `activeSchemeName`, `schemes`, `totalSchemes`, `truncated`, `fullSchemeListPath`
- Runtime check: in `XcodeMCPKit.xcworkspace`, the active scheme was `XcodeMCPKit-Package`, with 6 schemes total and `truncated=false`.

If multiple schemes share a name, pass the returned `disambiguatedName` to
`XcodeSwitchScheme`.

### `XcodeSwitchScheme`

Changes the active scheme and returns the post-switch active scheme and run
destination.

- Required arguments: `tabIdentifier`, `schemeName`
- Main result fields: `activeSchemeName`, `activeDestinationDisplayTitle`, `message`
- Runtime check: re-selecting the current `XcodeMCPKit-Package` scheme kept the run destination at `My Mac`.

If the previous run destination is not compatible with the new scheme, Xcode may
auto-resolve to a different destination or variant. Treat the returned
`activeDestinationDisplayTitle` as the ground truth for subsequent calls.

### `XcodeListRunDestinations`

Lists destinations available to the active scheme, grouped the same way Xcode's
destination picker groups them. Inline results are capped at 40 entries; the
complete list is written to `fullRunDestinationListPath`.

- Required arguments: `tabIdentifier`
- Optional arguments: `includeIncompatible`
- Main result fields: `activeDestinationDisplayTitle`, `activeSchemeName`, `destinations`, `groups`, `totalDestinations`, `truncated`, `fullRunDestinationListPath`
- Runtime check: for `XcodeMCPKit-Package`, the active destination was `My Mac`; the eligible destination list exceeded the inline cap and returned `truncated=true`.

Set `includeIncompatible=true` to include incompatible destinations inline, but
the same 40-entry cap still applies.

### `XcodeSwitchRunDestination`

Changes the active run destination for the active scheme. Pass a `displayTitle`
returned by `XcodeListRunDestinations`.

- Required arguments: `tabIdentifier`, `displayTitle`
- Main result fields: `activeDestinationDisplayTitle`, `activeSchemeName`, `message`
- Runtime check: re-selecting the current `My Mac` destination kept the active scheme at `XcodeMCPKit-Package`.

The tool refuses ineligible destinations and reports Xcode's ineligibility
reason.

## Run / Debug

### `RunProject`

Equivalent to pressing Xcode's Run button. It builds the active scheme, launches
the app, and returns after the app is running.

- Required arguments: `tabIdentifier`
- Optional arguments: `attachDebugger`
- Main result fields: `runResult`, `processIdentifier`, `launchSessionReference`, `elapsedTime`, `fullLogPath`, `buildErrors`

Use `attachDebugger=true` if the next step is `InvokeDebuggerCommand`. For logs,
pass `launchSessionReference` to `GetConsoleOutput`, or omit it to read the most
recent launch session.

### `StopProject`

Equivalent to pressing Xcode's Stop button. It stops the app currently running
from Xcode.

- Required arguments: `tabIdentifier`
- Main result fields: `stopResult`, `processIdentifier`

If no app is running, the tool reports that state instead of failing the MCP
transport.

### `GetConsoleOutput`

Reads stdout, stderr, and OSLog entries from a running or completed app launch
session. It supports regex filtering, severity filtering, tailing, and context
lines.

- Required arguments: `tabIdentifier`
- Optional arguments: `launchSessionReference`, `outputType`, `pattern`, `tailLimit`, `contextLines`, `oslogSeverity`, `includeMetadata`
- Main result fields: `launchSessionInfo`, `units`, `totalCount`, `truncated`

`outputType` accepts `stdio`, `oslog`, or `all`. `oslogSeverity` filters only
OSLog entries. Use `includeMetadata=true` only when needed, because it adds
subsystem, category, pid, sender, and related metadata.

### `InvokeDebuggerCommand`

Sends a command to Xcode's active LLDB session. The command runs in the same
debug session as Xcode's debug console.

- Required arguments: `tabIdentifier`, `command`
- Optional arguments: `timeout`
- Main result fields: `output`, `debugSessionActive`, `isWaitingForMore`, `processIdentifier`

The app must already be running with the debugger attached. The usual flow is
`RunProject(attachDebugger: true)` followed by commands such as `bt`,
`frame variable`, `po ...`, or `thread step-over`.

## Device Interaction

### `DeviceInteractionStartSession`

Starts a runtime verification session for an iOS device or simulator. It finds
the requested device and boots a simulator when needed.

- Required arguments: `tabIdentifier`, `sessionIdentifier`
- Optional arguments: `deviceIdentifier`
- Main result fields: `interactionSessionKey`, `deviceUUID`, `deviceIsSimulator`, `skillToTrigger`, `summary`

Device interaction sessions are relatively expensive and affect user-facing UI.
Start them only when runtime interaction is needed, and always close them with
`DeviceInteractionEndSession`.

### `DeviceInteractionInstallAndRun`

Builds, installs, and runs the current app on the device associated with a
device interaction session.

- Required arguments: `tabIdentifier`, `interactionSessionKey`
- Optional arguments: `commandLineArguments`, `environmentVariables`
- Main result fields: `userMessage`

Use this after code changes, destination changes, or debug session disconnects
when the app on the device needs to be refreshed. The `interactionSessionKey`
comes from `DeviceInteractionStartSession`.

### `DeviceInteractionSynthesize`

Synthesizes device or simulator input events, then captures the resulting
screenshot and UI hierarchy.

- Required arguments: `interactSessionKey`
- Optional arguments: `interactionCommand`
- Main result fields: `thumbnailScreenshotPath`, `screenshotPath`, `hierarchyPath`, `logsPath`, `applicationState`

Pass the `interactionSessionKey` value returned by
`DeviceInteractionStartSession` as this tool's `interactSessionKey` argument.
The field names differ in Xcode 27's tool schema.

The tool supports taps, swipes and scrolling, typing, hardware buttons,
orientation changes, and state capture. Coordinates should be derived from the
latest hierarchy dump, not guessed from screenshots alone.

### `DeviceInteractionEndSession`

Closes a session created by `DeviceInteractionStartSession`.

- Required arguments: `interactionSessionKey`
- Main result fields: `userMessage`

This is the required cleanup step for the device interaction workflow.

## Build Settings

### `GetFileCompilerFlags`

Reads the per-file compiler flags shown in Target > Build Phases > Compile
Sources > Compiler Flags.

- Required arguments: `tabIdentifier`, `targetName`, `filePath`
- Optional arguments: `projectPath`
- Main result fields: `compilerFlags`, `filePath`, `targetName`, `guidance`, `warning`
- Runtime check: in a workspace with duplicate target names, the tool reported `Target names must be unique within an Xcode project.` In that case, pass `projectPath`.

Per-file compiler flags are uncommon. For Swift files, they may not affect the
build because Swift compilation is module-oriented. Prefer target-level build
settings such as `OTHER_SWIFT_FLAGS` when they satisfy the requirement.

### `UpdateFileCompilerFlags`

Updates, appends, or deletes per-file compiler flags. This is the intended path
instead of editing `project.pbxproj` directly.

- Required arguments: `tabIdentifier`, `targetName`, `filePath`
- Optional arguments: `projectPath`, `compilerFlags`, `appendValue`
- Main result fields: `previousFlags`, `compilerFlags`, `filePath`, `targetName`, `guidance`, `warning`

Set `appendValue=true` to append to existing flags. Omit `compilerFlags` to
delete per-file flags. The descriptor strongly discourages per-file flags when a
target-level build setting would solve the problem.

## Localization

### `LocalizationPlanner`

Prepares a project and its String Catalogs so translations can be added for a
target locale.

- Required arguments: `tabIdentifier`, `targetLocaleIdentifier`
- Main result fields: `changesMade`, `nextStep`, `stepsFailed`, `suggestions`
- Runtime check: in the verifier fixture, the tool reported that 2 String Catalogs were prepared. This preparation can create file diffs in catalog files.

The tool metadata says this should be called whenever adding a language or
translating a project, after loading the translation coordinator workflow
instructions.

### `StringCatalogRead`

Summarizes translation state for a locale in a String Catalog and can return
keys from a requested state bucket.

- Required arguments: `tabIdentifier`, `filePath`, `targetLocaleIdentifier`
- Optional arguments: `requestedState`, `keyLimit`, `offset`
- Main result fields: `newCount`, `needsReviewCount`, `translatedCount`, `machineTranslatedCount`, `keys`, `nextStep`
- Runtime check: for the verifier fixture's `ja` locale, the tool reported `needsReviewCount=1`, `newCount=0`, and `translatedCount=0`.

Use this as the entry point for selecting keys to translate. Use
`StringCatalogContext` for per-key context before writing translations.

### `StringCatalogContext`

Returns the source value, usage locations, similar strings, existing
translations, and variation information for a specific String Catalog key.

- Required arguments: `tabIdentifier`, `filePath`, `stringKey`, `targetLocaleIdentifier`
- Main result fields: `sourceValues`, `usageLocations`, `similarStrings`, `translations`, `shouldTranslate`, `nextSteps`
- Runtime check: for `verifier.title`, the tool returned source value `Verifier Title` and a usage location in `VerifierCore.swift`.

Use this before drafting a translation, then pass the chosen translation to
`StringCatalogEdit`.

### `StringCatalogEdit`

Inserts a translation for a key and locale in a String Catalog.

- Required arguments: `tabIdentifier`, `filePath`, `stringKey`, `targetLocaleIdentifier`
- Optional arguments: `translation`, `stringSetTranslation`, `templateTranslation`, `variationTranslation`
- Main result fields: `success`, `message`

The tool supports simple strings, String Sets, template substitutions, and
variation translations. It is the intended alternative to manually editing the
String Catalog JSON.

## Organizer Diagnostics

### `GetTopCrashIssues`

Fetches top crash signatures from Apple's crash reporting service for the last
14 days, sorted by affected device count.

- Required arguments: `tabIdentifier`
- Optional arguments: `bundle_id`, `platform`, `app_version`, `is_beta`, `count`
- Main result fields: `success`, `message`, `bundleId`, `appVersion`, `data`
- Runtime check: the verifier fixture bundle id is not connected in Organizer, so the tool returned `success=false` with `Product not found for bundle ID...`.

If `bundle_id` and `platform` are omitted, Xcode attempts to infer them from the
active scheme and run destination. `bundle_id` is case-sensitive.

### `GetCrashIssueLogs`

Drills into a crash signature from `GetTopCrashIssues` and returns raw crash log
text plus triage guidance.

- Required arguments: `tabIdentifier`, `signature_name`
- Optional arguments: `bundle_id`, `platform`, `app_version`, `is_beta`
- Main result fields: `success`, `message`, `signatureName`, `bundleId`, `appVersion`, `data`

Use the `signature_name` from the top-crashes response. Add version or channel
filters when needed.

### `GetTopFieldPerformanceIssues`

Fetches top field performance issue signatures from Apple's field report APIs.

- Required arguments: `tabIdentifier`, `diagnostic_type`
- Optional arguments: `bundle_id`, `platform`, `app_version`, `is_beta`
- Main result fields: `success`, `message`, `diagnosticType`, `bundleId`, `appVersion`, `availableVersions`, `data`
- Supported diagnostic types: `launches`, `hangs`, `diskwrites`, `energy`
- Runtime check: `diagnostic_type=hangs` with `platform=macOS` returned `success=false` because hangs supported `iOS` but not `macOS` in that call.

Supported platforms vary by diagnostic type. Some diagnostic types, such as
`energy`, may require choosing between App Store and TestFlight data.

### `GetFieldPerformanceIssueLogs`

Drills into a signature from `GetTopFieldPerformanceIssues` and returns detailed
logs, stack traces, timeline data, and triage guidance.

- Required arguments: `tabIdentifier`, `app_version`, `signature_name`, `diagnostic_type`
- Optional arguments: `bundle_id`, `platform`, `is_beta`
- Main result fields: `success`, `message`, `signatureName`, `diagnosticType`, `bundleId`, `appVersion`, `data`

`app_version` is required. Call `GetTopFieldPerformanceIssues` first to choose a
valid version and signature.

## Practical Notes

- Most added tools require `tabIdentifier`. Start with `XcodeListWindows` to select the target workspace tab.
- `XcodeSwitchScheme` and `XcodeSwitchRunDestination` change Xcode UI state. Use list tools for inspection-only workflows.
- `RunProject`, `DeviceInteraction*`, `StringCatalogEdit`, and `UpdateFileCompilerFlags` change project, device, or file state. Prefer fixtures or scratch projects when validating them.
- Organizer diagnostics may succeed at the MCP transport level while returning structured `success=false` for product, platform, App Store Connect, or Organizer availability issues. Treat this separately from an MCP error.
- The Localization descriptors assume a translation workflow: `LocalizationPlanner` -> `StringCatalogRead` -> `StringCatalogContext` -> `StringCatalogEdit`.
