#!/usr/bin/env python3
import os
import sys

# Reconfigure standard streams to UTF-8 to prevent console encoding errors on Windows
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8')

import json
import re
import csv
import time
import signal
import threading
import argparse
import urllib.parse
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
import requests
from dotenv import load_dotenv
from rich.console import Console
from rich.progress import Progress, TextColumn, BarColumn, DownloadColumn, TransferSpeedColumn, TimeRemainingColumn

console = Console()
shutdown_event = threading.Event()

APP_ID = "250528"
BASE_URL = "https://www.terabox.com"

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": "https://www.terabox.com/",
    "X-Requested-With": "XMLHttpRequest"
}

ERROR_MESSAGES = {
    -1: "Server error or rate limited. Try again later.",
    -3: "Invalid or missing parameters in request.",
    -6: "Share link has expired or been removed.",
    -7: "File or share requires a password.",
    -9: "File does not exist or has been deleted.",
    -12: "Insufficient storage space on your account.",
    -20: "Session expired. Please refresh your ndus cookie.",
    -21: "Share link has been banned/restricted.",
    -32: "Exceeded download frequency limit. Wait and retry.",
    -33: "File too large for free-tier download.",
    2: "Download link expired. Re-fetching...",
    4: "Request too frequent. Please wait.",
    12: "Access denied — cookie may be invalid or expired.",
    31: "Sign/token verification failed. Cookie may need refresh.",
    105: "Invalid share link format.",
    112: "Session expired or cookie invalid. Please re-authenticate.",
    118: "Download quota exceeded for this file.",
    400210: "jsToken missing or invalid. Will auto-refresh.",
    4000023: "jsToken expired. Will auto-refresh.",
}

DEFAULT_CONFIG = {
    "ndusCookie": "",
    "outputDir": "Downloads",
    "maxRetries": 3,
    "resume": True,
    "logFile": "terabox-dl.log.csv",
    "archiveFile": "terabox-dl.archive.txt",
    "envFile": ".env",
    "threads": 3,
    "userAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "timeout": 30,
    "verbose": False
}

# Statistics tracking
stats = {
    'TotalFiles': 0,
    'Downloaded': 0,
    'Skipped': 0,
    'Failed': 0,
    'TotalBytes': 0,
    'StartTime': None
}

download_queue = []
js_token = None

# Helper functions
def format_file_size(size_bytes):
    if size_bytes >= 1024**3:
        return f"{size_bytes / 1024**3:.2f} GB"
    if size_bytes >= 1024**2:
        return f"{size_bytes / 1024**2:.2f} MB"
    if size_bytes >= 1024:
        return f"{size_bytes / 1024:.2f} KB"
    return f"{size_bytes} B"

