#!/usr/bin/env python3
"""
Trivy DB Build Monitor Web Application
A Flask-based web interface for monitoring and controlling the Trivy DB build process
"""

import os
import json
import subprocess
import threading
from datetime import datetime
from pathlib import Path
from flask import Flask, render_template, jsonify, send_file, request
from collections import deque

app = Flask(__name__)

# Configuration
SCRIPT_DIR = Path(__file__).parent.parent.resolve()
BUILD_SCRIPT = SCRIPT_DIR / "build-db-vm.sh"
CACHE_DIR = os.environ.get("CACHE_DIR", SCRIPT_DIR / "cache")
OUTPUT_DIR = os.environ.get("OUTPUT_DIR", SCRIPT_DIR / "output")
LOCK_FILE = Path("/tmp/build-db-vm.lock")
LOG_FILE = Path("/tmp/trivy-db-build.log")
MAX_LOG_LINES = 1000

# In-memory log buffer
log_buffer = deque(maxlen=MAX_LOG_LINES)


def get_build_status():
    """Check if a build is currently running"""
    if LOCK_FILE.exists():
        try:
            with open(LOCK_FILE, 'r') as f:
                pid = int(f.read().strip())
            # Check if process is actually running
            try:
                os.kill(pid, 0)
                return {"status": "running", "pid": pid}
            except OSError:
                # Process not running but lock file exists (stale lock)
                return {"status": "stale_lock", "pid": pid}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    return {"status": "idle"}


def get_db_info():
    """Get information about the latest database build"""
    db_file = Path(OUTPUT_DIR) / "trivy.db"
    db_tar = Path(OUTPUT_DIR) / "trivy.db.tar.gz"
    metadata_file = Path(OUTPUT_DIR) / "metadata.json"
    
    info = {
        "db_exists": db_file.exists(),
        "db_size": None,
        "db_mtime": None,
        "tar_exists": db_tar.exists(),
        "tar_size": None,
        "metadata": None
    }
    
    if db_file.exists():
        stat = db_file.stat()
        info["db_size"] = stat.st_size
        info["db_mtime"] = datetime.fromtimestamp(stat.st_mtime).isoformat()
    
    if db_tar.exists():
        stat = db_tar.stat()
        info["tar_size"] = stat.st_size
    
    if metadata_file.exists():
        try:
            with open(metadata_file, 'r') as f:
                info["metadata"] = json.load(f)
        except Exception:
            pass
    
    return info


def format_size(size_bytes):
    """Format bytes to human-readable size"""
    if size_bytes is None:
        return "N/A"
    
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024.0:
            return f"{size_bytes:.2f} {unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:.2f} TB"


