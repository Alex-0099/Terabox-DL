# TeraBox Downloader CLI — User Guide

A highly resilient PowerShell Core (`pwsh`) command-line tool designed to list and recursively download files and folders from TeraBox shared links using unofficial APIs and cookie authentication.

---

## Features
- **Recursive Downloads:** Recreates complete folder structures locally.
- **Dynamic Dlink Resolution:** Generates direct download links on-the-fly using the `/api/sharedownload` endpoint to avoid expired link errors.
- **Resilient Retry Loop:** Defaults to 10 retry attempts with exponential backoff to handle unstable networks.
- **Resume Support:** Automatically resumes interrupted files using HTTP Range headers instead of starting over.
- **Drive Fallback:** Safely redirects downloads to the script directory if the configured download drive (e.g. `D:`) is not found.
- **Archive Database:** Bypasses fully downloaded links instantly, reducing API traffic and script execution time.
- **Real-Time Speed Meter:** Displays downloading speed (in KB/s or MB/s), percentage progress, and byte count dynamically in the terminal.

---

## 1. Prerequisites
- **PowerShell Core (v7.x or later):** Recommended for native TLS 1.3 support and Unix compatibility.
- **Active Cookie Session:** A valid `ndus` cookie from a logged-in TeraBox account.

---

## 2. Configuration & Setup

The script loads configuration in the following order of priority (highest priority overrides lowest):
1. **Command-Line Arguments** (e.g., `-OutputDir`, `-NdusCookie`, etc.)
2. **`terabox-dl.config.json`** (local configuration file)
3. **`.env`** (environment file for credentials)
4. **System Environment Variables** (e.g. `$env:TERABOX_NDUS`)
5. **Built-in Script Defaults**

### Step A: Configure your `.env` file
Create or edit the `.env` file next to the script to store your session cookie safely:
```env
TERABOX_NDUS=your_copied_ndus_cookie_value
```

### Step B: Configure settings in `terabox-dl.config.json`
Adjust global settings such as fallback limits, directories, and logging paths:
```json
{
  "outputDir": "D:\\Downloads\\TeraBox",
  "maxRetries": 10,
  "resume": true,
  "timeoutSec": 600,
  "logFile": "terabox-dl.log.csv",
  "logLevel": "all",
  "envFile": ".env",
  "archiveFile": "terabox-dl.archive.txt",
  "userAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
  "appId": "250528"
}
```

---

