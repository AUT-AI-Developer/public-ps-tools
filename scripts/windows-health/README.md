# Windows Health Repair Scripts

This folder contains Windows PowerShell 5.1-compatible operational scripts for Windows component store and system file health checks.

## Scripts

| Script | Purpose |
|---|---|
| `Invoke-DismCheckHealth.ps1` | Runs `DISM /Online /Cleanup-Image /CheckHealth` and reports whether further DISM work is needed. |
| `Invoke-DismScanHealth.ps1` | Runs `DISM /Online /Cleanup-Image /ScanHealth` and reports whether `RestoreHealth` is needed. |
| `Invoke-DismRestoreHealth.ps1` | Runs `DISM /Online /Cleanup-Image /RestoreHealth` and recommends SFC verification after repair. |
| `Invoke-SfcScan.ps1` | Runs `sfc.exe /scannow` and reports whether corruption was found, repaired, or unresolved. |
| `Invoke-WindowsImageHealthRepair.ps1` | Runs the complete conditional workflow and consolidates child results. |

## Recommended execution model

Use `Invoke-WindowsImageHealthRepair.ps1` as the normal RMM entry point. The child scripts remain independently runnable for diagnostics, staged remediation, or troubleshooting.

The orchestrator runs the following decision sequence:

1. Validate the operating system and administrative elevation.
2. Run `Invoke-DismCheckHealth.ps1`.
3. If CheckHealth reports no component-store corruption, skip ScanHealth and RestoreHealth and continue to SFC.
4. If CheckHealth reports a repairable component store, run `Invoke-DismScanHealth.ps1`.
5. If ScanHealth reports no component-store corruption, skip RestoreHealth and continue to SFC.
6. If ScanHealth reports repairable corruption, run `Invoke-DismRestoreHealth.ps1`.
7. If any DISM stage reports a non-repairable condition or execution failure, stop the workflow and return failure with that stage's recommended action.
8. Run `Invoke-SfcScan.ps1` as final system-file verification after the applicable DISM path.
9. Return success/no-action, changed, partial success, or failure based primarily on the final SFC result plus whether any child operation changed state.

SFC returning unresolved corruption produces `PartialSuccess`, exit code `4`, and normally recommends another DISM RestoreHealth cycle or operator review. A successful SFC result produces exit code `0`; if any child repaired state, the orchestrator reports `Changed`, otherwise `NoActionNeeded`.

## Failure diagnostic capture

`Invoke-DismCheckHealth.ps1` automatically collects servicing diagnostics when CheckHealth reports that the component store cannot be repaired, when DISM returns a nonzero native exit code, or when the script cannot classify otherwise-successful DISM output.

`Invoke-DismRestoreHealth.ps1` performs the same collection when RestoreHealth fails or its output cannot be classified as successful.

Diagnostic files are written into the same directory as that script's log file. With default logging, they therefore appear under `C:\Temp`. The structured child result exposes the collected paths under `Data.DiagnosticArtifacts`.

The bounded diagnostic set includes:

- the last 100 lines of `%WINDIR%\Logs\CBS\CBS.log`;
- the last 100 lines of `%WINDIR%\Logs\DISM\dism.log`;
- a filtered excerpt from the last 2000 CBS lines matching `Error`, `CORRUPT`, `MISSING`, or `HRESULT`;
- a timestamped copy of `%WINDIR%\servicing\Sessions\Sessions.xml` when present;
- up to 100 Critical, Error, or Warning events from each available relevant servicing/Windows Update event source, starting five minutes before the current DISM operation:
  - `Microsoft-Windows-Servicing/Operational`;
  - `System` events from provider `Microsoft-Windows-Servicing`;
  - `Microsoft-Windows-WindowsUpdateClient/Operational`;
  - `System` events from provider `Microsoft-Windows-WindowsUpdateClient`.

Diagnostic collection is best-effort. Failure to read an optional event channel or servicing artifact is logged as a warning and does not replace the original DISM failure result.

## Automation contract

Each script supports:

```powershell
-OutputFormat Object|Json|None
-LogPath <path>
-ResultPath <path>
-Quiet
```

