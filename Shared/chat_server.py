#!/usr/bin/env python3
"""
Portable AI Chat Server
=======================
A zero-dependency Python HTTP server that:
  1. Serves the FastChatUI.html web interface
  2. Saves/loads chat history as JSON files on the USB drive
  3. Proxies all Ollama API requests (eliminates CORS issues)

Works on Windows, macOS, and Linux without installing anything.
"""

import http.server
import json
import os
import sys
import urllib.request
import urllib.error
import threading
import webbrowser
import time
import platform
import ctypes
import logging
import logging.handlers
import queue
import uuid
from datetime import datetime
from urllib.parse import urlparse

# Optional: psutil for hardware stats (graceful fallback to native APIs if not installed)
try:
    import psutil
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False

# ── Configuration ──────────────────────────────────────────────
CHAT_SERVER_PORT = 3333
OLLAMA_HOST = "http://127.0.0.1:11434"
LLAMA_CPP_MODE = "--llama-cpp" in sys.argv
if LLAMA_CPP_MODE:
    OLLAMA_HOST = "http://127.0.0.1:8080"

# Always resolve paths relative to THIS script's location (the USB drive)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CHATS_DIR = os.path.join(SCRIPT_DIR, "chat_data")
CHATS_FILE = os.path.join(CHATS_DIR, "chats.json")
SETTINGS_FILE = os.path.join(CHATS_DIR, "settings.json")
HTML_FILE = os.path.join(SCRIPT_DIR, "FastChatUI.html")
LOG_DIR = os.path.join(SCRIPT_DIR, "logs")
LOG_FILE = os.path.join(LOG_DIR, "chat_server.log")
LOG_MODE_ERRORS_ONLY = "errors_only"
LOG_MODE_ALL = "all"
DEFAULT_LOG_MODE = LOG_MODE_ERRORS_ONLY

# Lock shared file persistence paths to avoid concurrent write corruption.
DATA_FILE_LOCK = threading.RLock()
LOG_MODE_LOCK = threading.RLock()
ACTIVE_LOG_MODE = DEFAULT_LOG_MODE

# ── Pure-Python Hardware Stats (no psutil needed) ──────────────
_cpu_times_last = None  # (idle, total) from previous sample