## 3. How to Get Your `ndus` Cookie
1. Log in to [terabox.com](https://www.terabox.com) in your web browser.
2. Open Developer Tools (press **F12** or right-click and select **Inspect**).
3. Go to the **Application** (Chrome/Edge) or **Storage** (Firefox) tab.
4. Expand **Cookies** in the left sidebar and select `https://www.terabox.com`.
5. Locate the cookie named **`ndus`**. Double-click and copy its complete value.
6. Paste it into the `TERABOX_NDUS` variable in your `.env` file.

---

## 4. Usage Examples

Always execute the script using PowerShell Core (`pwsh`). Run commands from the directory containing the script.

### Single Link Downloads
Download all contents of a shared link into the default output directory:
```powershell
pwsh -File .\Terabox-dl.ps1 -Url "https://www.terabox.com/s/1yR1wZ9tiQm4bTv3DRMnQoQ"
```

### Batch Mode (List File)
To download multiple links sequentially, create a text file (e.g., `links.txt`) with one URL per line. Use `#` for comments:
```text
# Family Vacations
https://www.terabox.com/s/1yR1wZ9tiQm4bTv3DRMnQoQ
# Project Deliverables
https://www.terabox.com/s/another_link_here
```
Pass the text file path directly into the `-Url` parameter:
```powershell
pwsh -File .\Terabox-dl.ps1 -Url ".\links.txt"
```

### List-Only Mode
List files and directory structures without executing any downloads:
```powershell
pwsh -File .\Terabox-dl.ps1 -Url "https://www.terabox.com/s/1yR1wZ9tiQm4bTv3DRMnQoQ" -ListOnly
```

### Custom Output Directory
Override the config file download directory via command line:
```powershell
pwsh -File .\Terabox-dl.ps1 -Url "https://www.terabox.com/s/1yR1wZ9tiQm4bTv3DRMnQoQ" -OutputDir "C:\Users\Public\Downloads"
```

### Override Retry Attempts
Increase or decrease the maximum number of network/download retries:
```powershell
pwsh -File .\Terabox-dl.ps1 -Url "https://www.terabox.com/s/1yR1wZ9tiQm4bTv3DRMnQoQ" -MaxRetries 15
```

### Disable Archiving or Resuming
Disable checking or writing to the completed link database:
```powershell
pwsh -File .\Terabox-dl.ps1 -Url "https://www.terabox.com/s/1yR1wZ9tiQm4bTv3DRMnQoQ" -NoArchive
```
Disable file resumption (forces downloading partially completed files from scratch):
```powershell
pwsh -File .\Terabox-dl.ps1 -Url "https://www.terabox.com/s/1yR1wZ9tiQm4bTv3DRMnQoQ" -NoResume
```

### Interactive Selector Menu
Filter files and folders interactively before starting downloads:
```powershell
pwsh -File .\Terabox-dl.ps1 -Url "https://www.terabox.com/s/1yR1wZ9tiQm4bTv3DRMnQoQ" -Interactive
```

### Parallel / Concurrent Downloads
Download multiple files concurrently to maximize download bandwidth (e.g. 3 threads):
```powershell
pwsh -File .\Terabox-dl.ps1 -Url "https://www.terabox.com/s/1yR1wZ9tiQm4bTv3DRMnQoQ" -Threads 3
```
*Note: You can also configure `"threads": 3` inside your `terabox-dl.config.json` file for permanent parallel processing.*

---

## 5. Python Guide (`terabox_dl.py`)

A fully cross-platform Python port of the downloader. It supports Windows, macOS, and Linux out-of-the-box.

### Step 1: Install Prerequisites
Install the required standard libraries:
```bash
pip install requests python-dotenv rich
```

### Step 2: Usage Examples
Always run the script using Python 3:

```bash
# Single link download
python terabox_dl.py "https://www.terabox.com/s/1yR1wZ9tiQm4bTv3DRMnQoQ"

# Batch download (extracts and downloads all links from tb.txt)
python terabox_dl.py ".\tb.txt"

# List contents only (no download)
python terabox_dl.py "https://www.terabox.com/s/1yR1wZ9tiQm4bTv3DRMnQoQ" --list-only

# Interactive selection
python terabox_dl.py "https://www.terabox.com/s/1yR1wZ9tiQm4bTv3DRMnQoQ" --interactive

# Download concurrently with custom threads (e.g. 5 threads)
python terabox_dl.py "https://www.terabox.com/s/1yR1wZ9tiQm4bTv3DRMnQoQ" --threads 5
```

---

## 6. Troubleshooting SSL/TLS Interception

If you encounter connection reset errors, it is usually caused by network-level deep packet inspection (DPI) or censorship (common in regions where Baidu/TeraBox domains are blocked). The ISP middlebox forcibly resets the connection during the TLS handshake.

**Solutions:**
1. **Re-Run the Command:** Because the ISP interception is highly unstable, retrying (or simply starting the script again) will resume the download from where it failed.
2. **Use a Proxy/VPN:** You can route all script HTTP traffic through a local proxy or VPN by declaring environment variables in your terminal window before running the script:
   * **PowerShell:**
     ```powershell
     $env:http_proxy = "http://127.0.0.1:YOUR_PROXY_PORT"
     $env:https_proxy = "http://127.0.0.1:YOUR_PROXY_PORT"
     ```
   * **Bash (Linux/macOS):**
     ```bash
     export http_proxy="http://127.0.0.1:YOUR_PROXY_PORT"
     export https_proxy="http://127.0.0.1:YOUR_PROXY_PORT"
     ```
