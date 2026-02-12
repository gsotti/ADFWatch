# ADFWatch

Automated document scanner service that monitors a network scanner's ADF (Automatic Document Feeder) and creates PDFs from scanned documents.

## Features

- **Dynamic Scanner Discovery**: Automatically finds your scanner on the network by device name using mDNS/Bonjour
- **Automatic Scanning**: Monitors scanner ADF and automatically starts scanning when documents are detected
- **Blank Page Removal**: Automatically detects and removes blank pages from scans
- **PDF Generation**: Converts scanned pages to a single PDF document
- **Docker-based**: Easy deployment with Docker and Docker Compose

## Quick Start

1. **Configure your scanner** in `docker-compose.yml`:
   ```yaml
   environment:
     - SCANNER_IP=192.168.1.100  # Your scanner's IP address
     - SCANNER_NAME=My Scanner    # Your scanner's display name
   ```

2. **Build and run**:
   ```bash
   docker-compose up -d
   ```

3. **Place documents** in your scanner's ADF feeder

4. **Find your scans** in the `./scans` directory

## Configuration

### Scanner Settings

Configure your scanner in `docker-compose.yml`:

```yaml
- SCANNER_IP=192.168.1.100  # Required: Your scanner's IP address
- SCANNER_NAME=My Scanner    # Required: Your scanner's display name
```

**Finding your scanner's IP:**
- Check your router's DHCP client list
- Use your scanner's control panel/display
- Use network scanning tools like `nmap` or `arp-scan`

**Scanner name:**
- This can be any descriptive name for your scanner
- Used for SANE device identification

### Other Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `SCANNER_IP` | _(required)_ | Scanner's IP address |
| `SCANNER_NAME` | `My Scanner` | Scanner's display name for SANE device identification |
| `POLL_INTERVAL` | `5` | Seconds between ADF status checks |
| `SCAN_RESOLUTION` | `300` | Scan resolution in DPI |
| `SCAN_MODE` | `Color` | Scan mode: `Color`, `Gray`, or `Lineart` |
| `DUPLEX_MODE` | `false` | `true` = scan both sides (duplex), `false` = scan single side only |
| `DUPLEX_FLIP_DELAY` | `10` | Seconds to wait for flipping pages in manual duplex mode |
| `SCAN_EXTRA_OPTS` | _(empty)_ | Extra scanimage options (e.g., `--duplex` for manual duplex control) |
| `BLANK_THRESHOLD` | `0.005` | Threshold for blank page detection (lower = more sensitive) |
| `OUTPUT_DIR` | `/scans` | Directory where PDFs are saved |
| `LOG_LEVEL` | `info` | Logging level: `debug`, `info`, `warn`, or `error` |

### Upload Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `UPLOAD_ENABLED` | `false` | Set to `true` to enable automatic upload after scanning |
| `UPLOAD_PROTOCOL` | `sftp` | Upload protocol: `ftp`, `ftps`, or `sftp` |
| `UPLOAD_HOST` | _(empty)_ | Remote server hostname or IP address |
| `UPLOAD_PORT` | _(auto)_ | Server port (defaults: ftp=21, ftps=21, sftp=22) |
| `UPLOAD_USER` | _(empty)_ | Username for authentication |
| `UPLOAD_PASSWORD` | _(empty)_ | Password for authentication |
| `UPLOAD_PATH` | `/` | Remote directory path where PDFs will be uploaded |
| `UPLOAD_DELETE_AFTER` | `false` | Delete local file after successful upload |

## How It Works

1. **Discovery**: On startup, the service discovers your scanner's IP address by device name (or uses the provided IP)
2. **Monitoring**: Continuously polls the scanner's ADF status
3. **Scanning**: When documents are detected, automatically scans all pages
   - **Automatic Duplex**: If scanner supports it, scans both sides automatically
   - **Manual Duplex**: If scanner doesn't support automatic duplex but `DUPLEX_MODE=true`:
     - Scans all front pages (odd pages)
     - Logs countdown timer (default 10 seconds)
     - You flip the entire stack and place back in ADF
     - Scans all back pages (even pages)
     - Automatically reverses and interleaves pages correctly
4. **Processing**: Removes blank pages and converts to PNG
5. **PDF Creation**: Assembles all pages into a single PDF with timestamp
6. **Output**: Saves PDF to the output directory

### Manual Duplex Mode

For scanners that don't support automatic duplex:

1. Place documents **face-up** in the ADF
2. The scanner scans all fronts (pages 1, 3, 5, 7...)
3. **Watch the logs** - they will tell you when to flip
4. Remove the pages from output tray, flip the **entire stack**, place back in ADF
5. The scanner automatically scans all backs (pages 10, 8, 6, 4, 2...)
6. Pages are automatically reversed and interleaved into correct order (1, 2, 3, 4...)

## Network Requirements

- **Host Network Mode**: The container uses host networking to access mDNS services
- **mDNS/Bonjour**: Your scanner must advertise itself via mDNS (most modern eSCL scanners do)
- **eSCL Protocol**: Scanner must support eSCL (most network scanners do)

## Automatic Upload

After scanning, PDFs can be automatically uploaded to a remote server via FTP, FTPS, or SFTP.

### Enable Upload

In `docker-compose.yml`:

```yaml
- UPLOAD_ENABLED=true
- UPLOAD_PROTOCOL=sftp  # or ftp, ftps
- UPLOAD_HOST=your-server.com
- UPLOAD_USER=username
- UPLOAD_PASSWORD=password
- UPLOAD_PATH=/remote/scans
```

### Supported Protocols

- **SFTP** (recommended): Secure FTP over SSH, port 22
- **FTPS**: FTP with TLS/SSL encryption, port 21
- **FTP**: Plain FTP (not recommended for production), port 21

### Upload Workflow

1. Scanner detects documents
2. Scans and creates PDF locally in `/scans`
3. **Automatically uploads** PDF to remote server
4. Optionally deletes local copy (if `UPLOAD_DELETE_AFTER=true`)

### Security Notes

- **Passwords** are passed in plain text via environment variables
- For production, consider:
  - Using SFTP with SSH keys instead of passwords
  - Storing credentials in Docker secrets or external secret management
  - Using `.env` file (add to `.gitignore`) instead of hardcoding in `docker-compose.yml`

## Troubleshooting

### Scanner Not Found

If automatic discovery fails:

1. **Verify scanner IP**: Ping your scanner to ensure it's reachable:
   ```bash
   ping 192.168.1.100
   ```

2. **Check eSCL endpoint**: Verify the scanner's eSCL interface is accessible:
   ```bash
   curl http://192.168.1.100/eSCL/ScannerStatus
   ```

3. **Review logs**: Check Docker logs for detailed error messages:
   ```bash
   docker-compose logs -f adfwatch
   ```

### Viewing Logs

```bash
docker-compose logs -f adfwatch
```

Set `LOG_LEVEL=debug` for detailed diagnostics.

### Scanner Not Reachable

- Ensure scanner is on and connected to the network
- Verify scanner's web interface is accessible: `http://<scanner-ip>/`
- Check firewall settings on both scanner and host

## Supported Scanners

Any scanner that supports:
- **eSCL protocol** (AirPrint scanning)
- **ADF (Automatic Document Feeder)**

Compatible scanner brands:
- Canon PIXMA series
- HP OfficeJet / LaserJet series
- Epson WorkForce / EcoTank series
- Brother MFC / DCP series
- And many other modern network scanners with eSCL support

## License

This is free and unencumbered software released into the public domain.