def _get_hw_stats():
    """Return (cpu_percent, ram_percent) using only stdlib / ctypes."""
    global _cpu_times_last  # must be at top of function, before any branch uses it

    if HAS_PSUTIL:
        cpu = round(psutil.cpu_percent(interval=0.25), 1)
        ram = round(psutil.virtual_memory().percent, 1)
        return cpu, ram

    plat = platform.system()

    # ── Windows ──────────────────────────────────────────────────
    if plat == "Windows":
        # RAM via GlobalMemoryStatusEx
        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength",                ctypes.c_ulong),
                ("dwMemoryLoad",            ctypes.c_ulong),
                ("ullTotalPhys",            ctypes.c_ulonglong),
                ("ullAvailPhys",            ctypes.c_ulonglong),
                ("ullTotalPageFile",        ctypes.c_ulonglong),
                ("ullAvailPageFile",        ctypes.c_ulonglong),
                ("ullTotalVirtual",         ctypes.c_ulonglong),
                ("ullAvailVirtual",         ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]
        msx = MEMORYSTATUSEX()
        msx.dwLength = ctypes.sizeof(msx)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(msx))
        ram = float(msx.dwMemoryLoad)

        # CPU via GetSystemTimes (idle/kernel/user tick counts)
        FILETIME = ctypes.c_ulonglong
        idle, kern, user = FILETIME(), FILETIME(), FILETIME()
        ctypes.windll.kernel32.GetSystemTimes(
            ctypes.byref(idle), ctypes.byref(kern), ctypes.byref(user))
        idle_v = idle.value
        total_v = kern.value + user.value
        if _cpu_times_last is None:
            # First call — sleep briefly and sample again
            time.sleep(0.25)
            idle2, kern2, user2 = FILETIME(), FILETIME(), FILETIME()
            ctypes.windll.kernel32.GetSystemTimes(
                ctypes.byref(idle2), ctypes.byref(kern2), ctypes.byref(user2))
            d_idle  = idle2.value - idle_v
            d_total = (kern2.value + user2.value) - total_v
            _cpu_times_last = (idle2.value, kern2.value + user2.value)
        else:
            prev_idle, prev_total = _cpu_times_last
            d_idle  = idle_v  - prev_idle
            d_total = total_v - prev_total
            _cpu_times_last = (idle_v, total_v)

        cpu = round((1.0 - d_idle / max(d_total, 1)) * 100.0, 1)
        cpu = max(0.0, min(100.0, cpu))
        return cpu, ram

    # ── Linux ─────────────────────────────────────────────────────
    elif plat == "Linux":
        # RAM
        ram = 0.0
        try:
            with open("/proc/meminfo") as f:
                mem = {}
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2:
                        mem[parts[0].rstrip(":")] = int(parts[1])
            total = mem.get("MemTotal", 1)
            avail = mem.get("MemAvailable", total)
            ram = round((1 - avail / total) * 100, 1)
        except Exception:
            pass
        # CPU via /proc/stat delta
        cpu = 0.0
        try:
            def read_cpu():
                with open("/proc/stat") as f:
                    parts = f.readline().split()
                vals = [int(x) for x in parts[1:]]
                idle = vals[3]
                total = sum(vals)
                return idle, total
            if _cpu_times_last is None:
                i1, t1 = read_cpu()
                time.sleep(0.25)
                i2, t2 = read_cpu()
            else:
                i1, t1 = _cpu_times_last
                i2, t2 = read_cpu()
            _cpu_times_last = (i2, t2)
            d_idle  = i2 - i1
            d_total = t2 - t1
            cpu = round((1 - d_idle / max(d_total, 1)) * 100, 1)
        except Exception:
            pass
        return cpu, ram

    # ── macOS ─────────────────────────────────────────────────────
    else:
        # User requested to skip macOS usage to avoid any potential permission/execution issues
        cpu = 0.0
        ram = 0.0
        return cpu, ram

def _safe_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default

def _normalize_log_mode(value):
    if value == LOG_MODE_ALL:
        return LOG_MODE_ALL
    return LOG_MODE_ERRORS_ONLY

def _is_log_enabled(level):
    with LOG_MODE_LOCK:
        mode = ACTIVE_LOG_MODE
    if mode == LOG_MODE_ALL:
        return True
    return level >= logging.ERROR

def _load_settings_file():
    default_settings = {
        "globalSystemPrompt": "",
        "temperature": 0.7,
        "logMode": DEFAULT_LOG_MODE,
    }
    try:
        with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
            loaded = json.load(f)
        if isinstance(loaded, dict):
            merged = dict(default_settings)
            merged.update(loaded)
            merged["logMode"] = _normalize_log_mode(merged.get("logMode"))
            return merged
    except Exception:
        pass
    return default_settings

def _persist_settings_file(settings):
    with DATA_FILE_LOCK:
        temp_file = SETTINGS_FILE + ".tmp"
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(settings, f, ensure_ascii=False, indent=2)
            f.flush()
        os.replace(temp_file, SETTINGS_FILE)

def _set_active_log_mode(mode):
    global ACTIVE_LOG_MODE
    with LOG_MODE_LOCK:
        ACTIVE_LOG_MODE = _normalize_log_mode(mode)

