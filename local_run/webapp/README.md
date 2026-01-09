# Trivy DB Build Monitor Web Application

A Flask-based web interface for monitoring and controlling the Trivy DB build process.

## Features

- 📊 **Real-time Build Monitoring** - Check if a build is running, waiting, or idle
- 📋 **Build Logs Viewer** - Stream and view build logs in real-time
- ⬇️ **Database Download** - Download the latest built database files
- ▶️ **Build Triggering** - Initiate new builds directly from the web interface
- 🔒 **Lock Management** - Automatic lock file handling to prevent concurrent builds
- 📦 **Database Metrics** - View database size, last build time, and metadata

## Installation

1. **Install Dependencies**

```bash
cd /home/pk/OX/thirdparty/trivy-db/local_run/webapp
pip install -r requirements.txt
```

Or using a virtual environment (recommended):

```bash
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
pip install -r requirements.txt
```

2. **Configure Environment Variables (Optional)**

```bash
export CACHE_DIR=/path/to/cache    # Default: ../cache
export OUTPUT_DIR=/path/to/output  # Default: ../output
export PORT=5000                   # Default: 5000
export DEBUG=false                 # Default: false
```

## Usage

### Start the Web Application

```bash
python app.py
```

Or with custom settings:

```bash
PORT=8080 DEBUG=true python app.py
```

The application will be available at `http://localhost:5000` (or your configured port).

### Access the Dashboard

Open your browser and navigate to:
```
http://localhost:5000
```

### Using the Web Interface

1. **Monitor Status** - The dashboard automatically updates every 5 seconds
2. **View Logs** - Click "Refresh" to fetch the latest build logs
3. **Start Build** - Click "Start Build" to trigger a new database build
4. **Download DB** - Click "Download DB" to get the latest database archive
5. **Clear Stale Lock** - If a stale lock is detected, use "Clear Lock" to remove it

## API Endpoints

The application exposes the following REST API endpoints:

### GET `/api/status`
Get current build status and database information

**Response:**
```json
{
  "build": {
    "status": "idle|running|stale_lock|error",
    "pid": 12345
  },
  "database": {
    "db_exists": true,
    "db_size": 1234567890,
    "db_size_formatted": "1.15 GB",
    "db_mtime": "2026-01-09T12:00:00",
    "tar_exists": true,
    "tar_size": 123456789,
    "tar_size_formatted": "117.74 MB",
    "metadata": {
      "version": 2,
      "updatedAt": "2026-01-09T12:00:00Z",
      "nextUpdate": "2026-01-10T12:00:00Z"
    }
  },
  "timestamp": "2026-01-09T12:00:00"
}
```

### GET `/api/logs?lines=100`
Get recent build logs

**Query Parameters:**
- `lines` (optional): Number of log lines to return (default: 100, max: 1000)

**Response:**
```json
{
  "logs": ["log line 1\n", "log line 2\n"],
  "total_lines": 250,
  "timestamp": "2026-01-09T12:00:00"
}
```

### POST `/api/build`
Trigger a new database build

**Response:**
```json
{
  "success": true,
  "message": "Build started successfully"
}
```

### GET `/api/download/db`
Download the database archive file (trivy.db.tar.gz)

### GET `/api/download/metadata`
Download the metadata JSON file

### POST `/api/clear-lock`
Clear stale lock file (admin action)

**Response:**
```json
{
  "success": true,
  "message": "Lock file cleared successfully"
}
```

## Architecture

```
webapp/
├── app.py              # Flask application with REST API
├── templates/
│   └── index.html      # Web dashboard UI
├── requirements.txt    # Python dependencies
└── README.md          # This file
```

### How It Works

1. **Build Process Monitoring**
   - Checks for lock file at `/tmp/build-db-vm.lock`
   - Verifies if the PID in the lock file is actually running
   - Detects stale locks from crashed processes

2. **Log Streaming**
   - Captures output from build script in real-time
   - Stores logs in memory buffer (last 1000 lines)
   - Also writes to `/tmp/trivy-db-build.log` for persistence

3. **Database Management**
   - Monitors output directory for database files
   - Reads metadata from `metadata.json`
   - Provides download endpoints for database archives

4. **Build Triggering**
   - Runs build script in background thread
   - Prevents concurrent builds via lock file
   - Streams output to both memory buffer and log file

## Security Considerations

- The application runs on `0.0.0.0` (all interfaces) by default
- Consider using a reverse proxy (nginx, Apache) for production
- Add authentication if exposing to untrusted networks
- The `clear-lock` endpoint is powerful - protect it accordingly

## Troubleshooting

### Port Already in Use
```bash
PORT=8080 python app.py
```

### Build Script Not Found
Ensure the script is at the correct path relative to the webapp:
```
local_run/
├── build-db-vm.sh    # Must exist here
└── webapp/
    └── app.py
```

### Permission Denied
Ensure the build script is executable:
```bash
chmod +x ../build-db-vm.sh
```

### Lock File Issues
If you encounter persistent lock file issues, manually remove:
```bash
rm /tmp/build-db-vm.lock
```

## Production Deployment

For production use, consider:

1. **Using a WSGI Server**
```bash
pip install gunicorn
gunicorn -w 4 -b 0.0.0.0:5000 app:app
```

2. **Running as a Systemd Service**
Create `/etc/systemd/system/trivy-db-monitor.service`:
```ini
[Unit]
Description=Trivy DB Build Monitor
After=network.target

[Service]
Type=simple
User=trivy
WorkingDirectory=/home/pk/OX/thirdparty/trivy-db/local_run/webapp
Environment="PATH=/home/pk/OX/thirdparty/trivy-db/local_run/webapp/venv/bin"
ExecStart=/home/pk/OX/thirdparty/trivy-db/local_run/webapp/venv/bin/gunicorn -w 4 -b 0.0.0.0:5000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
```

3. **Using Nginx as Reverse Proxy**
```nginx
server {
    listen 80;
    server_name trivy-db.example.com;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## License

This application is part of the trivy-db project and follows the same license.
