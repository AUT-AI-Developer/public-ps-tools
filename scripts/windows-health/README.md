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

## SFC output parsing

SFC output can contain character spacing and/or embedded NUL characters depending on host/redirection encoding. The parser removes NUL characters and normalizes whitespace before classifying the final Windows Resource Protection status. Raw native output remains unchanged for troubleshooting.

## Failure diagnostic capture

`Invoke-DismCheckHealth.ps1` captures servicing diagnostics when CheckHealth reports that the component store cannot be repaired, when DISM returns a nonzero native exit code, or when otherwise-successful output cannot be classified.

`Invoke-DismRestoreHealth.ps1` performs the same capture when RestoreHealth fails or cannot be classified as successful.

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

Default public child source:

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

## 64-bit behavior

All five scripts require a 64-bit PowerShell process for DISM/SFC work. If launched from 32-bit PowerShell on 64-bit Windows, the script relaunches the exact currently executing script text through `Sysnative\WindowsPowerShell\v1.0\powershell.exe` and exits with the relaunched process exit code.

## Supported operating systems

The orchestrator accepts `Win32_OperatingSystem.ProductType` values `1` (workstation), `2` (domain controller), and `3` (server). Unsupported or undetectable systems return `ValidationFailed`, exit code `2`, and `RecommendedAction` `RunOnSupportedWindows`.

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