def _get_hardware_specs():
    """Collect a stable host hardware snapshot for log enrichment."""
    plat = platform.system()
    specs = {
        "platform": plat,
        "platform_release": platform.release(),
        "platform_version": platform.version(),
        "machine": platform.machine(),
        "processor": platform.processor() or "unknown",
        "python_version": sys.version.split()[0],
        "cpu_count_logical": os.cpu_count() or 0,
        "has_psutil": HAS_PSUTIL,
        "ram_total_gb": None,
    }
    if HAS_PSUTIL:
        try:
            total_ram = psutil.virtual_memory().total
            specs["ram_total_gb"] = round(total_ram / (1024 ** 3), 2)
        except Exception:
            pass
    elif plat == "Windows":
        try:
            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [
                    ("dwLength", ctypes.c_ulong),
                    ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]
            msx = MEMORYSTATUSEX()
            msx.dwLength = ctypes.sizeof(msx)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(msx))
            specs["ram_total_gb"] = round(msx.ullTotalPhys / (1024 ** 3), 2)
        except Exception:
            pass
    elif plat == "Linux":
        try:
            mem = {}
            with open("/proc/meminfo", "r", encoding="utf-8") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2:
                        mem[parts[0].rstrip(":")] = int(parts[1])
            total_kb = mem.get("MemTotal")
            if total_kb:
                specs["ram_total_gb"] = round((total_kb * 1024) / (1024 ** 3), 2)
        except Exception:
            pass
        try:
            with open("/proc/cpuinfo", "r", encoding="utf-8") as f:
                for line in f:
                    if line.lower().startswith("model name"):
                        _, value = line.split(":", 1)
                        model = value.strip()
                        if model:
                            specs["processor"] = model
                            break
        except Exception:
            pass
    else:
        # Keep parity with _get_hw_stats fallback behavior:
        # skip macOS/native probing in the non-psutil path.
        pass
    return specs

class LogFormatter(logging.Formatter):
    """Readable, multi-line formatter with strict spacing and rich context."""

    def format(self, record):
        local_now = datetime.now().astimezone()
        timestamp = local_now.isoformat()
        tz_label = local_now.tzname() or "local"
        exception_text = ""
        if record.exc_info:
            exception_text = self.formatException(record.exc_info)
        hardware = getattr(record, "hardware_specs", None) or {}
        request_headers = getattr(record, "request_headers", None) or {}
        lines = [
            "=" * 96,
            f"timestamp     : {timestamp}",
            f"timezone      : {tz_label}",
            f"level         : {record.levelname}",
            f"event         : {record.getMessage()}",
            "",
            "request_context",
            f"  request_id   : {getattr(record, 'request_id', '-')}",
            f"  method       : {getattr(record, 'http_method', '-')}",
            f"  path         : {getattr(record, 'path', '-')}",
            f"  api_source   : {getattr(record, 'api_source', '-')}",
            f"  client_ip    : {getattr(record, 'client_ip', '-')}",
            f"  user_agent   : {request_headers.get('User-Agent', '-')}",
            f"  model_name   : {getattr(record, 'model_name', '-')}",
            f"  model_temp   : {getattr(record, 'model_temperature', '-')}",
            f"  model_stream : {getattr(record, 'model_stream', '-')}",
            "",
            "code_context",
            f"  logger       : {record.name}",
            f"  module       : {record.module}",
            f"  function     : {record.funcName}",
            f"  line         : {record.lineno}",
            f"  thread       : {record.threadName}",
            "",
            "hardware_specs",
            f"  platform     : {hardware.get('platform', '-')}",
            f"  release      : {hardware.get('platform_release', '-')}",
            f"  machine      : {hardware.get('machine', '-')}",
            f"  processor    : {hardware.get('processor', '-')}",
            f"  cpu_logical  : {hardware.get('cpu_count_logical', '-')}",
            f"  ram_total_gb : {hardware.get('ram_total_gb', '-')}",
            f"  python       : {hardware.get('python_version', '-')}",
        ]
        if exception_text:
            lines.extend(["", "exception", exception_text])
        lines.append("=" * 96)
        return "\n".join(lines)

class ImmediateFlushRotatingFileHandler(logging.handlers.RotatingFileHandler):
    """Flush each record immediately so logs are visible without waiting."""

    def emit(self, record):
        super().emit(record)
        try:
            self.flush()
        except Exception:
            pass