def format_duration(seconds):
    if seconds >= 3600:
        h = int(seconds // 3600)
        m = int((seconds % 3600) // 60)
        s = int(seconds % 60)
        return f"{h}h {m}m {s}s"
    if seconds >= 60:
        m = int(seconds // 60)
        s = int(seconds % 60)
        return f"{m}m {s}s"
    return f"{seconds:.1f}s"

def get_safe_filename(name):
    if not name:
        return "unnamed_file"
    clean = os.path.basename(name)
    clean = re.sub(r'[<>:"/\\|?*\x00-\x1F]', '_', clean)
    if not clean or clean in ('.', '..'):
        import uuid
        return f"file_{uuid.uuid4().hex[:8]}"
    return clean

def truncate_filename(name, max_len=40):
    if not name or len(name) <= max_len:
        return name
    base, ext = os.path.splitext(name)
    if len(ext) > 10:
        return name[:max_len - 3] + "..."
    avail = max_len - len(ext) - 3
    if avail < 4:
        return name[:max_len - 3] + "..."
    head_len = avail // 2 + (avail % 2)
    tail_len = avail // 2
    if tail_len > 0:
        return f"{base[:head_len]}...{base[-tail_len:]}{ext}"
    return f"{base[:head_len]}...{ext}"

def get_error_message(code):
    return ERROR_MESSAGES.get(code, f"Unknown API error (code: {code}).")

# Archive file functions
def test_is_key_archived(key, archive_file_path):
    if not archive_file_path or not os.path.exists(archive_file_path):
        return False
    try:
        with open(archive_file_path, 'r', encoding='utf-8') as f:
            for line in f:
                if line.strip() == key:
                    return True
    except Exception:
        pass
    return False

def add_key_to_archive(key, archive_file_path):
    if not archive_file_path:
        return
    try:
        parent_dir = os.path.dirname(archive_file_path)
        if parent_dir:
            os.makedirs(parent_dir, exist_ok=True)
        with open(archive_file_path, 'a', encoding='utf-8') as f:
            f.write(f"{key}\n")
    except Exception as e:
        console.print(f"[yellow]⚠ Failed to write to archive file: {e}[/yellow]")

# Log file functions
def write_log_entry(log_file, status, share_url="", file_name="", file_size=0, downloaded_bytes=0, speed="", duration="", output_path="", error_message=""):
    if not log_file:
        return
    try:
        log_dir = os.path.dirname(os.path.abspath(log_file))
        if log_dir:
            os.makedirs(log_dir, exist_ok=True)
        file_exists = os.path.exists(log_file)
        
        with open(log_file, 'a', encoding='utf-8', newline='') as f:
            writer = csv.writer(f)
            if not file_exists:
                writer.writerow(["Timestamp", "Status", "ShareUrl", "FileName", "FileSize", "DownloadedBytes", "Speed", "Duration", "OutputPath", "ErrorMessage"])
            
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            writer.writerow([timestamp, status, share_url, file_name, file_size, downloaded_bytes, speed, duration, output_path, error_message])
    except Exception:
        pass

# Config loading and default writing
def load_config(custom_path=None):
    script_dir = os.path.dirname(os.path.abspath(__file__))
    config_file = custom_path if custom_path else os.path.join(script_dir, "terabox-dl.config.json")
    
    config = DEFAULT_CONFIG.copy()
    
    if os.path.exists(config_file):
        try:
            with open(config_file, 'r', encoding='utf-8') as f:
                loaded = json.load(f)
                for k, v in loaded.items():
                    config[k] = v
        except Exception as e:
            console.print(f"[yellow]⚠ Failed to load config file: {e}. Using defaults.[/yellow]")
    else:
        if not custom_path:
            try:
                with open(config_file, 'w', encoding='utf-8') as f:
                    json.dump(DEFAULT_CONFIG, f, indent=4)
            except Exception:
                pass
    return config

# Get jsToken
def get_js_token(session, target_url=None, verbose=False):
    urls_to_try = []
    if target_url:
        urls_to_try.append(target_url)
    urls_to_try.append(BASE_URL)
    
    for url in urls_to_try:
        if verbose:
            console.print(f"[yellow]⟳ Fetching jsToken from {url}...[/yellow]")
        try:
            resp = session.get(url, headers=HEADERS, timeout=30)
            html = resp.text
            
            # Primary pattern (encoded backticks)
            start_marker = '`function%20fn%28a%29%7Bwindow.jsToken%20%3D%20a%7D%3Bfn%28%22'
            end_marker = '%22%29`'
            if start_marker in html:
                start_idx = html.index(start_marker) + len(start_marker)
                end_idx = html.index(end_marker, start_idx)
                token = html[start_idx:end_idx]
                if token:
                    if verbose:
                        console.print(f"[green]✓ jsToken acquired ({len(token)} chars)[/green]")
                    return token
                    
            # Alt pattern (without backticks)
            start_marker_alt = 'function%20fn%28a%29%7Bwindow.jsToken%20%3D%20a%7D%3Bfn%28%22'
            end_marker_alt = '%22%29'
            if start_marker_alt in html:
                start_idx = html.index(start_marker_alt) + len(start_marker_alt)
                end_idx = html.index(end_marker_alt, start_idx)
                token = html[start_idx:end_idx]
                if token:
                    if verbose:
                        console.print(f"[green]✓ jsToken acquired via alt pattern ({len(token)} chars)[/green]")
                    return token
                    
            # window.jsToken regex
            m = re.search(r'window\.jsToken\s*=\s*["\']([a-zA-Z0-9_.-]+)["\']', html)
            if m:
                token = m.group(1)
                if verbose:
                    console.print(f"[green]✓ jsToken acquired via window.jsToken ({len(token)} chars)[/green]")
                return token
                
            # JSON format
            m = re.search(r'["\']jsToken["\']\s*:\s*["\']([a-zA-Z0-9_.-]+)["\']', html)
            if m:
                token = m.group(1)
                if verbose:
                    console.print(f"[green]✓ jsToken acquired via JSON pattern ({len(token)} chars)[/green]")
                return token
                
            # fn("TOKEN") format
            m = re.search(r'fn\(\s*["\']([a-zA-Z0-9_.-]{16,})["\']\s*\)', html)
            if m:
                token = m.group(1)
                if verbose:
                    console.print(f"[green]✓ jsToken acquired via fn() pattern ({len(token)} chars)[/green]")
                return token
                
            if verbose:
                console.print(f"[yellow]⚠ Could not extract jsToken from {url}.[/yellow]")
        except Exception as e:
            if verbose:
                console.print(f"[yellow]⚠ Failed to fetch jsToken from {url}: {e}[/yellow]")
            
    if verbose:
        console.print("[red]✗ Could not extract jsToken from any source.[/red]")
    return None

# Resolve share info
def get_share_info(session, short_url, config):
    global js_token
    verbose = config.get('verbose', False)
    if verbose:
        console.print("[yellow]⟳ Resolving shared link...[/yellow]")
    
    params = {
        'shorturl': short_url,
        'root': '1',
        'app_id': APP_ID,
        'web': '1',
        'channel': 'dubox',
        'clienttype': '0'
    }
    if js_token:
        params['jsToken'] = js_token
        
    url = f"{BASE_URL}/api/shorturlinfo"
    
    for attempt in range(1, 4):
        try:
            resp = session.get(url, params=params, headers=HEADERS, timeout=30)
            resp_data = resp.json()
            
            # Handle jsToken refresh
            if resp_data.get('errno') in (400210, 4000023):
                if verbose:
                    console.print("  [yellow]⚠ jsToken invalid/expired — refreshing...[/yellow]")
                js_token = get_js_token(session, target_url=f"{BASE_URL}/s/{short_url}", verbose=verbose)
                if js_token:
                    params['jsToken'] = js_token
                    resp = session.get(url, params=params, headers=HEADERS, timeout=30)
                    resp_data = resp.json()
                    
            if resp_data.get('errno', 0) != 0:
                err_msg = get_error_message(resp_data.get('errno'))
                console.print(f"[red]✗ {err_msg}[/red]")
                write_log_entry(config['logFile'], "FAILED", share_url=f"{BASE_URL}/s/{short_url}", file_name="(resolve)", error_message=err_msg)
                raise Exception(err_msg)
                
            if verbose:
                console.print(f"[green]✓ Share resolved: {resp_data.get('title', 'Shared Files')}[/green]")
            write_log_entry(config['logFile'], "INFO", share_url=f"{BASE_URL}/s/{short_url}", file_name=f"(resolved: {resp_data.get('title', 'Shared Files')})")
            
            return {
                'ShareId': resp_data.get('shareid'),
                'Uk': resp_data.get('uk'),
                'Sign': resp_data.get('sign'),
                'Timestamp': resp_data.get('timestamp'),
                'Randsk': resp_data.get('randsk'),
                'Title': resp_data.get('title'),
                'FileList': resp_data.get('list', [])
            }
        except Exception as e:
            if attempt == 3:
                raise e
            time.sleep(1)

def is_item_dir(item):
    val = item.get('isdir')
    return val == 1 or str(val).strip() == '1' or val is True

# Get folder contents recursively
def get_folder_contents(session, share_id, uk, sign, timestamp, directory, config, target_url=None):
    global js_token
    all_items = []
    current_page = 1
    limit = 100
    
    while True:
        params = {
            'shareid': share_id,
            'uk': uk,
            'sign': sign,
            'timestamp': timestamp,
            'dir': directory,
            'root': '1' if directory == '/' else '0',
            'app_id': APP_ID,
            'web': '1',
            'channel': 'dubox',
            'clienttype': '0',
            'page': current_page,
            'num': limit,
            'order': 'name'
        }
        if js_token:
            params['jsToken'] = js_token
            
        url = f"{BASE_URL}/share/list"
        try:
            resp = session.get(url, params=params, headers=HEADERS, timeout=30)
            resp_data = resp.json()
            
            if resp_data.get('errno') in (400210, 4000023):
                verbose = config.get('verbose', False) if config else False
                if verbose:
                    console.print("  [yellow]⚠ jsToken invalid/expired — refreshing...[/yellow]")
                js_token = get_js_token(session, target_url=target_url if target_url else BASE_URL, verbose=verbose)
                if js_token:
                    params['jsToken'] = js_token
                    resp = session.get(url, params=params, headers=HEADERS, timeout=30)
                    resp_data = resp.json()
                    
            if resp_data.get('errno', 0) != 0:
                err_msg = get_error_message(resp_data.get('errno'))
                console.print(f"  [red]✗ Folder listing error: {err_msg}[/red]")
                return all_items
                
            items = resp_data.get('list', [])
            if items:
                all_items.extend(items)
                current_page += 1
                if len(items) < limit:
                    break
            else:
                break
        except Exception as e:
            console.print(f"  [red]✗ Failed to list folder '{directory}': {e}[/red]")
            return all_items
            
    return all_items

# Recursively queue items
def invoke_process_items(items, dest_dir, session, share_id, uk, sign, timestamp, randsk, url, list_only, config, depth=0):
    if not items:
        return
        
    indent = "  " * depth
    for item in items:
        is_dir = is_item_dir(item)
        
        if is_dir:
            folder_name = item.get('server_filename')
            disp_folder = truncate_filename(folder_name, 45)
            folder_path = item.get('path')
            
            console.print(f"{indent}[yellow]📁 {disp_folder}/[/yellow]")
            
            sub_dir = dest_dir
            if not list_only:
                sub_dir = os.path.join(dest_dir, folder_name)
                os.makedirs(sub_dir, exist_ok=True)
                
            sub_items = get_folder_contents(session, share_id, uk, sign, timestamp, folder_path, config, target_url=url)
            if sub_items:
                invoke_process_items(sub_items, sub_dir, session, share_id, uk, sign, timestamp, randsk, url, list_only, config, depth + 1)
            else:
                console.print(f"{indent}[grey50]  (empty folder)[/grey50]")
        else:
            name = item.get('server_filename')
            disp_name = truncate_filename(name, 45)
            size_bytes = int(item.get('size', 0))
            size_str = format_file_size(size_bytes)
            stats['TotalFiles'] += 1
            
            if list_only:
                console.print(f"{indent}📄 {disp_name}  ({size_str})")
            else:
                console.print(f"{indent}[grey50]📄 {disp_name}  ({size_str}) [queued][/grey50]")
                download_queue.append({
                    'FileItem': item,
                    'DestDir': dest_dir,
                    'ShareId': share_id,
                    'Uk': uk,
                    'Sign': sign,
                    'Timestamp': timestamp,
                    'Randsk': randsk,
                    'Url': url
                })

def parse_selection(selection_str, max_val):
    if not selection_str.strip():
        return list(range(max_val))
    indices = set()
    parts = selection_str.split(',')
    for part in parts:
        part = part.strip()
        if '-' in part:
            try:
                start_str, end_str = part.split('-')
                start = int(start_str)
                end = int(end_str)
                indices.update(range(start - 1, min(end, max_val)))
            except ValueError:
                pass
        else:
            try:
                idx = int(part)
                if 1 <= idx <= max_val:
                    indices.add(idx - 1)
            except ValueError:
                pass
    return sorted(list(indices))

def get_short_url_key(raw_url):
    raw_url = raw_url.strip().rstrip('/')
    # Format: /s/1ABCxyz
    if '/s/' in raw_url:
        return raw_url.split('/s/')[-1]
    # Format: /sharing/link?surl=ABCxyz  (surl = key without leading '1')
    if 'surl=' in raw_url:
        parsed = urllib.parse.urlparse(raw_url)
        params = urllib.parse.parse_qs(parsed.query)
        surl = params.get('surl', [None])[0]
        if surl:
            return '1' + surl
    # Bare key (no slashes, no protocol)
    if '/' not in raw_url and ':' not in raw_url:
        return raw_url
    console.print(f"[red]✗ Could not extract share key from URL: {raw_url}[/red]")
    raise Exception("Invalid TeraBox URL format.")

def get_terabox_download_link(session, fs_id, share_id, uk, sign, timestamp, randsk, headers, timeout):
    decoded_randsk = randsk
    if '%' in decoded_randsk:
        decoded_randsk = urllib.parse.unquote(decoded_randsk)
        
    extra = f'{{"sekey":"{decoded_randsk}"}}'
    extra_escaped = urllib.parse.quote(extra)
    data = f"encrypt=0&extra={extra_escaped}&fid_list=[{fs_id}]&primaryid={share_id}&uk={uk}&product=share&type=nolimit"
    
    uri = f"{BASE_URL}/api/sharedownload?app_id={APP_ID}&channel=chunlei&clienttype=12&sign={sign}&timestamp={timestamp}&web=1"
    
    post_headers = headers.copy()
    post_headers["Content-Type"] = "application/x-www-form-urlencoded"

    for attempt in range(1, 4):
        try:
            resp = session.post(uri, headers=post_headers, data=data, timeout=15)
            resp_data = resp.json()
            if resp_data.get('errno') == 0 and resp_data.get('list'):
                return resp_data['list'][0].get('dlink')
            err_msg = resp_data.get('errmsg', f"errno {resp_data.get('errno')}")
            console.print(f"  [yellow]⚠ sharedownload API error: {err_msg}[/yellow]")
        except Exception as e:
            console.print(f"  [yellow]⚠ sharedownload request failed (attempt {attempt}/3): {e}[/yellow]")
            time.sleep(1)
    return None

# Download file worker
def download_file_worker(queue_item, session, headers, config, progress=None, task_id=None):
    file_item = queue_item['FileItem']
    dest_dir = queue_item['DestDir']
    share_id = queue_item['ShareId']
    uk = queue_item['Uk']
    sign = queue_item['Sign']
    timestamp = queue_item['Timestamp']
    randsk = queue_item['Randsk']
    url = queue_item['Url']
    
    file_name = get_safe_filename(file_item.get('server_filename'))
    disp_name = truncate_filename(file_name, 35)
    file_size = int(file_item.get('size', 0))
    dlink = file_item.get('dlink')
    
    dest_path = os.path.join(dest_dir, file_name)
    
    # Early exit if shutdown was requested
    if shutdown_event.is_set():
        return {
            'Status': 'FAILED',
            'FileName': file_name,
            'FileSize': file_size,
            'Bytes': 0,
            'ErrorMessage': 'Interrupted by user',
            'OutputPath': dest_path,
            'ShareUrl': url
        }
    
    # 1. Fetch direct download link if needed
    if not dlink:
        if share_id and uk and sign and timestamp and randsk:
            if progress:
                progress.update(task_id, description=f"[yellow]⟳ Link: {disp_name}[/yellow]", visible=True)
            else:
                console.print(f"  [yellow]⟳ Fetching direct link for '{disp_name}'...[/yellow]")
                
            dlink = get_terabox_download_link(session, file_item.get('fs_id'), share_id, uk, sign, timestamp, randsk, headers, config['timeout'])
            
    if not dlink:
        if progress:
            progress.update(task_id, description=f"[red]✗ Failed: {disp_name}[/red]", visible=False)
        else:
            console.print(f"  [red]⚠ No download link available for '{disp_name}' — skipping.[/red]")
        return {
            'Status': 'FAILED',
            'FileName': file_name,
            'FileSize': file_size,
            'Bytes': 0,
            'ErrorMessage': 'No dlink available',
            'OutputPath': dest_path,
            'ShareUrl': url
        }
        
    # 2. Handle filename collisions: auto-rename if a completed file with the same name exists
    #    A "completed" file is one whose size >= the target size (same or different content).
    #    A "partial" file is one whose size < the target size (resume candidate).
    if os.path.exists(dest_path):
        existing_size = os.path.getsize(dest_path)
        if existing_size >= file_size:
            # Existing file is complete (same or larger) — auto-rename to avoid overwriting
            base, ext = os.path.splitext(dest_path)
            counter = 1
            while True:
                new_path = f"{base}({counter}){ext}"
                if not os.path.exists(new_path):
                    dest_path = new_path
                    file_name = os.path.basename(dest_path)
                    disp_name = truncate_filename(file_name, 35)
                    if progress:
                        progress.update(task_id, description=f"[yellow]↓ Renamed: {disp_name}[/yellow]")
                    break
                elif os.path.getsize(new_path) >= file_size:
                    # This renamed copy also exists with same/larger size, try next number
                    counter += 1
                else:
                    # Partial download of this renamed file — resume it
                    dest_path = new_path
                    file_name = os.path.basename(dest_path)
                    disp_name = truncate_filename(file_name, 35)
                    break
        # else: existing file is smaller = partial download, will be resumed in retry loop
            
    # 3. Download retry loop
    max_retries = config['maxRetries']
    for attempt in range(1, max_retries + 1):
        try:
            resume_pos = 0
            if config['resume'] and os.path.exists(dest_path):
                resume_pos = os.path.getsize(dest_path)
                if resume_pos >= file_size:
                    # This dest_path was just auto-renamed above, so this shouldn't happen
                    # unless file appeared between rename and here — treat as complete
                    if progress:
                        progress.update(task_id, description=f"[grey50]⊘ Complete: {disp_name}[/grey50]", completed=file_size, visible=False)
                    return {
                        'Status': 'SKIPPED',
                        'FileName': file_name,
                        'FileSize': file_size,
                        'Bytes': 0,
                        'OutputPath': dest_path,
                        'ShareUrl': url
                    }
                    
            dl_headers = headers.copy()
            if resume_pos > 0:
                dl_headers['Range'] = f"bytes={resume_pos}-"
                if progress:
                    progress.update(task_id, description=f"[cyan]↓ Resume: {disp_name}[/cyan]", completed=resume_pos, visible=True)
                else:
                    remain_str = format_file_size(file_size - resume_pos)
                    console.print(f"  [cyan]↓ Resuming: {disp_name} ({remain_str} remaining)[/cyan]")
            else:
                if progress:
                    progress.update(task_id, description=f"[cyan]↓ DL: {disp_name}[/cyan]", completed=0, visible=True)
                else:
                    size_str = format_file_size(file_size)
                    retry_suffix = f" [retry {attempt}/{max_retries}]" if attempt > 1 else ""
                    console.print(f"  [cyan]↓ Downloading: {disp_name} ({size_str}){retry_suffix}[/cyan]")
                    
            dl_start_time = time.time()
            resp = session.get(dlink, headers=dl_headers, stream=True, timeout=config['timeout'])
            
            if resp.status_code not in (200, 206):
                resp.raise_for_status()
                
            is_append = resp.status_code == 206
            mode = 'ab' if is_append else 'wb'
            
            chunk_size = 64 * 1024
            total_read = resume_pos
            bytes_read_this_period = 0
            last_period_time = time.time()
            
            with open(dest_path, mode) as f:
                for chunk in resp.iter_content(chunk_size=chunk_size):
                    if shutdown_event.is_set():
                        resp.close()
                        return {
                            'Status': 'FAILED',
                            'FileName': file_name,
                            'FileSize': file_size,
                            'Bytes': total_read - resume_pos,
                            'ErrorMessage': 'Interrupted by user',
                            'OutputPath': dest_path,
                            'ShareUrl': url
                        }
                    if not chunk:
                        break
                    f.write(chunk)
                    chunk_len = len(chunk)
                    total_read += chunk_len
                    bytes_read_this_period += chunk_len
                    
                    if progress:
                        progress.update(task_id, advance=chunk_len)
                    
                
            dl_duration = time.time() - dl_start_time
            if os.path.exists(dest_path):
                dl_size = os.path.getsize(dest_path)
                if dl_size > 0:
                    speed_bps = dl_size / dl_duration if dl_duration > 0 else 0
                    speed_str = format_file_size(speed_bps) + "/s" if dl_duration > 0 else "instant"
                    
                    if file_size > 0 and dl_size != file_size:
                        console.print(f"  [yellow]⚠ Size mismatch: expected {file_size}, got {dl_size}[/yellow]")
                    else:
                        if progress:
                            progress.update(task_id, description=f"[green]✓ Saved: {disp_name}[/green]", visible=False)
                        else:
                            console.print(f"  [green]✓ Saved: {disp_name} ({format_file_size(dl_size)}, {speed_str})[/green]")
                            
                    return {
                        'Status': 'SUCCESS',
                        'FileName': file_name,
                        'FileSize': file_size,
                        'Bytes': dl_size,
                        'SpeedBytes': speed_bps,
                        'DurationSec': dl_duration,
                        'OutputPath': dest_path,
                        'ShareUrl': url
                    }
        except Exception as e:
            err_msg = str(e)
            if attempt < max_retries:
                wait_sec = 2**attempt + (time.time() % 2)
                if progress:
                    progress.update(task_id, description=f"[yellow]⚠ Retry: {disp_name}[/yellow]")
                else:
                    console.print(f"  [yellow]⚠ Attempt {attempt} failed: {err_msg}. Retrying in {wait_sec:.1f}s...[/yellow]")
                time.sleep(wait_sec)
            else:
                if progress:
                    progress.update(task_id, description=f"[red]✗ Failed: {disp_name}[/red]", visible=False)
                else:
                    console.print(f"  [red]✗ Download failed after {max_retries} attempts: {err_msg}[/red]")
                    
                if not config['resume'] and os.path.exists(dest_path):
                    try: os.remove(dest_path)
                    except: pass
                elif os.path.exists(dest_path) and os.path.getsize(dest_path) == 0:
                    try: os.remove(dest_path)
                    except: pass
                    
                return {
                    'Status': 'FAILED',
                    'FileName': file_name,
                    'FileSize': file_size,
                    'Bytes': 0,
                    'ErrorMessage': err_msg,
                    'OutputPath': dest_path,
                    'ShareUrl': url
                }
    return {
        'Status': 'FAILED',
        'FileName': file_name,
        'FileSize': file_size,
        'Bytes': 0,
        'ErrorMessage': 'Max retries reached',
        'OutputPath': dest_path,
        'ShareUrl': url
    }

# Main function
def main():
    global js_token
    # Print banner
    console.print("")
    console.print("╔══════════════════════════════════════════╗", style="cyan")
    console.print("║         TeraBox Downloader v2.1          ║", style="cyan")
    console.print("║     Unofficial API · Cookie Auth         ║", style="cyan")
    console.print("║  Config · .env · Log · Retry · Resume    ║", style="cyan")
    console.print("╚══════════════════════════════════════════╝", style="cyan")
    console.print("")
    
    # Initialize Arguments
    parser = argparse.ArgumentParser(description="Python port of TeraBox Downloader with parallel progress bars.")
    parser.add_argument("url", nargs='?', default=None, help="Direct share URL or path to a text file containing URLs")
    parser.add_argument("-n", "--ndus", help="Your ndus session cookie value")
    parser.add_argument("-o", "--output", help="Directory to save downloaded files")
    parser.add_argument("-l", "--list-only", action="store_true", help="Only list share contents without downloading")
    parser.add_argument("-r", "--max-retries", type=int, default=-1, help="Max download retries")
    parser.add_argument("--no-resume", action="store_true", help="Disable resume capability")
    parser.add_argument("--no-log", action="store_true", help="Disable logging")
    parser.add_argument("--no-archive", action="store_true", help="Disable archiving keys")
    parser.add_argument("-t", "--threads", type=int, default=-1, help="Number of download threads")
    parser.add_argument("-i", "--interactive", action="store_true", help="Interactive item selector")
    parser.add_argument("-c", "--config", help="Custom configuration JSON path")
    parser.add_argument("-v", "--verbose", action="store_true", help="Show verbose output (e.g. token acquisition and detailed resolving)")
    args = parser.parse_args()
    
    # Load config file
    config = load_config(args.config)
    
    # Load env file
    env_file = config.get("envFile", ".env")
    if not os.path.isabs(env_file):
        env_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), env_file)
        
    if os.path.exists(env_file):
        load_dotenv(env_file)
        
    # Apply CLI overrides
    if args.ndus:
        config['ndusCookie'] = args.ndus
    if not config['ndusCookie'] and os.getenv("TERABOX_NDUS"):
        config['ndusCookie'] = os.getenv("TERABOX_NDUS")
        
    if args.output:
        config['outputDir'] = args.output
        
    if args.max_retries >= 0:
        config['maxRetries'] = args.max_retries
        
    if args.no_resume:
        config['resume'] = False
        
    if args.no_log:
        config['logFile'] = None
        
    if args.no_archive:
        config['archiveFile'] = None
        
    if args.threads > 0:
        config['threads'] = args.threads
        
    if args.interactive:
        config['interactive'] = True
        
    if args.verbose:
        config['verbose'] = True
    
    # Resolve relative paths to script directory (not CWD)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    for path_key in ('archiveFile', 'logFile', 'outputDir'):
        val = config.get(path_key)
        if val and not os.path.isabs(val):
            config[path_key] = os.path.join(script_dir, val)
        
    # Show configs
    console.print("── Configuration ────────────────────────────", style="cyan")
    console.print(f"   Config:  {args.config if args.config else 'terabox-dl.config.json'}", style="grey50")
    console.print(f"   Env:     {env_file if os.path.exists(env_file) else '(none found)'}", style="grey50")
    console.print(f"   Log:     {config['logFile'] if config['logFile'] else '(disabled)'}", style="grey50")
    console.print("")
    
    # Cookie verification
    if not config.get('ndusCookie'):
        console.print("[red]✗ No ndus cookie provided![/red]")
        console.print("\nYou must provide your TeraBox session cookie. Options:", style="yellow")
        console.print(f"  1) Add it to the .env file:  TERABOX_NDUS=your_value", style="grey50")
        console.print(f"  2) Pass --ndus 'your_value'", style="grey50")
        console.print(f"  3) Set environment variable TERABOX_NDUS = 'your_value'", style="grey50")
        console.print("\nTo get your ndus cookie:", style="yellow")
        console.print("  1. Log in at https://www.terabox.com", style="grey50")
        console.print("  2. Open DevTools (F12) → Application → Cookies", style="grey50")
        console.print("  3. Copy the 'ndus' value from terabox.com", style="grey50")
        sys.exit(1)
        
    # Initialize Log
    if config['logFile']:
        write_log_entry(config['logFile'], "INFO", file_name="(session init)")
        
    # Initialize requests session
    session = requests.Session()
    session.cookies.set('ndus', config['ndusCookie'], domain='.terabox.com')
    session.cookies.set('lang', 'en', domain='.terabox.com')
    
    # Resolve output directory
    resolved_output_dir = config.get('outputDir', 'Downloads')
    if not os.path.isabs(resolved_output_dir):
        resolved_output_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), resolved_output_dir)
    resolved_output_dir = os.path.abspath(resolved_output_dir)
    
    # Verify write access/fallback
    drive, _ = os.path.splitdrive(resolved_output_dir)
    if drive and not os.path.exists(drive):
        fallback_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Downloads")
        console.print(f"[yellow]⚠ Configured output directory points to a non-existent drive '{drive}'.[/yellow]")
        console.print(f"  Falling back to script directory: {fallback_dir}")
        resolved_output_dir = fallback_dir

    # Core processing function for a single URL or file input
    def process_url_input(url_input, list_only=False):
        global js_token
        shutdown_event.clear()
        
        # Parse URLs from input
        urls_to_process = []
        if os.path.isfile(url_input):
            try:
                with open(url_input, 'r', encoding='utf-8') as f:
                    for line in f:
                        m = re.search(r'https?://[^\s"\'<>]+', line)
                        if m:
                            urls_to_process.append(m.group(0))
                if not urls_to_process:
                    console.print(f"[red]✗ No valid URLs found in file: {url_input}[/red]")
                    return
                console.print(f"📄 Batch Mode: Found {len(urls_to_process)} URLs in file: {url_input}", style="green")
                console.print("")
            except Exception as e:
                console.print(f"[red]✗ Error reading URLs from file: {e}[/red]")
                return
        else:
            m = re.search(r'https?://[^\s"\'<>]+', url_input)
            if m:
                urls_to_process.append(m.group(0))
            else:
                urls_to_process.append(url_input)
        
        if not list_only:
            os.makedirs(resolved_output_dir, exist_ok=True)
            console.print(f"📂 Output: {resolved_output_dir}", style="grey50")
            
        if list_only:
            console.print("── File Listing (no download) ────────────────", style="cyan")
        else:
            console.print("── Downloading ──────────────────────────────", style="cyan")
            
        stats['StartTime'] = time.time()
        stats['Downloaded'] = 0
        stats['Skipped'] = 0
        stats['Failed'] = 0
        stats['TotalBytes'] = 0
        stats['TotalFiles'] = 0
        download_queue.clear()
        
        # Pre-filter: remove archived URLs before any network calls
        if config['archiveFile']:
            filtered_urls = []
            for u in urls_to_process:
                try:
                    key = get_short_url_key(u)
                    if test_is_key_archived(key, config['archiveFile']):
                        console.print(f"⊘ Archived (skipping): {key}", style="green")
                    else:
                        filtered_urls.append(u)
                except Exception:
                    filtered_urls.append(u)
            urls_to_process = filtered_urls
            
        if not urls_to_process:
            console.print("\n[green]✓ All URLs already archived. Nothing to do.[/green]")
            return
        
        # Traverse phase
        url_idx = 1
        total_urls = len(urls_to_process)
        
        for current_url in urls_to_process:
            if shutdown_event.is_set():
                break
            if total_urls > 1:
                console.print(f"\n[Link {url_idx}/{total_urls}] Processing: {current_url}", style="cyan")
                
            try:
                short_url_key = get_short_url_key(current_url)
                    
                console.print(f"🔗 Share key: {short_url_key}", style="grey50")
                
                # Fetch jsToken if not loaded
                if not js_token:
                    js_token = get_js_token(session, target_url=f"{BASE_URL}/s/{short_url_key}", verbose=config.get('verbose', False))
                    
                share_info = get_share_info(session, short_url_key, config)
                file_list = share_info.get('FileList', [])
                
                # Interactive selection
                if config.get('interactive') and file_list:
                    console.print("\n[bold cyan]Select files to download:[/bold cyan]")
                    for i, item in enumerate(file_list, start=1):
                        name = item.get('server_filename')
                        disp_name = truncate_filename(name, 45)
                        is_dir = is_item_dir(item)
                        type_prefix = "📁" if is_dir else "📄"
                        size_str = f" ({format_file_size(int(item.get('size', 0)))})" if not is_dir else ""
                        console.print(f"  [[bold green]{i}[/bold green]] {type_prefix} {disp_name}{size_str}")
                        
                    sel_input = console.input("\nEnter selection (e.g. 1,3,5-8 or press Enter for all): ")
                    selected_indices = parse_selection(sel_input, len(file_list))
                    
                    if not selected_indices:
                        console.print("[yellow]⚠ No valid items selected. Skipping this URL.[/yellow]")
                        url_idx += 1
                        continue
                    file_list = [file_list[idx] for idx in selected_indices]
                    
                # Process & Traverse folder trees
                total_files = len([x for x in file_list if not is_item_dir(x)])
                total_folders = len([x for x in file_list if is_item_dir(x)])
                total_size = sum([int(x.get('size', 0)) for x in file_list if not is_item_dir(x)])
                
                console.print(f"   Contents: {total_files} files, {total_folders} folders ({format_file_size(total_size)})", style="grey50")
                
                invoke_process_items(
                    items=file_list,
                    dest_dir=resolved_output_dir,
                    session=session,
                    share_id=share_info['ShareId'],
                    uk=share_info['Uk'],
                    sign=share_info['Sign'],
                    timestamp=share_info['Timestamp'],
                    randsk=share_info['Randsk'],
                    url=current_url,
                    list_only=list_only,
                    config=config
                )
            except Exception as e:
                console.print(f"[red]✗ Failed to process URL {current_url}: {e}[/red]")
                
            url_idx += 1
            
        # Download Execution Phase
        if not list_only and download_queue:
            threads = config['threads']
            results = []
            
            if len(download_queue) == 1 or threads <= 1:
                try:
                    with Progress(
                        TextColumn("[bold blue]{task.description}"),
                        BarColumn(bar_width=20),
                        "[progress.percentage]{task.percentage:>3.0f}%",
                        DownloadColumn(),
                        TransferSpeedColumn(),
                        TimeRemainingColumn(),
                    ) as progress:
                        for item in download_queue:
                            if shutdown_event.is_set():
                                break
                            file_name = get_safe_filename(item['FileItem'].get('server_filename'))
                            disp_name = truncate_filename(file_name, 35)
                            file_size = int(item['FileItem'].get('size', 0))
                            task_id = progress.add_task(f"[cyan]↓ DL: {disp_name}[/cyan]", total=file_size, visible=True)
                            res = download_file_worker(item, session, HEADERS, config, progress, task_id)
                            results.append(res)
                except KeyboardInterrupt:
                    shutdown_event.set()
                    console.print("\n[red]✗ Download interrupted by user (Ctrl+C). Partial files are resumable.[/red]")
            else:
                console.print(f"\n⚡ Downloading {len(download_queue)} files in parallel (Threads: {threads})...", style="cyan")
                
                try:
                    with Progress(
                        TextColumn("[bold blue]{task.description}"),
                        BarColumn(bar_width=20),
                        "[progress.percentage]{task.percentage:>3.0f}%",
                        DownloadColumn(),
                        TransferSpeedColumn(),
                        TimeRemainingColumn(),
                    ) as progress:
                        futures = {}
                        with ThreadPoolExecutor(max_workers=threads) as executor:
                            for item in download_queue:
                                file_name = get_safe_filename(item['FileItem'].get('server_filename'))
                                disp_name = truncate_filename(file_name, 35)
                                file_size = int(item['FileItem'].get('size', 0))
                                
                                task_id = progress.add_task(f"[cyan]↓ Queued: {disp_name}[/cyan]", total=file_size, visible=False)
                                future = executor.submit(download_file_worker, item, session, HEADERS, config, progress, task_id)
                                futures[future] = item
                                
                            for future in as_completed(futures):
                                if shutdown_event.is_set():
                                    break
                                res = future.result()
                                results.append(res)
                except KeyboardInterrupt:
                    shutdown_event.set()
                    console.print("\n[red]✗ Download interrupted by user (Ctrl+C). Partial files are resumable.[/red]")
                    for f in futures:
                        f.cancel()
                        
            # Post-process logs and stats
            for res in results:
                if not res:
                    continue
                if res['Status'] == "SUCCESS":
                    stats['Downloaded'] += 1
                    stats['TotalBytes'] += res['Bytes']
                    speed_str = format_file_size(res['SpeedBytes']) + "/s" if res.get('SpeedBytes') else "unknown"
                    dur_str = format_duration(res['DurationSec']) if res.get('DurationSec') else "unknown"
                    write_log_entry(
                        config['logFile'], "SUCCESS", share_url=res['ShareUrl'], file_name=res['FileName'],
                        file_size=res['FileSize'], downloaded_bytes=res['Bytes'], speed=speed_str,
                        duration=dur_str, output_path=res['OutputPath']
                    )
                elif res['Status'] == "SKIPPED":
                    stats['Skipped'] += 1
                    write_log_entry(
                        config['logFile'], "SKIPPED", share_url=res['ShareUrl'], file_name=res['FileName'],
                        file_size=res['FileSize'], output_path=res['OutputPath']
                    )
                else:
                    stats['Failed'] += 1
                    write_log_entry(
                        config['logFile'], "FAILED", share_url=res['ShareUrl'], file_name=res['FileName'],
                        file_size=res['FileSize'], error_message=res.get('ErrorMessage', 'Unknown')
                    )
                    
            # Archive completed share keys (only if not interrupted)
            if not shutdown_event.is_set() and results:
                from collections import defaultdict
                grouped = defaultdict(list)
                for res in results:
                    grouped[res['ShareUrl']].append(res)
                    
                for share_url, group in grouped.items():
                    failed_count = len([x for x in group if x['Status'] == 'FAILED'])
                    if failed_count == 0:
                        try:
                            key = get_short_url_key(share_url)
                            add_key_to_archive(key, config['archiveFile'])
                            console.print(f"✓ Added to archive database: {key}", style="green")
                        except Exception:
                            pass

        # Summary
        elapsed = time.time() - stats['StartTime']
        console.print("")
        console.print("══════════════════════════════════════════════", style="cyan")
        
        if list_only:
            console.print(f"✓ Listing complete. ({stats['TotalFiles']} files found)", style="green")
        else:
            console.print("── Summary ──────────────────────────────────", style="cyan")
            console.print(f"   Downloaded: {stats['Downloaded']} files ({format_file_size(stats['TotalBytes'])})", style="green")
            if stats['Skipped'] > 0:
                console.print(f"   Skipped:    {stats['Skipped']} files (already existed)", style="grey50")
            if stats['Failed'] > 0:
                console.print(f"   Failed:     {stats['Failed']} files", style="red")
                
            console.print(f"   Duration:   {format_duration(elapsed)}")
            if elapsed > 0 and stats['TotalBytes'] > 0:
                console.print(f"   Avg Speed:  {format_file_size(stats['TotalBytes'] / elapsed)}/s")
            console.print(f"   Saved to:   {resolved_output_dir}", style="grey50")
            
            if config['logFile']:
                console.print(f"   Log file:   {config['logFile']}", style="grey50")
                
        console.print("══════════════════════════════════════════════", style="cyan")
        
        if log_file := config.get('logFile'):
            summary_msg = f"(session complete: {stats['Downloaded']} ok, {stats['Skipped']} skipped, {stats['Failed']} failed)"
            write_log_entry(log_file, "INFO", share_url=url_input, file_name=summary_msg, downloaded_bytes=stats['TotalBytes'], duration=format_duration(elapsed))
            
        if shutdown_event.is_set():
            console.print("\n⚠ Session interrupted. Partial files are saved and resumable.", style="yellow")
        elif not list_only and stats['Failed'] > 0:
            console.print("\n⚠ Some files failed. Re-run the same command to retry/resume.", style="yellow")
        elif not list_only:
            console.print("✓ All downloads complete!", style="green")
    
    # ── Execution mode ─────────────────────────────────────────────────
    if args.url:
        # Single-shot mode: process the provided URL/file and exit
        process_url_input(args.url, list_only=args.list_only)
    else:
        # Interactive loop mode
        console.print("── Interactive Mode ──────────────────────────", style="cyan")
        console.print("   Enter a URL or path to a text file to begin.", style="grey50")
        console.print("   Press [bold]Ctrl+C[/bold] or type [bold]exit[/bold] to quit.", style="grey50")
        console.print("")
        
        while True:
            try:
                url_input = console.input("[bold cyan]Enter URL: [/bold cyan]").strip()
            except (KeyboardInterrupt, EOFError):
                console.print("\n[grey50]Goodbye![/grey50]")
                break
                
            if not url_input or url_input.lower() in ('exit', 'quit', 'q'):
                console.print("[grey50]Goodbye![/grey50]")
                break
                
            process_url_input(url_input, list_only=args.list_only)
            console.print("")

if __name__ == "__main__":
    if os.name == 'nt':
        import ctypes
        def _win_ctrl_handler(ctrl_type):
            if ctrl_type in (0, 1): # CTRL_C_EVENT, CTRL_BREAK_EVENT
                console.print("\n[red]✗ Interrupted by user.[/red]")
                os._exit(130)
            return True
        
        # Keep reference to handler callback to prevent garbage collection
        _handler_prototype = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_uint)
        _win_handler_ref = _handler_prototype(_win_ctrl_handler)
        ctypes.windll.kernel32.SetConsoleCtrlHandler(_win_handler_ref, True)
    else:
        def _sigint_handler(sig, frame):
            shutdown_event.set()
            console.print("\n[red]✗ Interrupted by user.[/red]")
            sys.exit(130)
        signal.signal(signal.SIGINT, _sigint_handler)
        
    try:
        main()
    except KeyboardInterrupt:
        shutdown_event.set()
        console.print("\n[red]✗ Interrupted by user.[/red]")
        sys.exit(130)
    except SystemExit:
        raise
    except Exception as e:
        console.print(f"\n[red]✗ Fatal error: {e}[/red]")
        sys.exit(1)
