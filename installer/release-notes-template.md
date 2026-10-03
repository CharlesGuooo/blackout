## Install

- **`Blackout-{{VERSION}}-Setup.exe`** — installs for your user only. No admin rights, no UAC prompt.
- **`Blackout-{{VERSION}}-portable.zip`** — unzip and run it from anywhere.
- **`Blackout-{{VERSION}}-mac.zip`** — macOS 13 or newer, Apple Silicon and Intel. Unzip and drag `Blackout.app` into Applications.

The first time you open it, the list already contains four lines telling you how to use it. Delete them as you learn them.

Then press <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>`</kbd>.

### Windows will warn you

SmartScreen will say *"Windows protected your PC"* and refuse to run the installer. Click **More info → Run anyway**.

The binaries are not code-signed. A certificate costs $200–400 a year, and a fresh one gets flagged anyway until it builds up reputation — that math does not work for a free 132 KB utility.

Verify instead of trusting. Every file is listed in `SHA256SUMS.txt`:

```powershell
Get-FileHash .\Blackout-{{VERSION}}-Setup.exe -Algorithm SHA256
```

You can also read every line of source in this repo — it is one C file — and build it yourself with `build.bat`.

### macOS will block it too

The Mac app is not notarized, for the same reason: Apple charges $99 a year for it. The first time you open it, macOS refuses. Click **Done**, then **System Settings → Privacy & Security → Open Anyway**. Or:

```sh
xattr -dr com.apple.quarantine /Applications/Blackout.app
```

Check the zip against `SHA256SUMS.txt` with `shasum -a 256 Blackout-{{VERSION}}-mac.zip`.

Built from this tag by GitHub Actions; the workflow run is linked on this page.