def configure_logging():
    os.makedirs(LOG_DIR, exist_ok=True)
    logger = logging.getLogger("chat_server")
    logger.setLevel(logging.INFO)
    logger.handlers = []
    logger.propagate = False

    log_queue = queue.Queue(maxsize=10000)
    queue_handler = logging.handlers.QueueHandler(log_queue)
    logger.addHandler(queue_handler)

    file_handler = ImmediateFlushRotatingFileHandler(
        LOG_FILE, maxBytes=10 * 1024 * 1024, backupCount=1, encoding="utf-8"
    )
    file_handler.setFormatter(LogFormatter())

    listener = logging.handlers.QueueListener(log_queue, file_handler, respect_handler_level=True)
    listener.start()
    return logger, listener

def _log_event(level, message, request_context=None, exc_info=False):
    if not _is_log_enabled(level):
        return
    request_context = request_context or {}
    LOGGER.log(
        level,
        message,
        extra={
            "request_id": request_context.get("request_id", "-"),
            "http_method": request_context.get("method", "-"),
            "path": request_context.get("path", "-"),
            "api_source": request_context.get("api_source", "-"),
            "client_ip": request_context.get("client_ip", "-"),
            "request_headers": request_context.get("request_headers", {}),
            "model_name": request_context.get("model_name", "-"),
            "model_temperature": request_context.get("model_temperature", "-"),
            "model_stream": request_context.get("model_stream", "-"),
            "hardware_specs": HOST_HARDWARE_SPECS,
        },
        exc_info=exc_info,
    )

def ensure_data_dir():
    """Create required data folders if they don't exist."""
    os.makedirs(CHATS_DIR, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)
    if not os.path.exists(CHATS_FILE):
        with open(CHATS_FILE, "w", encoding="utf-8") as f:
            json.dump([], f)
    if not os.path.exists(SETTINGS_FILE):
        with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "globalSystemPrompt": "",
                    "temperature": 0.7,
                    "logMode": DEFAULT_LOG_MODE,
                },
                f,
            )

