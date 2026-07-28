## Install

- **`Blackout-{{VERSION}}-Setup.exe`** — installs for your user only. No admin rights, no UAC prompt.
- **`Blackout-{{VERSION}}-portable.zip`** — unzip and run it from anywhere.

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

Built from this tag by GitHub Actions; the workflow run is linked on this page.
