# TerminalGlass

English | [简体中文](README.zh-CN.md)

A tiny tool that gives Windows Terminal an acrylic (frosted glass) look — and can undo it precisely.

- Pure PowerShell + .NET file I/O
- No drivers, no DWM hooks, no registry writes, no admin rights
- Only touches two keys under `profiles.defaults` in `settings.json`

## What it can and cannot do

| | |
|---|---|
| ✅ Toggle the Acrylic blur on/off | Uses the official Windows Terminal setting |
| ✅ Adjust "frost strength" (window opacity 0-100) | Lower = more of what is behind shows through |
| ✅ Restore exactly what was there before | Only rolls back the keys it changed |
| ✅ Automatic backups and write-time validation | Rolls back on any mismatch |
| ❌ Change the blur radius | Fixed by Windows; not exposed by the OS |
| ❌ Liquid glass / refraction | Not provided by Windows |
| ❌ Blur a single pane | Terminal materials always apply to the whole window |

The slider controls **transparency**, not the blur radius. Visually it reads as "more or less frost", but strictly speaking it changes the background alpha.

## Requirements

- Windows 10 or 11 with [Windows Terminal](https://aka.ms/terminal) installed
- Windows PowerShell 5.1 (shipped with Windows)
- The GUI uses WPF from .NET Framework 4.8 (also shipped with Windows)

## Usage

### GUI

Double-click `Launch.cmd`.

- Toggle **Acrylic blur**
- Drag the **Frost strength** slider or use a preset (Light 90% / Medium 80% / Heavy 65% / Clear 40%)
- **Apply** — Terminal hot-reloads immediately, no restart needed
- **Reset** — return to the state before the tool was used
- The **中文 / EN** button switches the interface language; the choice is remembered

### Command line

```powershell
# Current values
.\Launch.cmd -Status

# Self-check: values, restore record, explicit-default leftovers
.\Launch.cmd -Verify

# Apply 85% opacity with acrylic
.\Launch.cmd -Apply -Opacity 85

# Apply 70% without acrylic (translucent, not blurred)
.\Launch.cmd -Apply -Opacity 70 -DisableAcrylic

# Restore
.\Launch.cmd -Reset

# Remove explicitly written default values (opacity=100 / useAcrylic=false)
.\Launch.cmd -Repair
```

Call the script directly if you prefer:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\TerminalGlass.ps1 -Apply -Opacity 85
```

### Language

The tool ships with Chinese and English. Language resolution order:

1. `-Language zh` or `-Language en` on the command line
2. The last choice made with the **中文 / EN** button (stored in `prefs.json`)
3. The Windows display language (`zh*` → Chinese, anything else → English)

```powershell
.\Launch.cmd -Status -Language en
.\Launch.cmd -Apply -Opacity 80 -Language zh
```

## What "restore" means

On the first **Apply**, the tool records the previous values of `opacity` and `useAcrylic` — including the case where they did not exist at all — in:

```
%LOCALAPPDATA%\TerminalGlass\state.json
```

**Reset** puts those values back; keys that did not exist are removed. So:

- Fonts, color schemes, tabs, keybindings and everything else you configured are untouched
- If you had `opacity: 100` before using the tool, it stays `100`
- If the keys did not exist, they disappear and Terminal falls back to its built-in defaults
- If the whole `profiles.defaults` block did not exist, an empty `"defaults": {}` remains afterwards (behaviorally identical to absent)

A full snapshot is written to `%LOCALAPPDATA%\TerminalGlass\backups\` before every write (the last 20 are kept).

## Safety

- The whole file is re-parsed and validated before any write; invalid output is never written
- Writes use a temp file plus replace, so a partial write cannot happen
- Only the `profiles.defaults` block is rewritten; the rest of the file is preserved byte-for-byte
- Comments **inside** `profiles.defaults` are normalized away when the block is rewritten (comments elsewhere are kept)
- A legacy array-style `profiles`, or a `defaults` that is not an object, produces a clear error instead of a risky edit
- Two instances writing at once are serialized with a system mutex
- A corrupted `state.json` is renamed aside instead of breaking restore
- Restore only accepts the two known keys and validates their ranges
- If the settings path in the restore record does not match the target, the tool refuses to act
- **After every write the file is read back and compared**; on any mismatch the snapshot is restored automatically

## Troubleshooting

If nothing changes after applying:

1. **Settings → Personalization → Colors → Transparency effects** must be ON
2. Battery saver / energy saver turns transparency off
3. `opacity` must be below 100
4. The window must be Windows Terminal itself, not the legacy console host
5. If Terminal is not running, the setting applies on next launch

## Files

```
TerminalGlass.ps1   main program (GUI + CLI)
Launch.cmd          launcher
%LOCALAPPDATA%\TerminalGlass\prefs.json      language preference
%LOCALAPPDATA%\TerminalGlass\state.json      restore record
%LOCALAPPDATA%\TerminalGlass\backups\        snapshots taken before each write
```

## Manual recovery

If `state.json` is lost:

```powershell
copy "$env:LOCALAPPDATA\TerminalGlass\backups\settings-<timestamp>.json" `
     "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
```

## License

MIT — see [LICENSE](LICENSE).
