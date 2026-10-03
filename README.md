# TeraBox Downloader CLI (v2.1)

A high-performance, cross-platform command-line tool designed to list, resolve, and recursively download files and folders from TeraBox shared links using unofficial APIs, session authentication, and multi-threaded stream downloading.

Works seamlessly on **Windows**, **Linux**, and **macOS**.

---

## Key Features in v2.1

- ⚡ **Multi-Threaded Parallel Downloads:** Download multiple files simultaneously with individual Rich progress bars (`--threads`).
- 📁 **Full Recursive Folder Support:** Correctly identifies shared directories and recreates nested folder hierarchies locally.
- 💬 **Interactive Prompt Loop:** Run `terabox-dl` without arguments to enter an interactive session for continuous URL downloading without restarting.
- 🎯 **Interactive Item Selector:** Filter and pick specific files or folders before downloading (`--interactive` / `-i`).
- 🔄 **Resilient Resume & Retry:** Automatically resumes broken or interrupted downloads using HTTP `Range` headers with exponential backoff retry.
- 🏷️ **Smart Duplicate Collision Handling:** Automatically renames files (e.g. `video(1).mp4`) when identical names exist across different links instead of skipping or overwriting.
- 📦 **Instant Archive Skipping:** Pre-filters links against `terabox-dl.archive.txt` before making network calls, avoiding unnecessary API queries for completed items.
- 🧹 **Clean Terminal UI by Default:** Hides noisy token acquisition and internal API resolution lines unless verbose mode (`-v`) is enabled.
- 📏 **Smart Terminal Truncation:** Truncates long file names with `...` while preserving extensions to ensure clean, aligned single-line progress bars.
- 🛑 **Immediate Interrupt:** Native Windows (`ctypes`) and Unix signal handling to abort immediately on `Ctrl+C` without thread hanging.

---

## 1. Prerequisites & Installation

### Requirements
- **Python 3.8+**

### Install Dependencies
Clone or download this repository, navigate to the folder, and run:
```bash
pip install -r requirements.txt
```
*(Or manually install: `pip install requests python-dotenv rich`)*

---

## 2. Configuration & Authentication

The tool reads configuration in this priority order (highest overrides lowest):
1. **Command-Line Arguments** (e.g., `-o`, `-n`, `-t`, etc.)
2. **`terabox-dl.config.json`** (local configuration file)
3. **`.env`** (credentials file)
4. **Environment Variables** (`$env:TERABOX_NDUS` or `export TERABOX_NDUS`)
5. **Built-in Defaults**

### Step A: Set up your `.env` File
Create or edit the `.env` file in the script directory:
```env
TERABOX_NDUS=your_copied_ndus_cookie_value
```