class ChatHandler(http.server.BaseHTTPRequestHandler):
    """Handles all HTTP requests for the Portable AI Chat."""

    def _build_request_context(self, api_source):
        headers = {}
        for key in ("User-Agent", "Authorization"):
            value = self.headers.get(key)
            if value:
                headers[key] = value
        return {
            "request_id": str(uuid.uuid4()),
            "method": getattr(self, "command", "-"),
            "path": getattr(self, "path", "-"),
            "api_source": api_source,
            "client_ip": self.client_address[0] if self.client_address else "-",
            "request_headers": headers,
        }

    def _read_body(self):
        length = _safe_int(self.headers.get("Content-Length"), 0)
        return self.rfile.read(length) if length > 0 else b""

    def log_message(self, format, *args):
        """Print all requests for easy debugging."""
        msg = format % args
        ts = time.strftime("%H:%M:%S")
        # Colour-code by status: errors red, warnings yellow, ok green
        if "404" in msg or "500" in msg or "502" in msg:
            prefix = "  \033[91m[ERR]\033[0m"
        elif "200" in msg or "204" in msg:
            prefix = "  \033[92m[ OK]\033[0m"
        else:
            prefix = "  \033[93m[---]\033[0m"
        print(f"{prefix} {ts}  {msg}")

    # ── CORS headers ───────────────────────────────────────────
    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")

    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(204)
        self._cors_headers()
        self.end_headers()

    # ── Routing ────────────────────────────────────────────────
    def do_GET(self):
        path = urlparse(self.path).path

        # Serve the main UI
        if path == "/" or path == "/index.html":
            self._serve_html()

        # Chat data API
        elif path == "/api/chats":
            self._get_chats()

        # Settings API
        elif path == "/api/settings":
            self._get_settings()

        # Hardware stats API
        elif path == "/api/stats":
            self._get_stats()

        # Proxy Ollama API
        elif path.startswith("/ollama/"):
            self._proxy_ollama("GET")

        else:
            # Try serving static files from SCRIPT_DIR
            self._serve_static(path)

    def do_POST(self):
        path = urlparse(self.path).path

        if path == "/api/chats":
            self._save_chats()

        elif path == "/api/settings":
            self._save_settings()

        # Proxy Ollama API
        elif path.startswith("/ollama/"):
            self._proxy_ollama("POST")

        else:
            self.send_response(404)
            self._cors_headers()
            self.end_headers()

    def do_DELETE(self):
        path = urlparse(self.path).path
        if path.startswith("/ollama/"):
            self._proxy_ollama("DELETE")
        else:
            self.send_response(404)
            self._cors_headers()
            self.end_headers()

    # ── Serve HTML ─────────────────────────────────────────────
    def _serve_html(self):
        try:
            with open(HTML_FILE, "rb") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self._cors_headers()
            self.end_headers()
            self.wfile.write(content)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"FastChatUI.html not found.")

    def _serve_static(self, path):
        """Serve static files (CSS, JS, images) from SCRIPT_DIR."""
        safe_path = os.path.normpath(path.lstrip("/"))
        full_path = os.path.join(SCRIPT_DIR, safe_path)

        # Security: don't allow path traversal
        if not full_path.startswith(SCRIPT_DIR):
            self.send_response(403)
            self.end_headers()
            return

        if os.path.isfile(full_path):
            ext = os.path.splitext(full_path)[1].lower()
            mime_types = {
                ".html": "text/html", ".css": "text/css", ".js": "application/javascript",
                ".json": "application/json", ".png": "image/png", ".jpg": "image/jpeg",
                ".svg": "image/svg+xml", ".ico": "image/x-icon"
            }
            content_type = mime_types.get(ext, "application/octet-stream")
            with open(full_path, "rb") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self._cors_headers()
            self.end_headers()
            self.wfile.write(content)
        else:
            self.send_response(404)
            self.end_headers()

    # ── Chat Persistence ───────────────────────────────────────
    def _get_chats(self):
        request_context = self._build_request_context("/api/chats")
        try:
            with DATA_FILE_LOCK:
                with open(CHATS_FILE, "r", encoding="utf-8") as f:
                    data = f.read()
        except (FileNotFoundError, json.JSONDecodeError):
            data = "[]"
        except Exception:
            _log_event(logging.ERROR, "Failed to read chats file", request_context=request_context, exc_info=True)
            data = "[]"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(data.encode("utf-8"))

    def _save_chats(self):
        request_context = self._build_request_context("/api/chats")
        body = self._read_body()
        try:
            chats = json.loads(body)
            with DATA_FILE_LOCK:
                temp_file = CHATS_FILE + ".tmp"
                with open(temp_file, "w", encoding="utf-8") as f:
                    json.dump(chats, f, ensure_ascii=False, indent=2)
                    f.flush()
                os.replace(temp_file, CHATS_FILE)
            _log_event(logging.INFO, "Chats saved successfully", request_context=request_context)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self._cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({"ok": True}).encode())
        except Exception as e:
            _log_event(logging.ERROR, "Failed to save chats", request_context=request_context, exc_info=True)
            self.send_response(500)
            self._cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode())

    def _get_settings(self):
        request_context = self._build_request_context("/api/settings")
        try:
            settings = _load_settings_file()
            data = json.dumps(settings)
        except Exception:
            _log_event(logging.ERROR, "Failed to read settings file", request_context=request_context, exc_info=True)
            data = "{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(data.encode("utf-8"))

    def _save_settings(self):
        request_context = self._build_request_context("/api/settings")
        body = self._read_body()
        try:
            incoming = json.loads(body)
            if not isinstance(incoming, dict):
                raise ValueError("Settings payload must be a JSON object")

            settings = _load_settings_file()
            settings.update(incoming)
            settings["logMode"] = _normalize_log_mode(settings.get("logMode"))
            _persist_settings_file(settings)
            _set_active_log_mode(settings["logMode"])
            _log_event(logging.INFO, "Settings saved successfully", request_context=request_context)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self._cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({"ok": True, "logMode": settings["logMode"]}).encode())
        except Exception as e:
            _log_event(logging.ERROR, "Failed to save settings", request_context=request_context, exc_info=True)
            self.send_response(500)
            self._cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode())

    # ── Hardware Stats ─────────────────────────────────────────
    def _get_stats(self):
        """Return CPU % and RAM % as JSON. Works with no external packages."""
        try:
            cpu, ram = _get_hw_stats()
            data = json.dumps({"cpu_percent": cpu, "ram_percent": ram, "has_psutil": HAS_PSUTIL})
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self._cors_headers()
            self.end_headers()
            self.wfile.write(data.encode())
        except Exception as e:
            _log_event(
                logging.ERROR,
                "Failed to collect hardware stats",
                request_context=self._build_request_context("/api/stats"),
                exc_info=True,
            )
            self.send_response(500)
            self._cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode())

    # ── Ollama Proxy (streaming-aware) ─────────────────────────
    def _proxy_ollama(self, method):
        """
        Proxy requests from /ollama/* to the local Ollama engine.
        Supports streaming responses for /api/chat and /api/generate.
        """
        request_context = self._build_request_context("/ollama")
        # Strip the /ollama prefix to get the real Ollama path
        ollama_path = self.path[len("/ollama"):]
        target_url = OLLAMA_HOST + ollama_path

        # Read request body if present
        body = None
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length > 0:
            body = self.rfile.read(content_length)
        payload = {}
        if body:
            try:
                payload = json.loads(body)
            except Exception:
                payload = {}

        if isinstance(payload, dict):
            request_context["model_name"] = payload.get("model", "-")
            request_context["model_stream"] = payload.get("stream", "-")
            request_context["model_temperature"] = payload.get("options", {}).get("temperature", "-")

        try:
            # Handle fake /api/tags for llama.cpp mode
            if LLAMA_CPP_MODE and ollama_path == "/api/tags":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self._cors_headers()
                self.end_headers()
                self.wfile.write(json.dumps({"models":[{"name": "local-llama-model"}]}).encode())
                return

            if LLAMA_CPP_MODE and ollama_path == "/api/chat":
                # Translate Ollama payload -> OpenAI payload for llama-server
                ollama_req = json.loads(body) if body else {}
                openai_req = {
                    "messages": ollama_req.get("messages", []),
                    "stream": True,
                    "temperature": ollama_req.get("options", {}).get("temperature", 0.7)
                }
                target_url = OLLAMA_HOST + "/v1/chat/completions"
                body = json.dumps(openai_req).encode()

            req = urllib.request.Request(
                target_url,
                data=body,
                method=method,
                headers={"Content-Type": self.headers.get("Content-Type", "application/json")}
            )

            # Optional: pass Authorization header if present
            if "Authorization" in self.headers:
                req.add_header("Authorization", self.headers.get("Authorization"))

            response = urllib.request.urlopen(req, timeout=600)

            # Send response headers
            self.send_response(response.status)
            is_stream = ("/api/chat" in ollama_path or "/api/generate" in ollama_path)

            for header, value in response.getheaders():
                lower = header.lower()
                if lower not in ("transfer-encoding", "connection", "content-length"):
                    self.send_header(header, value)

            self._cors_headers()
            self.end_headers()
            if method == "POST" and ("/api/chat" in ollama_path or "/api/generate" in ollama_path):
                _log_event(
                    logging.INFO,
                    f"Model request succeeded with upstream status {response.status}",
                    request_context=request_context,
                )

            # Stream the response in chunks
            while True:
                chunk = response.read(4096)
                if not chunk:
                    break
                
                # If bridging llama.cpp SSE to Ollama JSONL
                if LLAMA_CPP_MODE and is_stream:
                    text = chunk.decode(errors="ignore")
                    lines = text.split("\n")
                    for line in lines:
                        if line.startswith("data: "):
                            data = line[6:].strip()
                            if data == "[DONE]":
                                break
                            try:
                                j = json.loads(data)
                                if "choices" in j and len(j["choices"]) > 0:
                                    delta = j["choices"][0].get("delta", {})
                                    out = {
                                        "message": {"role": "assistant", "content": delta.get("content", "")},
                                        "done": False
                                    }
                                    try:
                                        self.wfile.write((json.dumps(out) + "\n").encode())
                                        self.wfile.flush()
                                    except (BrokenPipeError, ConnectionResetError, OSError):
                                        _log_event(
                                            logging.ERROR,
                                            "Client disconnected while streaming response",
                                            request_context=request_context,
                                            exc_info=True,
                                        )
                                        return
                            except:
                                pass
                else:
                    try:
                        self.wfile.write(chunk)
                        if is_stream:
                            self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        _log_event(
                            logging.ERROR,
                            "Client disconnected while streaming response",
                            request_context=request_context,
                            exc_info=True,
                        )
                        return

        except urllib.error.HTTPError as e:
            _log_event(
                logging.ERROR,
                f"Upstream HTTP error from Ollama: {e.code}",
                request_context=request_context,
                exc_info=True,
            )
            self.send_response(e.code)
            self._cors_headers()
            self.end_headers()
            try:
                self.wfile.write(e.read())
            except:
                pass

        except urllib.error.URLError as e:
            _log_event(
                logging.ERROR,
                "Failed to reach Ollama upstream",
                request_context=request_context,
                exc_info=True,
            )
            self.send_response(502)
            self._cors_headers()
            self.end_headers()
            msg = json.dumps({"error": f"Cannot reach Ollama engine: {str(e.reason)}"})
            self.wfile.write(msg.encode())

        except Exception as e:
            _log_event(
                logging.ERROR,
                "Unhandled proxy error",
                request_context=request_context,
                exc_info=True,
            )
            self.send_response(500)
            self._cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode())


