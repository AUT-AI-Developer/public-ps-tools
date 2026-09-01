# Windows Health Repair Scripts

Windows PowerShell 5.1-compatible operational scripts for Windows component-store and protected system-file health checks.

## Scripts

| Script | Purpose |
|---|---|
| `Invoke-DismCheckHealth.ps1` | Runs `DISM /Online /Cleanup-Image /CheckHealth`. |
| `Invoke-DismScanHealth.ps1` | Runs `DISM /Online /Cleanup-Image /ScanHealth`. |
| `Invoke-DismRestoreHealth.ps1` | Runs `DISM /Online /Cleanup-Image /RestoreHealth`. |
| `Invoke-SfcScan.ps1` | Runs `sfc.exe /scannow`. |
| `Invoke-WindowsImageHealthRepair.ps1` | Runs the complete conditional workflow and consolidates child results. |

## Recommended execution model

Use `Invoke-WindowsImageHealthRepair.ps1` as the normal RMM entry point. The orchestrator validates Windows client/server support and elevation, downloads the child scripts, and runs the minimum required sequence:

1. DISM CheckHealth.
2. If CheckHealth reports no component-store corruption, skip ScanHealth and RestoreHealth and run SFC.
3. If CheckHealth reports repairable corruption, run ScanHealth.
4. If ScanHealth reports repairable corruption, run RestoreHealth; otherwise skip RestoreHealth.
5. Stop immediately on a non-repairable DISM state or execution failure.
6. Run SFC as final protected-system-file verification after a successful DISM path.

## Consolidated logging and artifacts

An orchestrated run uses one detailed chronological log. The orchestrator passes the same `-LogPath` to every child process, so child operations append to the same file rather than creating multiple small logs.

Default durable artifact root:

```text
C:\Temp\Logs\
```

Default layout:

```text
C:\Temp\Logs\
├── WindowsImageHealthRepair-<timestamp>.log
├── results\
│   └── WindowsImageHealthRepair-<timestamp>.json
├── scan-results\
│   ├── DismCheckHealth-<timestamp>.txt
│   ├── DismScanHealth-<timestamp>.txt
│   ├── DismRestoreHealth-<timestamp>.txt
│   └── SfcScan-<timestamp>.txt
└── diagnostics\
    ├── *-CBS-tail.txt
    ├── *-CBS-errors.txt
    ├── *-DISM-tail.txt
    ├── *-Sessions.xml
    └── *-events.txt
```

The consolidated log records execution context, OS/build/ProductType, elevation, child download/cache decisions, operation starts, native exit codes, parsed status, skip/continue decisions, artifact paths, diagnostic collection, and the final structured outcome. Raw DISM/SFC progress output is intentionally kept out of the central log and preserved under `scan-results` instead.

Child result JSON files used for out-of-process orchestration are internal IPC artifacts stored under the working directory (`C:\Temp\AUT-WindowsHealth` by default). The RMM-facing consolidated JSON result is stored under `C:\Temp\Logs\results` by default.

When a child script is run independently, it creates its own standalone log and result JSON under the same central artifact root.

## Logging levels

The scripts use the toolkit's stable levels:

- `Debug`
- `Information`
- `Warning`
- `Error`
- `Critical`

Routine decision flow is logged at `Information`, detailed paths/exit codes and execution context at `Debug`, best-effort diagnostic collection problems at `Warning`, recoverable operation failures at `Error`, and final unrecoverable/non-zero outcomes at `Critical` where appropriate.

## SFC output parsing

SFC output can contain character spacing and/or embedded NUL characters depending on host/redirection encoding. The parser normalizes embedded NUL characters and whitespace before classifying the final Windows Resource Protection status. This covers output such as character-spaced or UTF-16-style text while preserving the raw native output file unchanged.

Native output reads use terminating error handling. If the raw DISM/SFC file cannot be read, the structured result reports that failure rather than silently converting it into an unknown parse result.

## Failure diagnostic capture

`Invoke-DismCheckHealth.ps1` captures servicing diagnostics when CheckHealth reports that the component store cannot be repaired, when DISM returns a nonzero native exit code, when native output cannot be read, or when otherwise-successful output cannot be classified.

`Invoke-DismRestoreHealth.ps1` performs the same capture when RestoreHealth fails, its native output cannot be read, or the successful native result cannot be classified.

Diagnostics are best-effort and written below `C:\Temp\Logs\diagnostics` by default. The structured child result exposes collected paths under `Data.DiagnosticArtifacts`.

The bounded set includes the last 100 lines of CBS and DISM logs, a filtered CBS excerpt from the last 2000 lines matching `Error`, `CORRUPT`, `MISSING`, or `HRESULT`, `Sessions.xml` when present, and up to 100 Critical/Error/Warning events from relevant Servicing and WindowsUpdateClient channels beginning five minutes before the DISM operation.

## Automation contract

Each script supports:

```powershell
-OutputFormat Object|Json|None
-LogPath <path>
-ResultPath <path>
-Quiet
```

The orchestrator additionally supports:

```powershell
-WorkingDirectory <path>
-ChildScriptBaseUrl <raw GitHub package URL>
-ForceDownload
-RequirePinnedSource
```

The default public child source is:

```text
https://raw.githubusercontent.com/AUT-AI-Developer/public-ps-tools/main/scripts/windows-health
```

For production RMM automation, prefer an immutable public commit URL and `-RequirePinnedSource`:

```powershell
$Commit = '<40-character-public-commit-sha>'
$Base = "https://raw.githubusercontent.com/AUT-AI-Developer/public-ps-tools/$Commit/scripts/windows-health"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-WindowsImageHealthRepair.ps1 `
    -ChildScriptBaseUrl $Base `
    -RequirePinnedSource `
    -Quiet `
    -OutputFormat None
```

Pinned mode rejects moving references such as `main` and refreshes cached child scripts so all four children come from the same immutable commit.

## PowerShell engineering contract

All five scripts:

- declare `#Requires -Version 5.1`;
- use `[CmdletBinding(PositionalBinding = $false)]`;
- use `Set-StrictMode -Version 2.0`;
- use targeted `-ErrorAction Stop` where a cmdlet failure must be handled by `catch` rather than setting a universal global `$ErrorActionPreference`;
- use `-LiteralPath` for concrete filesystem paths where supported;
- keep helper functions from calling `exit`; process termination occurs at script scope after result publication;
- invoke DISM/SFC directly and capture `$LASTEXITCODE` immediately;
- invoke child Windows PowerShell directly with a discrete argument array and capture `$LASTEXITCODE` immediately;
- provide comment-based help with parameter, output, example, compatibility, and operational information.

The 32-bit-to-64-bit relay continues to use `Start-Process` deliberately because the relay requires separate-process lifecycle control, hidden-window behavior, and exit-code propagation.

## Intentional project-specific exceptions

### Windows PowerShell 5.1

The Project Framework PowerShell skill defaults unconstrained new work to current PowerShell LTS, but allows Windows PowerShell 5.1 when the target environment requires it. This package intentionally targets Windows PowerShell 5.1 for broad RMM and Windows Server compatibility.

### Runtime child acquisition

The orchestrator intentionally supports downloading child scripts from the approved public repository because single-entry execution is materially useful for RMM deployment. Production reproducibility is provided through `-RequirePinnedSource`, which requires a 40-character commit SHA and refreshes all children from the same immutable source.

### No superficial WhatIf mode

The repair workflow does not expose a superficial `SupportsShouldProcess`/`-WhatIf` wrapper. `DISM /RestoreHealth` and `sfc /scannow` are state-changing operations, but simply skipping those commands would not truthfully simulate the workflow or its later decisions. If a dry-run capability is required later, implement a separate assessment mode with commands whose behavior genuinely represents read-only assessment rather than a misleading `WhatIf` facade.

## 64-bit behavior

All five scripts require a 64-bit PowerShell process for DISM/SFC work. If launched from 32-bit PowerShell on 64-bit Windows, the script relaunches the exact currently executing script text through `Sysnative\WindowsPowerShell\v1.0\powershell.exe` and exits with the relaunched process exit code.

## Supported operating systems

The orchestrator accepts `Win32_OperatingSystem.ProductType` values `1` (workstation), `2` (domain controller), and `3` (server). Unsupported or undetectable systems return `ValidationFailed`, exit code `2`, and `RecommendedAction` `RunOnSupportedWindows`.

The consolidated result projects operating-system information to the compact fields `Caption`, `Version`, `BuildNumber`, `ProductType`, and `OSArchitecture`; the raw CIM/WMI instance is not serialized into RMM-facing JSON.

## Structured result

Each script preserves these fields:

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

Use JSON/result objects for automation control flow. Use the consolidated log, raw native output, and failure diagnostic artifacts for troubleshooting.

## Validation

Regression coverage is maintained in `tests/windows-health.Tests.ps1` in the private toolkit repository. The Windows PowerShell 5.1 / Pester suite covers parser validity, result contracts, central artifact layout, shared child logging, PowerShell skill compliance contracts, native-output whitespace/NUL normalization, OS ProductType handling, compact OS result projection, pinned-source enforcement, diagnostic capture, and workflow ordering.

Maintainer-supplied Windows PowerShell 5.1/Pester validation on 2026-09-01 passed the current P-023 integration suite with **25 passed and 0 failed**.

Live validation has also passed on Windows 11 and Windows Server 2019 Standard. The Server 2019 run executed as `NT AUTHORITY\SYSTEM`, detected `ProductType=2`, used 64-bit Windows PowerShell, correctly skipped ScanHealth/RestoreHealth after a clean CheckHealth result, successfully parsed real embedded-NUL SFC output, and returned `NoActionNeeded` with exit code `0`. The compact operating-system result payload was verified in the generated JSON.

Remaining validation requirements are PSScriptAnalyzer review when available and validation of the actual public/RMM acquisition path, including an immutable commit-pinned child-script run with `-RequirePinnedSource`.
