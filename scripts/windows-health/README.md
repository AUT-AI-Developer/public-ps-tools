# Windows Health Repair Scripts

Public runtime distribution of the Windows PowerShell 5.1-compatible Windows component-store and protected system-file health package.

## Scripts

| Script | Purpose |
|---|---|
| `Invoke-DismCheckHealth.ps1` | Runs `DISM /Online /Cleanup-Image /CheckHealth`. |
| `Invoke-DismScanHealth.ps1` | Runs `DISM /Online /Cleanup-Image /ScanHealth`. |
| `Invoke-DismRestoreHealth.ps1` | Runs `DISM /Online /Cleanup-Image /RestoreHealth`. |
| `Invoke-SfcScan.ps1` | Runs `sfc.exe /scannow`. |
| `Invoke-WindowsImageHealthRepair.ps1` | Runs the complete conditional workflow and consolidates child results. |

The public repository contains the runtime distribution only. Regression tests, task tracking, standards, and project governance remain in the private `AUT-AI-Developer/aut-powershell-toolkit` source repository.

## Recommended execution model

Use `Invoke-WindowsImageHealthRepair.ps1` as the normal RMM entry point. The orchestrator validates Windows client/server support and elevation, downloads the child scripts, and runs the minimum required sequence:

1. DISM CheckHealth.
2. If CheckHealth reports no component-store corruption, skip ScanHealth and RestoreHealth and run SFC.
3. If CheckHealth reports repairable corruption, run ScanHealth.
4. If ScanHealth reports repairable corruption, run RestoreHealth; otherwise skip RestoreHealth.
5. Stop immediately on a non-repairable DISM state or execution failure.
6. Run SFC as final protected-system-file verification after a successful DISM path.

## Consolidated logging and artifacts

An orchestrated run uses one detailed chronological log. The orchestrator passes the same `-LogPath` to every child process.

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

Child-result JSON used for out-of-process orchestration remains under the working directory (`C:\Temp\AUT-WindowsHealth` by default). The RMM-facing consolidated JSON remains under `C:\Temp\Logs\results`.

The operational log uses `Debug`, `Information`, `Warning`, `Error`, and `Critical` levels. Raw DISM/SFC progress output is intentionally kept separate from the main log.

## SFC output parsing

SFC output can contain character spacing and embedded NUL characters depending on host/redirection encoding. The parser removes NUL characters and normalizes whitespace for classification while preserving the raw native output file unchanged.

Native output reads use terminating error handling. Missing or unreadable native output is reported explicitly in the structured result instead of being silently treated as an unknown parser state.

## Failure diagnostic capture

`Invoke-DismCheckHealth.ps1` captures bounded servicing diagnostics for non-repairable, native-failure, native-output-read, and unclassified states.

`Invoke-DismRestoreHealth.ps1` captures the same class of evidence for RestoreHealth failure, output-read failure, or unclassified completion.

The bounded evidence includes CBS/DISM tails, filtered CBS corruption/error lines, `Sessions.xml` when present, and recent Critical/Error/Warning events from relevant Servicing and WindowsUpdateClient logs.

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

The default child source is:

```text
https://raw.githubusercontent.com/AUT-AI-Developer/public-ps-tools/main/scripts/windows-health
```

For production RMM use, prefer an immutable public commit URL:

```powershell
$Commit = '<40-character-public-commit-sha>'
$Base = "https://raw.githubusercontent.com/AUT-AI-Developer/public-ps-tools/$Commit/scripts/windows-health"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-WindowsImageHealthRepair.ps1 `
    -ChildScriptBaseUrl $Base `
    -RequirePinnedSource `
    -Quiet `
    -OutputFormat None
```

Pinned mode rejects moving references such as `main` and refreshes all child scripts from the same immutable commit.

## PowerShell engineering contract

All five scripts:

- declare `#Requires -Version 5.1`;
- use `[CmdletBinding(PositionalBinding = $false)]`;
- use `Set-StrictMode -Version 2.0`;
- use targeted `-ErrorAction Stop` where failures must be caught rather than a universal global stop preference;
- use `-LiteralPath` for concrete filesystem paths where supported;
- keep process `exit` at script scope after result publication;
- invoke DISM/SFC directly and capture `$LASTEXITCODE` immediately;
- provide complete comment-based help suitable for reusable RMM scripts.

The orchestrator invokes child Windows PowerShell directly with a discrete argument array and immediately captures `$LASTEXITCODE`. `Start-Process` remains only in the 32-bit-to-64-bit relay, where separate-process lifecycle, hidden-window behavior, and exit-code propagation are intentional.

## Intentional design decisions

Windows PowerShell 5.1 remains the target because broad RMM and Windows Server compatibility is an explicit requirement.

Runtime child acquisition is deliberate for single-entry RMM execution. Production reproducibility is provided through `-RequirePinnedSource`.

The package does not expose a superficial `-WhatIf` wrapper. Simply skipping `DISM /RestoreHealth` or `sfc /scannow` would not truthfully simulate the repair workflow. A future dry-run capability should be implemented as a real assessment mode rather than misleading `WhatIf` behavior.

## 64-bit behavior

All five scripts require a 64-bit PowerShell process for DISM/SFC work. If launched from 32-bit PowerShell on 64-bit Windows, the exact currently executing script text is relaunched through `Sysnative\WindowsPowerShell\v1.0\powershell.exe`.

## Supported operating systems

The orchestrator accepts `Win32_OperatingSystem.ProductType` values `1` (workstation), `2` (domain controller), and `3` (server).

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

Use structured JSON/results for automation control flow and the consolidated log/raw artifacts for troubleshooting.

## Validation status

The current runtime files are synchronized from P-023 in the private toolkit. A prior Windows PowerShell 5.1/Pester 3.4 suite passed 15/15 before the latest compliance refactor. The expanded post-refactor suite, PSScriptAnalyzer review, Windows 11 rerun, Windows Server validation, and RMM Local System validation are still required before production acceptance.
