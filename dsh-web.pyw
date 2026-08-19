#!/usr/bin/env python3
"""
GUI launcher for DeepSeek Harness Web UI — a small tkinter front-end.
Double-click to configure host/port/trusted-hosts and start/stop the dsh web
service. Settings persist in .dsh-web-launcher-config.json next to the script.

Requires: Python 3.10+ (bundled tkinter), Node.js >= 22.19, project checkout.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
import webbrowser
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk

PROJECT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = PROJECT_DIR / ".dsh-web-launcher-config.json"
DSH_ENTRY = PROJECT_DIR / "apps" / "cli" / "src" / "bin.ts"

DEFAULTS = {"host": "127.0.0.1", "port": "34567", "trustedHosts": ""}


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        return dict(DEFAULTS)
    try:
        data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        return {**DEFAULTS, **{k: v for k, v in data.items() if k in DEFAULTS}}
    except Exception:
        return dict(DEFAULTS)


def find_node() -> str:
    """Return an absolute path to a Node binary (>= 22.19), or None."""
    candidates = [
        PROJECT_DIR / ".dsh" / "node" / "node.exe",
        Path.home() / ".dsh" / "node" / "node.exe",
    ]
    for cand in candidates:
        if cand.is_file():
            return str(cand)
    # PATH fallback
    for path in os.environ.get("PATH", "").split(os.pathsep):
        exe = os.path.join(path, "node.exe")
        if os.path.isfile(exe):
            return exe
    return None


def node_supports_zstd(node: str) -> bool:
    try:
        out = subprocess.run(
            [node, "-e", "process.stdout.write(typeof require('node:zlib').createZstdDecompress)"],
            capture_output=True, text=True, timeout=10,
        )
        return out.stdout.strip() == "function"
    except Exception:
        return False


class Launcher:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.config = load_config()
        self.node = find_node()
        self.proc: subprocess.Popen | None = None
        self.server_url = ""
        self._polling = False

        self.node_status = ""
        if self.node is None:
            self.node_status = "Node.js not found on PATH"
        elif not node_supports_zstd(self.node):
            self.node_status = "Node.js too old (need >= 22.19)"
        else:
            self.node_status = f"OK ({Path(self.node).name})"

        self._build_ui()
        self._update_status("Ready", "gray")

    # ── UI ──────────────────────────────────────────────────────────────────
    def _build_ui(self) -> None:
        self.root.title("dsh Web Launcher")
        self.root.resizable(False, False)
        pad = {"padx": 12, "pady": 8}

        frame = ttk.Frame(self.root, padding=12)
        frame.grid(row=0, column=0, sticky="nsew")

        # Row 1 — host
        ttk.Label(frame, text="Host:").grid(row=0, column=0, sticky="e")
        self.host_var = tk.StringVar(value=self.config["host"])
        ttk.Entry(frame, textvariable=self.host_var, width=30).grid(row=0, column=1, sticky="we", padx=(6, 0))

        # Row 2 — port
        ttk.Label(frame, text="Port:").grid(row=1, column=0, sticky="e", pady=(6, 0))
        self.port_var = tk.StringVar(value=self.config["port"])
        ttk.Entry(frame, textvariable=self.port_var, width=10).grid(row=1, column=1, sticky="w", padx=(6, 0), pady=(6, 0))

        # Row 3 — trusted hosts
        ttk.Label(frame, text="Trusted:").grid(row=2, column=0, sticky="e", pady=(6, 0))
        self.trusted_var = tk.StringVar(value=self.config["trustedHosts"])
        ttk.Entry(frame, textvariable=self.trusted_var, width=30).grid(row=2, column=1, sticky="we", padx=(6, 0), pady=(6, 0))

        # Hint
        hint = ttk.Label(
            frame,
            text="0.0.0.0 = all interfaces (LAN)\nspace-separate multiple Trusted Hosts",
            foreground="gray",
        )
        hint.grid(row=3, column=0, columnspan=2, sticky="w", pady=(8, 4))

        # Node status line
        ttk.Label(
            frame,
            text=f"node: {self.node_status}",
            foreground="darkorange" if self.node_status.startswith("OK") else "red",
        ).grid(row=4, column=0, columnspan=2, sticky="w")

        # Status / URL line
        self.status_var = tk.StringVar(value="Ready")
        self.status_lbl = ttk.Label(frame, textvariable=self.status_var, foreground="gray")
        self.status_lbl.grid(row=5, column=0, columnspan=2, sticky="w", pady=(8, 0))

        # Start / Stop button
        self.button = ttk.Button(frame, text="Start", command=self.toggle)
        self.button.grid(row=6, column=0, columnspan=2, sticky="we", pady=(10, 0))

        # Center on screen
        self.root.update_idletasks()
        w, h = self.root.winfo_width(), self.root.winfo_height()
        x = (self.root.winfo_screenwidth() - w) // 2
        y = (self.root.winfo_screenheight() - h) // 2
        self.root.geometry(f"+{x}+{y}")

    # ── Actions ─────────────────────────────────────────────────────────────
    def toggle(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            self.stop()
        else:
            self.start()

    def start(self) -> None:
        if self.node is None:
            messagebox.showerror("dsh Web Launcher", "Node.js not found. Install Node.js >= 22.19 (or use ~/.dsh/node).")
            return

        host = self.host_var.get().strip() or "127.0.0.1"
        port = self.port_var.get().strip() or "34567"
        trusted = [h for h in re.split(r"\s+", self.trusted_var.get().strip()) if h]

        if not port.isdigit():
            messagebox.showerror("dsh Web Launcher", f"Invalid port: {port!r}")
            return

        # Remote mode: trusted hosts imply out-of-loopback access (CF tunnel /
        # LAN), which the native OS dialog cannot serve.  Traffic still lands at
        # 127.0.0.1 via the tunnel; the broker picks the in-browser browse
        # backend and the remote client can pick workspaces through the UI.
        actual_host = "0.0.0.0" if trusted else host

        cmd = [
            self.node,
            "--import", "tsx/esm",
            str(DSH_ENTRY),
            "web",
            "--host", actual_host,
            "--port", port,
        ]
        for t in trusted:
            cmd += ["--trusted-host", t]

        # Persist the field values as entered (not the effective host), so the
        # next launch restores user intent and re-applies remote detection.
        self.config = {"host": host, "port": port, "trustedHosts": " ".join(trusted)}
        try:
            CONFIG_PATH.write_text(json.dumps(self.config), encoding="utf-8")
        except Exception:
            pass  # nothing the user can do about it; non-fatal

        try:
            self.proc = subprocess.Popen(
                cmd,
                cwd=str(PROJECT_DIR),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except OSError as e:
            messagebox.showerror("dsh Web Launcher", f"Failed to start: {e}")
            return

        self.server_url = ""
        self._update_status("Starting...", "orange")
        self.button.config(text="Stop")

        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()
        threading.Thread(target=self._monitor_exit, daemon=True).start()

    def stop(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
            # give it a moment, then hard kill if needed
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        self.proc = None
        self.server_url = ""
        self._update_status("Stopped", "gray")
        self.button.config(text="Start")

    # ── Background threads ──────────────────────────────────────────────────
    def _read_stdout(self) -> None:
        proc = self.proc
        if proc is None or proc.stdout is None:
            return
        for line in proc.stdout:
            m = re.search(r"(https?://\S+)", line)
            if m and not self.server_url:
                self.server_url = m.group(1)
                self.root.after(0, self._on_ready)
            if line.strip():
                print(line, end="", flush=True)  # passthrough for debugging
        # EOF
        if proc.poll() is not None and not self.server_url:
            self.root.after(0, self._on_failed)

    def _read_stderr(self) -> None:
        proc = self.proc
        if proc is None or proc.stderr is None:
            return
        for line in proc.stderr:
            if line.strip():
                print(line, end="", file=sys.stderr, flush=True)

    def _monitor_exit(self) -> None:
        proc = self.proc
        if proc is None:
            return
        rc = proc.wait()
        # Only reflect if there's no URL already found (service never came up)
        if not self.server_url:
            self.root.after(0, lambda: self._update_status(f"Exited ({rc})", "red"))
            self.root.after(0, lambda: self.button.config(text="Start"))

    # ── UI updates (main thread via root.after) ─────────────────────────────
    def _on_ready(self) -> None:
        self._update_status(f"Running at {self.server_url}", "green")
        self.button.config(text="Stop")
        webbrowser.open(self.server_url)

    def _on_failed(self) -> None:
        self._update_status("Start failed (see console)", "red")
        self.button.config(text="Start")

    def _update_status(self, text: str, color: str) -> None:
        self.status_var.set(text)
        self.status_lbl.config(foreground=color)


def main() -> None:
    root = tk.Tk()
    try:
        ttk.Style().theme_use("vista")
    except Exception:
        pass
    Launcher(root)
    root.mainloop()


if __name__ == "__main__":
    main()