### Step B: How to Get Your `ndus` Cookie
1. Log in to [terabox.com](https://www.terabox.com) in your browser.
2. Open Developer Tools (press **F12** or right-click -> **Inspect**).
3. Open the **Application** tab (Chrome/Edge) or **Storage** tab (Firefox).
4. Under **Cookies**, select `https://www.terabox.com`.
5. Locate the **`ndus`** cookie, copy its entire value, and paste it into your `.env` file.

### Step C: Customize Settings (Optional)
Edit `terabox-dl.config.json` to change default behaviors:
```json
{
  "outputDir": "Downloads",
  "maxRetries": 3,
  "resume": true,
  "threads": 3,
  "timeout": 30,
  "verbose": false,
  "logFile": "terabox-dl.log.csv",
  "archiveFile": "terabox-dl.archive.txt",
  "envFile": ".env",
  "userAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  "appId": "250528"
}
```

---

## 3. Usage & Examples

You can run the script directly via `python terabox_dl.py` or use the included launcher aliases (`terabox-dl`).

### 1. Interactive Loop Mode
Run without arguments to enter an interactive session. Paste links one by one; press `Ctrl+C` or type `exit` to quit:
```bash
terabox-dl
```

### 2. Single Link Download
Download all files/folders from a shared link:
```bash
terabox-dl "https://1024terabox.com/s/1y7jen-bPZdcBmQvcrpAUSQ"
```

### 3. Batch Download via Text File
Download multiple links sequentially from a text file (one URL per line, lines with `#` are ignored):
```bash
terabox-dl "links.txt"
```

### 4. List-Only Mode (No Download)
Inspect shared link contents and folder hierarchies without downloading:
```bash
terabox-dl "https://1024terabox.com/s/1y7jen-bPZdcBmQvcrpAUSQ" -l
```

### 5. Multi-Threaded Parallel Downloads
Specify how many files to download concurrently (e.g. 5 threads):
```bash
terabox-dl "https://1024terabox.com/s/1y7jen-bPZdcBmQvcrpAUSQ" -t 5
```

### 6. Interactive File Selection
Choose specific files or folders to download using numbers (e.g. `1,3,5-8`):
```bash
terabox-dl "https://1024terabox.com/s/1y7jen-bPZdcBmQvcrpAUSQ" -i
```

### 7. Verbose Diagnostics Mode
Show detailed internal API operations, jsToken extraction, and share resolving logs:
```bash
terabox-dl "https://1024terabox.com/s/1y7jen-bPZdcBmQvcrpAUSQ" -v
```

### 8. Custom Output Directory
Override the target download destination:
```bash
terabox-dl "https://1024terabox.com/s/1y7jen-bPZdcBmQvcrpAUSQ" -o "D:\Media"
```

---

## 4. CLI Arguments Reference

| Option | Long Flag | Description |
| :--- | :--- | :--- |
| `url` | *(positional)* | Direct TeraBox share link or path to `.txt` file containing URLs |
| `-l` | `--list-only` | List files and folder contents without downloading |
| `-t` | `--threads` | Number of concurrent download workers (default: `3`) |
| `-i` | `--interactive` | Prompt to pick specific files/folders to download |
| `-v` | `--verbose` | Display verbose token acquisition and resolution diagnostics |
| `-o` | `--output` | Directory where downloaded files will be saved |
| `-n` | `--ndus` | Pass `ndus` session cookie directly from the command line |
| `-r` | `--max-retries` | Max retry attempts per file upon network failure (default: `3`) |
| | `--no-resume` | Disable resume capability (forces full redownload) |
| | `--no-archive` | Disable skipping links recorded in `terabox-dl.archive.txt` |
| | `--no-log` | Disable writing download sessions to `terabox-dl.log.csv` |
| `-c` | `--config` | Path to a custom JSON configuration file |

---

## 5. Shell Integration & Aliases

### Windows (PowerShell)
Place `Terabox-dl.ps1` in your directory (or a folder on your system `$PATH`), then invoke directly:
```powershell
terabox-dl "https://..."
```

### Windows (Command Prompt / CMD)
Use `terabox-dl.bat`:
```cmd
terabox-dl "https://..."
```

### Linux / macOS
Add an alias to your `~/.bashrc` or `~/.zshrc`:
```bash
alias terabox-dl="python3 /path/to/Terabox-dl/terabox_dl.py"
```

---

## 6. Troubleshooting & FAQs

### Q: Download fails or gets connection reset error?
Network-level Deep Packet Inspection (DPI) or censorship may block TeraBox domains.
* **Auto-Resume:** Simply run the command again; it will automatically resume from the last saved byte.
* **Proxy / VPN:** Configure your terminal proxy before running the script:
  * **PowerShell:**
    ```powershell
    $env:http_proxy="http://127.0.0.1:YOUR_PORT"
    $env:https_proxy="http://127.0.0.1:YOUR_PORT"
    ```
  * **Linux / macOS:**
    ```bash
    export http_proxy="http://127.0.0.1:YOUR_PORT"
    export https_proxy="http://127.0.0.1:YOUR_PORT"
    ```

### Q: "Access denied — cookie may be invalid or expired"?
Your TeraBox `ndus` cookie has expired. Log back into [terabox.com](https://www.terabox.com) in your web browser and update the `TERABOX_NDUS` value in your `.env` file.