def run_build_async():
    """Run the build script asynchronously and capture output"""
    log_buffer.clear()
    log_buffer.append(f"[{datetime.now().isoformat()}] Starting build process...\n")
    
    try:
        # Run the build script
        process = subprocess.Popen(
            [str(BUILD_SCRIPT)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
            bufsize=1,
            cwd=str(SCRIPT_DIR)
        )
        
        # Stream output to log buffer
        for line in iter(process.stdout.readline, ''):
            if line:
                log_buffer.append(line)
                # Also write to file
                with open(LOG_FILE, 'a') as f:
                    f.write(line)
        
        process.wait()
        
        if process.returncode == 0:
            log_buffer.append(f"\n[{datetime.now().isoformat()}] Build completed successfully\n")
        else:
            log_buffer.append(f"\n[{datetime.now().isoformat()}] Build failed with exit code {process.returncode}\n")
            
    except Exception as e:
        log_buffer.append(f"\n[{datetime.now().isoformat()}] Build error: {str(e)}\n")


@app.route('/')
def index():
    """Serve the main dashboard page"""
    return render_template('index.html')


@app.route('/api/status')
def api_status():
    """Get current build status and database info"""
    build_status = get_build_status()
    db_info = get_db_info()
    
    # Format sizes for display
    db_info['db_size_formatted'] = format_size(db_info['db_size'])
    db_info['tar_size_formatted'] = format_size(db_info['tar_size'])
    
    return jsonify({
        "build": build_status,
        "database": db_info,
        "timestamp": datetime.now().isoformat()
    })


@app.route('/api/logs')
def api_logs():
    """Get recent build logs"""
    lines = request.args.get('lines', 100, type=int)
    lines = min(lines, MAX_LOG_LINES)  # Cap at max buffer size
    
    recent_logs = list(log_buffer)[-lines:] if log_buffer else []
    
    # Also try to read from log file if buffer is empty
    if not recent_logs and LOG_FILE.exists():
        try:
            with open(LOG_FILE, 'r') as f:
                all_lines = f.readlines()
                recent_logs = all_lines[-lines:]
        except Exception:
            pass
    
    return jsonify({
        "logs": recent_logs,
        "total_lines": len(log_buffer),
        "timestamp": datetime.now().isoformat()
    })


@app.route('/api/build', methods=['POST'])
def api_build():
    """Trigger a new database build"""
    build_status = get_build_status()
    
    if build_status["status"] == "running":
        return jsonify({
            "success": False,
            "message": "A build is already running",
            "pid": build_status.get("pid")
        }), 409
    
    if build_status["status"] == "stale_lock":
        return jsonify({
            "success": False,
            "message": "Stale lock file detected. Please clean it manually.",
            "pid": build_status.get("pid")
        }), 409
    
    # Clear old logs
    if LOG_FILE.exists():
        LOG_FILE.unlink()
    
    # Start build in background thread
    thread = threading.Thread(target=run_build_async, daemon=True)
    thread.start()
    
    return jsonify({
        "success": True,
        "message": "Build started successfully"
    })


@app.route('/api/build/stop', methods=['POST'])
def api_stop_build():
    """Stop a running database build"""
    build_status = get_build_status()
    
    if build_status["status"] != "running":
        return jsonify({
            "success": False,
            "message": "No build is currently running"
        }), 409
    
    try:
        pid = build_status.get("pid")
        # Send SIGTERM to allow graceful shutdown
        os.kill(pid, 15)  # SIGTERM
        log_buffer.append(f"\n[{datetime.now().isoformat()}] Build stop requested (PID: {pid})\n")
        
        return jsonify({
            "success": True,
            "message": f"Stop signal sent to build process (PID: {pid})"
        })
    except ProcessLookupError:
        return jsonify({
            "success": False,
            "message": "Build process not found"
        }), 404
    except Exception as e:
        return jsonify({
            "success": False,
            "message": f"Failed to stop build: {str(e)}"
        }), 500


@app.route('/api/download/db')
def api_download_db():
    """Download the database file"""
    db_tar = Path(OUTPUT_DIR) / "trivy.db.tar.gz"
    
    if not db_tar.exists():
        return jsonify({
            "success": False,
            "message": "Database file not found"
        }), 404
    
    return send_file(
        db_tar,
        as_attachment=True,
        download_name=f"trivy-db-{datetime.now().strftime('%Y%m%d')}.tar.gz",
        mimetype='application/gzip'
    )


@app.route('/api/download/metadata')
def api_download_metadata():
    """Download the metadata file"""
    metadata_file = Path(OUTPUT_DIR) / "metadata.json"
    
    if not metadata_file.exists():
        return jsonify({
            "success": False,
            "message": "Metadata file not found"
        }), 404
    
    return send_file(
        metadata_file,
        as_attachment=True,
        download_name=f"metadata-{datetime.now().strftime('%Y%m%d')}.json",
        mimetype='application/json'
    )


@app.route('/api/clear-lock', methods=['POST'])
def api_clear_lock():
    """Clear stale lock file (admin action)"""
    build_status = get_build_status()
    
    if build_status["status"] == "running":
        return jsonify({
            "success": False,
            "message": "Cannot clear lock while build is running"
        }), 409
    
    if LOCK_FILE.exists():
        try:
            LOCK_FILE.unlink()
            return jsonify({
                "success": True,
                "message": "Lock file cleared successfully"
            })
        except Exception as e:
            return jsonify({
                "success": False,
                "message": f"Failed to clear lock: {str(e)}"
            }), 500
    
    return jsonify({
        "success": True,
        "message": "No lock file to clear"
    })


if __name__ == '__main__':
    # Ensure output directory exists
    Path(OUTPUT_DIR).mkdir(parents=True, exist_ok=True)
    
    # Run Flask app
    port = int(os.environ.get('PORT', 5000))
    debug = os.environ.get('DEBUG', 'false').lower() == 'true'
    
    print(f"Starting Trivy DB Monitor on http://0.0.0.0:{port}")
    print(f"Build script: {BUILD_SCRIPT}")
    print(f"Output directory: {OUTPUT_DIR}")
    
    app.run(host='0.0.0.0', port=port, debug=debug)