class ThreadedHTTPServer(http.server.HTTPServer):
    """Handle each request in a new thread for concurrent streaming."""
    def process_request(self, request, client_address):
        thread = threading.Thread(target=self._handle, args=(request, client_address))
        thread.daemon = True
        thread.start()

    def _handle(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)

HOST_HARDWARE_SPECS = _get_hardware_specs()
LOGGER, LOG_LISTENER = configure_logging()

def open_browser_delayed():
    """Open the browser after a short delay to ensure server is ready."""
    time.sleep(1.0)
    webbrowser.open(f"http://localhost:{CHAT_SERVER_PORT}")

def main():
    ensure_data_dir()
    _set_active_log_mode(_load_settings_file().get("logMode"))
    
    # Try to find the local LAN IP
    local_ip = "127.0.0.1"
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        local_ip = s.getsockname()[0]
        s.close()
    except Exception:
        pass

    print()
    print("=" * 55)
    print("  Portable AI — Chat Server")
    print("=" * 55)
    print()
    print(f"  Local Access:    http://localhost:{CHAT_SERVER_PORT}")
    print(f"  Network Access:  http://{local_ip}:{CHAT_SERVER_PORT}   <-- Use this on phone/other PC!")
    print(f"  Ollama/Llama Proxy: {OLLAMA_HOST}")
    if LLAMA_CPP_MODE:
        print("  Running in LLAMA_CPP_MODE (Translating API requests)")
    print()
    print("  All chats auto-save to the USB drive!")
    print("  Press Ctrl+C to shut down.")
    print()
    print("-" * 55)

    server = ThreadedHTTPServer(("0.0.0.0", CHAT_SERVER_PORT), ChatHandler)

    # Open browser in background thread
    if "--no-browser" not in sys.argv:
        threading.Thread(target=open_browser_delayed, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Shutting down chat server...")
        server.shutdown()
        print("  Goodbye!")
    finally:
        try:
            LOG_LISTENER.stop()
        except Exception:
            pass

if __name__ == "__main__":
    main()