`-Quiet` is accepted by all five RMM-facing scripts. The package does not emit progress chatter to the success stream; quiet operation therefore preserves the same structured result, result-file, log, and exit-code behavior while remaining compatible with unattended RMM execution.

Default log path pattern:

```text
C:\Temp\<ScriptName>-<Timestamp>.log
```

Native DISM/SFC command output is written under a `scan-results` subfolder beside the log file directory. With the default log path, this is:

```text
C:\Temp\scan-results\
```

Use the JSON result file for control flow. Use the log file, native scan result, and any `Data.DiagnosticArtifacts` files for diagnostics. Do not parse human-readable log text for automation decisions.

## 64-bit PowerShell behavior

The orchestrator and all four child scripts require a 64-bit PowerShell process for DISM and SFC work. If a 32-bit PowerShell process launches a script on a 64-bit Windows OS, the script attempts to relaunch itself through `Sysnative\WindowsPowerShell\v1.0\powershell.exe` and exits with the relaunched process exit code.

For in-memory launches, the relay writes the exact currently executing script text to a temporary local file and executes that file in 64-bit Windows PowerShell. It does not download another copy of the script from a moving branch during relay.

The structured result `Data` object includes `Is64BitProcess` so RMM output can confirm the effective process architecture.

## Supported operating systems

The scripts are intended for Windows client and Windows Server repair automation.

The orchestrator validates that it can read `Win32_OperatingSystem` and that `ProductType` is `1` (workstation), `2` (domain controller), or `3` (server). Unsupported or undetectable systems return `ValidationFailed`, exit code `2`, and `RecommendedAction` `RunOnSupportedWindows`.

## Reproducible production source mode

The orchestrator supports:

```powershell
-ChildScriptBaseUrl <raw GitHub package URL>
-ForceDownload
-RequirePinnedSource
```

For production RMM automation, use `-RequirePinnedSource` with a `ChildScriptBaseUrl` containing an exact 40-character Git commit SHA. When `-RequirePinnedSource` is enabled:

- the orchestrator rejects moving references such as `main`;
- the child URL must match the raw GitHub `.../<40-character-commit>/scripts/windows-health` form;
- existing cached child scripts are refreshed automatically;
- all four children are therefore retrieved from the same immutable commit reference for that run.

Example production pattern:

```powershell
$Commit = '<40-character-public-ps-tools-commit-sha>'
$Base = "https://raw.githubusercontent.com/AUT-AI-Developer/public-ps-tools/$Commit/scripts/windows-health"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-WindowsImageHealthRepair.ps1 `
    -ChildScriptBaseUrl $Base `
    -RequirePinnedSource `
    -Quiet `
    -OutputFormat None `
    -ResultPath 'C:\Temp\Invoke-WindowsImageHealthRepair-result.json'
```

The default public `main` URL remains available for development and controlled testing, but it is intentionally rejected when `-RequirePinnedSource` is requested.

## Autonomous orchestrator execution

`Invoke-WindowsImageHealthRepair.ps1` downloads child scripts into `C:\Temp\AUT-WindowsHealth` by default, executes those local copies, and writes one consolidated result.

Development/direct GitHub launch:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ScriptText = (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/AUT-AI-Developer/public-ps-tools/main/scripts/windows-health/Invoke-WindowsImageHealthRepair.ps1'); & ([scriptblock]::Create($ScriptText)) -Quiet"
```

For production, download the orchestrator from a pinned public commit and pass the matching pinned child base URL with `-RequirePinnedSource`.

## Result fields

Each script returns or writes a structured result with these fields:

- `ScriptName`
- `Operation`
- `Status`
- `ExitCode`
- `Changed`
- `Message`
- `LogPath`
- `ResultPath`
- `RecommendedAction`
- `Data`
- `Errors`

Recommended status values include `Success`, `NoActionNeeded`, `Changed`, `PartialSuccess`, `ValidationFailed`, `DependencyMissing`, and `Failed`.

## Validation

The corresponding authoritative toolkit package was validated under Windows PowerShell 5.1 with Pester 3.4 before this public distribution sync. This public folder intentionally contains only the operational scripts and README; test, schema, task, and governance files are not distributed here.

Live Local System/RMM and Windows Server execution remain separate operational validation requirements.
