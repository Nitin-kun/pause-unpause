# pause-unpause

When a lecture plays, your type beat pauses. When you pause the lecture to take notes, the beat comes back.

Open source. MIT licensed. One-command installer.

Works on **Windows**, **Linux**, and **Mac**.

## Windows

In PowerShell:

```powershell
irm https://raw.githubusercontent.com/Nitin-kun/pause-unpause/main/install.ps1 | iex
```

That command:

1. Downloads the extension into `%LOCALAPPDATA%\pause-unpause\extension`
2. Turns on Chrome Developer mode when it can
3. Adds `--load-extension` to your Chrome / Edge shortcuts so it stays loaded
4. Restarts the browser with pause-unpause already on

Chrome will not let a script click **Load unpacked** for you. Closing and relaunching with `--load-extension` is the way a one-liner can put it on the browser you already use.

If you already cloned this repo:

```powershell
.\install.ps1
```

Uninstall (restores Chrome shortcuts):

```powershell
.\install.ps1 -Uninstall
```

Install files only, do not open the browser:

```powershell
.\install.ps1 -NoLaunch
```

## Linux

```bash
curl -fsSL https://raw.githubusercontent.com/Nitin-kun/pause-unpause/main/install.sh | bash
```

Then:

```bash
pause-unpause
```

Same command works in WSL. If you already cloned this repo:

```bash
./install.sh
```

Uninstall:

```bash
./install.sh --uninstall
```

The script downloads the files and opens a Chrome window that already has pause-unpause loaded. Use that window, or load the printed folder unpacked in the Chrome you already use:

1. Open `chrome://extensions`
2. Turn on **Developer mode**
3. **Load unpacked**
4. Pick the folder the script printed (`~/.local/share/pause-unpause/extension`)

## Mac

```bash
curl -fsSL https://raw.githubusercontent.com/Nitin-kun/pause-unpause/main/install.sh | bash
```

Then:

```bash
pause-unpause
```

If you already cloned this repo:

```bash
./install.sh
```

Uninstall:

```bash
./install.sh --uninstall
```

## How to use it

1. Press play once on your type beat tab
2. Click the extension icon → **Use this tab** under Type beat
3. Switch to the lecture tab → **Use this tab** under Lecture
4. Leave **Keep them in sync** on

Works on YouTube and most sites with a normal video/audio player.

Chrome and Edge pages (`chrome://`, `edge://`, the Web Store) cannot be assigned.

## Manual setup (no script)

1. Clone this repo
2. Open `chrome://extensions`
3. Enable Developer mode
4. Load unpacked → `browser-extension/unpause`

## What's in the repo

- MIT license
- `install.sh` / `install.ps1` at the **repo root** (this is what the `irm` / `curl` one-liners download)
- Extension sources in `browser-extension/unpause`

## Support

If this helps your study sessions, you can [buy me a coffee](https://buymeacoffee.com/nitin_kun).

## License

MIT. See [LICENSE](LICENSE).
