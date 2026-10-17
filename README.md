# wsl2-vbs-off

Turn off Virtualization-Based Security (VBS) and Memory Integrity (HVCI) on Windows 11 **while keeping WSL2 working** — in one double-click.

On recent Windows 11 builds, simply enabling a hypervisor-based feature such as WSL2 also brings up VBS, and with it the overhead of running Windows on top of a secure kernel. The usual advice — `bcdedit /set hypervisorlaunchtype off` or turning off virtualization (SVM / VT-x) in the BIOS — removes that overhead but also breaks WSL2, Docker Desktop and other hypervisor-based tools.

This script takes the middle path:

| | Stock Windows 11 | `hypervisorlaunchtype off` / SVM off | **wsl2-vbs-off** |
|---|---|---|---|
| Hypervisor | Running | Off | **Running** |
| WSL2 / Docker Desktop | Works | Broken | **Works** |
| VBS (secure kernel) | Running | Off | **Off** |
| Memory Integrity (HVCI) | Depends on device | Off | **Off** |

## Usage

1. Download this repository (**Code → Download ZIP**) and extract it.
2. Double-click **`Apply.cmd`** and accept the UAC prompt. Restart when asked.
3. After the restart, double-click **`Verify.cmd`**. Every row should read `OK`.

To revert, double-click **`Undo.cmd`** and restart.

If Windows blocks the files, right-click the ZIP → **Properties** → check **Unblock** before extracting.

> The console output of the script is in Japanese.

### Command-line options

```powershell
powershell -ExecutionPolicy Bypass -File .\GamingVBS.ps1 -Mode Apply    # default
powershell -ExecutionPolicy Bypass -File .\GamingVBS.ps1 -Mode Verify
powershell -ExecutionPolicy Bypass -File .\GamingVBS.ps1 -Mode Undo
powershell -ExecutionPolicy Bypass -File .\GamingVBS.ps1 -SkipVMP      # don't enable Virtual Machine Platform
```

Use `-SkipVMP` on machines that don't need WSL2.

## What it changes

All values live under `HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard`.

| Setting | Value | Why |
|---|---|---|
| `EnableVirtualizationBasedSecurity` | `0` | Don't request VBS |
| `HyperVVirtualizationBasedSecurityOptout` | `1` | **Key setting.** Without it, Windows turns VBS on automatically whenever the hypervisor starts |
| `Scenarios\WindowsHello\Enabled` | `0` | Since 24H2, Windows Hello's VBS protection can start VBS on its own |
| `Scenarios\HypervisorEnforcedCodeIntegrity\Enabled` | `0` | Memory Integrity (HVCI) |
| `Scenarios\KernelShadowStacks\Enabled` | `0` | Depends on HVCI |
| `Scenarios\CredentialGuard\Enabled` | `0` | Only if the key exists |
| `HKLM\...\Control\Lsa\LsaCfgFlags` | `0` | Only if the value exists (Credential Guard) |

It also:

- sets `bcdedit /set {current} hypervisorlaunchtype auto` so the hypervisor still starts, and
- enables the **Virtual Machine Platform** optional feature if it is off (skipped with `-SkipVMP`).

Before changing anything, `Apply` saves the original state to `C:\ProgramData\GamingVBS\Backup` (a `.reg` export of the DeviceGuard key, a BCD export, and a JSON file). `Undo` restores from there.

## How to tell it worked

Windows logs why VBS was or wasn't started on each boot (System log, `Microsoft-Windows-Kernel-Boot`, event ID 153). `Verify` shows the latest entry. After applying, it should read:

```
Virtualization-based security (policies: 0) is disabled due to HyperV opt-out.
```

If you instead see `enabled due to HyperV`, the opt-out isn't taking effect; if you see `enabled due to VBS registry configuration`, some other scenario key is still requesting VBS.

You can also check manually:

```powershell
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent   # True  -> WSL2 works
(Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard).VirtualizationBasedSecurityStatus   # 0 -> VBS off
```

`msinfo32` should show **Virtualization-based security: Not enabled** while still listing **A hypervisor has been detected**.

## Performance

How much you gain depends heavily on the CPU, the game and whether HVCI was on:

- Most of the measured gaming cost comes from **HVCI**, not from the hypervisor itself. Tom's Hardware measured an average 5–6% (up to ~10%) gain across 15 games on an RTX 4090 with VBS off.
- CPUs older than Intel Kaby Lake / AMD Zen 2 lack MBEC/GMET and emulate it, so they are hit harder.
- With VBS off, a hypervisor that is merely running has little measurable effect on games; differences, if any, tend to show up in 1% lows rather than average FPS.

Benchmark your own games before and after rather than relying on these numbers.

## Caveats

- **This weakens Windows security.** VBS isolates credentials and protects the kernel's code integrity. Use it on a personal gaming / development machine, not on a work or shared PC.
- It does **not** work when VBS, HVCI or Credential Guard is enforced by Group Policy, MDM or a UEFI lock (common on managed corporate PCs and some Secured-core PCs). `Apply` warns when it detects a policy or lock.
- Feature updates and some quality updates may reset these values. Starting in October 2026, Microsoft is also rolling out Memory Integrity by default to eligible devices. Run `Verify.cmd` after major updates.
- Windows Hello (PIN, face, fingerprint) keeps working, but its credentials are no longer isolated by VBS.

## Tested on

- Windows 11 Home Insider Preview, build 26340 (26H2, Experimental channel)
- AMD Ryzen 7 9850X3D, ASRock B650M

Registry behavior around VBS has changed between Windows releases, so results on other builds may differ. Reports are welcome.

## References

- [Microsoft Learn — Enable virtualization-based protection of code integrity](https://learn.microsoft.com/en-us/windows/security/hardware-security/enable-virtualization-based-protection-of-code-integrity)
- [Microsoft Q&A — VBS is not disabled on Windows 11 24H2 (Windows Hello scenario)](https://learn.microsoft.com/en-us/answers/questions/2113711/vbs-is-not-disabled-on-windows-11-version-24h2-os)
- [Tom's Hardware — Windows 11 VBS/HVCI gaming benchmarks](https://www.tomshardware.com/news/windows-11-gaming-benchmarks-performance-vbs-hvci-security)

## Disclaimer

Provided as is, without warranty. You are responsible for any changes made to your system.
