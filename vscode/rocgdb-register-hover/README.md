## rocgdb Register Hover (VS Code extension)

This is a small VS Code extension that shows AMDGPU SGPR/VGPR values when hovering registers in `.s/.S` files while stopped in `rocgdb`.

### Key features
- Hover `s55`, `s[54:55]`, `v17`
- Hover symbolic registers like `s[sgprStreamKIter]` by resolving `.set/.equ` definitions in the current assembly file
- Works with **active `cppdbg`** rocgdb sessions (recommended), or with a spawned `rocgdb` MI process

### Install (dev)
- Open this folder in VS Code
- Press `F5` to launch an Extension Development Host

### Install (manual copy)
For VS Code Remote (SSH/containers), you can copy/symlink this folder into the remote extensions directory and reload the window:
- Typical remote dir: `~/.vscode-server/extensions/`

### Settings
See `package.json` for all `rocgdbHover.*` settings.

### Notes
- VGPR values are read via `info registers vXX` and may return a 64-lane vector depending on your rocgdb build.
<img width="1086" height="270" alt="image" src="https://github.com/user-attachments/assets/b81d807d-30fa-440e-97d9-2ffc5c99655c" />
