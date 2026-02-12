#!/bin/bash
set -euo pipefail

# Configuration from environment variables
SCANNER_IP="${SCANNER_IP:?SCANNER_IP is required}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
SCAN_RESOLUTION="${SCAN_RESOLUTION:-300}"
SCAN_MODE="${SCAN_MODE:-Color}"
OUTPUT_DIR="${OUTPUT_DIR:-/scans}"
BLANK_THRESHOLD="${BLANK_THRESHOLD:-0.005}"
DUPLEX_FLIP_DELAY="${DUPLEX_FLIP_DELAY:-10}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-30}"
SCANNER_NAME="${SCANNER_NAME:-My Scanner}"
SCAN_SOURCE="${SCAN_SOURCE:-}"
SCAN_DEVICE="${SCAN_DEVICE:-}"
WORK_DIR="/tmp/adfwatch"
LOG_LEVEL="${LOG_LEVEL:-info}"
ESCL_BASE="http://${SCANNER_IP}/eSCL"

# Upload configuration
UPLOAD_ENABLED="${UPLOAD_ENABLED:-false}"
UPLOAD_PROTOCOL="${UPLOAD_PROTOCOL:-sftp}"  # ftp, ftps, sftp, or smb
UPLOAD_HOST="${UPLOAD_HOST:-}"
UPLOAD_PORT="${UPLOAD_PORT:-}"  # Auto-set based on protocol if not specified
UPLOAD_USER="${UPLOAD_USER:-}"
UPLOAD_PASSWORD="${UPLOAD_PASSWORD:-}"
UPLOAD_PATH="${UPLOAD_PATH:-/}"  # For SMB: //server/share/path or just share name
UPLOAD_DELETE_AFTER="${UPLOAD_DELETE_AFTER:-false}"

# Log levels mapping
declare -A LOG_LEVELS=( [debug]=0 [info]=1 [warn]=2 [error]=3 )
CURRENT_LOG_LEVEL=${LOG_LEVELS[${LOG_LEVEL}]:-1}

log() {
    local level="$1"
    shift
    local level_num=${LOG_LEVELS[${level}]:-1}
    if [[ ${level_num} -ge ${CURRENT_LOG_LEVEL} ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level^^}] $*" >&2
    fi
}

# Initialize scanner configuration
initialize_scanner() {
    # Write scanner IP and name into airscan.conf
    sed -i "s/SCANNER_IP/${SCANNER_IP}/g" /etc/sane.d/airscan.conf
    sed -i "s/SCANNER_NAME/${SCANNER_NAME}/g" /etc/sane.d/airscan.conf

    # Set default scan device if not specified
    if [[ -z "${SCAN_DEVICE}" ]]; then
        SCAN_DEVICE="airscan:e0:${SCANNER_NAME}"
    fi

    # Get scanner help output for option detection
    local scanner_help
    scanner_help=$(scanimage -d "${SCAN_DEVICE}" --help 2>&1)

    # Auto-detect scan source if not manually set
    if [[ -z "${SCAN_SOURCE}" ]]; then
        SCAN_SOURCE="ADF"  # Default value

        # Try to detect ADF source from scanner capabilities
        local adf_source
        adf_source=$(echo "${scanner_help}" | grep -A 20 "^\s*--source" | grep -i "adf" | head -n1 | sed 's/^[[:space:]]*//' | sed 's/[[:space:]].*//' || true)

        if [[ -n "${adf_source}" ]] && [[ "${adf_source}" != "--source" ]]; then
            SCAN_SOURCE="${adf_source}"
            log debug "Detected ADF source: ${SCAN_SOURCE}"
        else
            log debug "Using default source: ${SCAN_SOURCE}"
        fi
    fi

    # Wait for scanner to be reachable (max 60s)
    for attempt in {1..12}; do
        if curl --connect-timeout 5 --max-time 10 -s "${ESCL_BASE}/ScannerStatus" >/dev/null 2>&1; then
            break
        fi
        if [[ ${attempt} -eq 12 ]]; then
            log error "Scanner not reachable at ${ESCL_BASE} after 60s"
            exit 1
        fi
        log warn "Scanner not reachable, retrying in 5s (${attempt}/12)"
        sleep 5
    done

    log info "Scanner connected at ${SCANNER_IP} | source=${SCAN_SOURCE} | ${SCAN_RESOLUTION}dpi ${SCAN_MODE}"
}

# Check ADF status via eSCL
# Returns: 0 = documents loaded, 1 = empty, 2 = error
# Sets global ADF_ERROR_STATE for error details
check_adf() {
    local status_xml
    if ! status_xml=$(curl --connect-timeout 5 --max-time 10 -s "${ESCL_BASE}/ScannerStatus" 2>&1); then
        return 1
    fi

    local adf_state
    adf_state=$(echo "${status_xml}" | xmlstarlet sel -N escl="http://schemas.hp.com/imaging/escl/2011/05/03" \
        -t -v "//escl:AdfState" 2>/dev/null || echo "")

    if [[ -z "${adf_state}" ]]; then
        adf_state=$(echo "${status_xml}" | xmlstarlet sel -t -v "//*[local-name()='AdfState']" 2>/dev/null || echo "")
    fi

    if [[ "${adf_state}" == *"Loaded"* ]] || [[ "${adf_state}" == *"Processing"* ]]; then
        return 0
    fi

    if [[ "${adf_state}" == *"Jam"* ]] || [[ "${adf_state}" == *"Mispick"* ]] || \
       [[ "${adf_state}" == *"HatchOpen"* ]] || [[ "${adf_state}" == *"Error"* ]]; then
        ADF_ERROR_STATE="${adf_state}"
        return 2
    fi

    return 1
}

# Scan pages from ADF
do_scan_simple() {
    local scan_dir="$1"
    local batch_prefix="$2"

    local scan_cmd="scanimage -d \"${SCAN_DEVICE}\" --source \"${SCAN_SOURCE}\" --mode \"${SCAN_MODE}\" --resolution \"${SCAN_RESOLUTION}\" --batch=\"${scan_dir}/${batch_prefix}-%04d.pnm\" --batch-start=1 --format=pnm"

    log debug "Scan command: ${scan_cmd}"

    # Run scan synchronously (let scanimage decide when to stop)
    set +e
    local scan_output
    scan_output=$(eval "${scan_cmd}" 2>&1)
    set -e

    log debug "Scanner output: ${scan_output}"

    local page_count=$(find "${scan_dir}" -name "${batch_prefix}-*.pnm" 2>/dev/null | wc -l)
    log info "Scanned ${page_count} page(s)"
    echo "${page_count}"
}

# Manual duplex: scan fronts, wait for flip, scan backs, interleave
do_scan_manual_duplex() {
    local scan_dir="$1"

    log info "Manual duplex: scanning fronts..."
    local fronts_count
    fronts_count=$(do_scan_simple "${scan_dir}" "front")

    if [[ ${fronts_count} -eq 0 ]]; then
        log warn "No front pages scanned (timeout or empty ADF)"
        return 0
    fi

    log info "Front scanning complete (${fronts_count} pages)"
    log info "Flip the stack and reload into ADF within ${DUPLEX_FLIP_DELAY}s to scan backs, or wait to save fronts only..."
    sleep "${DUPLEX_FLIP_DELAY}"

    log info "Checking for backs..."
    local backs_count
    backs_count=$(do_scan_simple "${scan_dir}" "back")

    if [[ ${backs_count} -eq 0 ]]; then
        log warn "No back pages scanned, saving document with fronts only"
        # Just rename front pages to final page numbers
        for ((i=1; i<=fronts_count; i++)); do
            local front_file=$(printf "${scan_dir}/front-%04d.pnm" ${i})
            local final_front=$(printf "${scan_dir}/page-%04d.pnm" ${i})
            [[ -f "${front_file}" ]] && mv "${front_file}" "${final_front}"
        done
        log info "Saved ${fronts_count} front page(s) only"
        return 0
    fi

    if [[ ${fronts_count} -ne ${backs_count} ]]; then
        log warn "Front/back page count mismatch: ${fronts_count} vs ${backs_count}"
    fi

    # Interleave fronts and backs (backs in reverse order)
    local page_num=1
    for ((i=1; i<=fronts_count; i++)); do
        local front_file=$(printf "${scan_dir}/front-%04d.pnm" ${i})
        local back_file=$(printf "${scan_dir}/back-%04d.pnm" $((fronts_count - i + 1)))
        local final_front=$(printf "${scan_dir}/page-%04d.pnm" $((page_num)))
        local final_back=$(printf "${scan_dir}/page-%04d.pnm" $((page_num + 1)))

        [[ -f "${front_file}" ]] && mv "${front_file}" "${final_front}"
        [[ -f "${back_file}" ]] && mv "${back_file}" "${final_back}"

        page_num=$((page_num + 2))
    done

    log info "Interleaved $((fronts_count + backs_count)) pages"
}

# Check if a page is blank (white)
is_blank_page() {
    local file="$1"
    [[ ! -f "${file}" ]] && return 1

    local stdev
    if ! stdev=$(convert "${file}" -colorspace Gray -format "%[fx:standard_deviation]" info: 2>/dev/null); then
        return 1
    fi

    echo "${stdev} < ${BLANK_THRESHOLD}" | bc -l | grep -q "^1$"
}

# Filter blanks, convert to PNG, assemble PDF
assemble_pdf() {
    local scan_dir="$1"
    local timestamp="$2"

    local pnm_files
    mapfile -t pnm_files < <(find "${scan_dir}" -name "page-*.pnm" 2>/dev/null | sort)

    if [[ ${#pnm_files[@]} -eq 0 ]]; then
        log warn "No pages to process"
        return 0
    fi

    local page_num=0
    local blank_count=0

    for pnm_file in "${pnm_files[@]}"; do
        page_num=$((page_num + 1))

        if is_blank_page "${pnm_file}"; then
            blank_count=$((blank_count + 1))
            rm -f "${pnm_file}"
            continue
        fi

        local png_file="${pnm_file%.pnm}.png"
        if ! convert "${pnm_file}" "${png_file}" 2>/dev/null; then
            log warn "Failed to convert page ${page_num} to PNG"
        fi
        rm -f "${pnm_file}"
    done

    if [[ ${blank_count} -gt 0 ]]; then
        log info "Removed ${blank_count} blank page(s)"
    fi

    local png_files
    mapfile -t png_files < <(find "${scan_dir}" -name "page-*.png" 2>/dev/null | sort)

    if [[ ${#png_files[@]} -eq 0 ]]; then
        log warn "All pages were blank"
        return 0
    fi

    local pdf_path="${OUTPUT_DIR}/scan_${timestamp}.pdf"

    if img2pdf "${png_files[@]}" -o "${pdf_path}" 2>/dev/null; then
        log info "Saved ${pdf_path} (${#png_files[@]} pages)"
        echo "${pdf_path}"  # Return the PDF path
    else
        log error "Failed to create PDF"
        return 1
    fi
}

# Upload file to FTP/FTPS/SFTP/SMB server
upload_file() {
    local file_path="$1"
    local temp_script=""

    [[ "${UPLOAD_ENABLED}" != "true" ]] && return 0

    if [[ ! -f "${file_path}" ]]; then
        log error "Upload failed: file not found: ${file_path}"
        return 1
    fi

    if [[ -z "${UPLOAD_HOST}" ]] || [[ -z "${UPLOAD_USER}" ]]; then
        log error "Upload failed: UPLOAD_HOST and UPLOAD_USER are required"
        return 1
    fi

    local filename
    filename=$(basename "${file_path}")

    # Set default ports based on protocol
    local port="${UPLOAD_PORT}"
    if [[ -z "${port}" ]]; then
        case "${UPLOAD_PROTOCOL}" in
            ftp)   port=21 ;;
            ftps)  port=21 ;;
            sftp)  port=22 ;;
            smb)   port=445 ;;
            *)
                log error "Unknown upload protocol: ${UPLOAD_PROTOCOL}"
                return 1
                ;;
        esac
    fi

    if [[ "${UPLOAD_PROTOCOL}" == "smb" ]]; then
        log info "Uploading ${filename} to ${UPLOAD_PROTOCOL}://${UPLOAD_HOST}/${UPLOAD_PATH}"
    else
        log info "Uploading ${filename} to ${UPLOAD_PROTOCOL}://${UPLOAD_HOST}:${port}${UPLOAD_PATH}"
    fi

    # Build upload command based on protocol
    local upload_cmd
    local remote_file="${UPLOAD_PATH%/}/${filename}"

    case "${UPLOAD_PROTOCOL}" in
        ftp|ftps)
            # Use lftp for FTP/FTPS
            local protocol_option=""
            if [[ "${UPLOAD_PROTOCOL}" == "ftps" ]]; then
                protocol_option="set ftp:ssl-force true; set ftp:ssl-protect-data true;"
            fi

            upload_cmd="lftp -e \"${protocol_option} set net:timeout 30; set net:max-retries 3; put -O '${UPLOAD_PATH}' '${file_path}'; bye\" -u '${UPLOAD_USER},${UPLOAD_PASSWORD}' '${UPLOAD_HOST}' -p '${port}'"
            ;;

        sftp)
            # Use lftp for SFTP (supports password authentication)
            local temp_script
            temp_script=$(mktemp)
            cat > "${temp_script}" <<EOF
set sftp:auto-confirm yes
set net:timeout 30
set net:max-retries 3
cd ${UPLOAD_PATH}
put ${file_path}
bye
EOF
            upload_cmd="lftp sftp://'${UPLOAD_USER}':'${UPLOAD_PASSWORD}'@'${UPLOAD_HOST}':'${port}' -f '${temp_script}'"
            ;;

        smb)
            # Use smbclient for SMB/CIFS
            # UPLOAD_PATH can be: "share" or "share/subfolder"
            local share_path="${UPLOAD_PATH}"
            local remote_dir=""

            # Split share and directory if path contains /
            if [[ "${share_path}" == */* ]]; then
                local share_name="${share_path%%/*}"
                remote_dir="${share_path#*/}"
                share_path="${share_name}"
            fi

            # Build SMB path
            local smb_path="//${UPLOAD_HOST}/${share_path}"

            # Build smbclient command
            if [[ -n "${remote_dir}" ]]; then
                upload_cmd="smbclient '${smb_path}' -U '${UPLOAD_USER}%${UPLOAD_PASSWORD}' -p ${port} -c 'cd ${remote_dir}; put \"${file_path}\" \"${filename}\"'"
            else
                upload_cmd="smbclient '${smb_path}' -U '${UPLOAD_USER}%${UPLOAD_PASSWORD}' -p ${port} -c 'put \"${file_path}\" \"${filename}\"'"
            fi
            ;;

        *)
            log error "Unsupported upload protocol: ${UPLOAD_PROTOCOL}"
            return 1
            ;;
    esac

    log debug "Upload command: ${upload_cmd}"

    # Execute upload
    set +e
    local upload_output
    upload_output=$(eval "${upload_cmd}" 2>&1)
    local upload_result=$?
    set -e

    if [[ ${upload_result} -eq 0 ]]; then
        log info "Upload successful: ${filename} -> ${UPLOAD_PROTOCOL}://${UPLOAD_HOST}${remote_file}"

        # Delete local file if requested
        if [[ "${UPLOAD_DELETE_AFTER}" == "true" ]]; then
            rm -f "${file_path}"
            log info "Deleted local file: ${file_path}"
        fi

        # Clean up temp script if it exists
        [[ -n "${temp_script}" ]] && rm -f "${temp_script}"
        return 0
    else
        log error "Upload failed: ${upload_output}"
        [[ -n "${temp_script}" ]] && rm -f "${temp_script}"
        return 1
    fi
}

# Main
main() {
    log info "ADFWatch starting | scanner=${SCANNER_IP} poll=${POLL_INTERVAL}s"

    initialize_scanner

    local last_scan_time=0
    local adf_error_grace_period=60  # Ignore ADF errors for 60s after scan

    while true; do
        local current_time=$(date +%s)
        local time_since_scan=$((current_time - last_scan_time))

        # Only check ADF if we're outside the grace period
        # During grace period, only look for documents, not errors
        set +e
        check_adf
        local adf_result=$?
        set -e

        # If we're in grace period and got an error, treat it as empty instead
        if [[ ${time_since_scan} -lt ${adf_error_grace_period} ]] && [[ ${adf_result} -eq 2 ]]; then
            log debug "Suppressing ADF error during ${adf_error_grace_period}s grace period (${time_since_scan}s after scan)"
            adf_result=1  # Treat as empty
        fi

        if [[ ${adf_result} -eq 0 ]]; then
            log info "Documents detected, scanning..."

            local timestamp
            timestamp=$(date '+%Y%m%d_%H%M%S')
            local scan_dir="${WORK_DIR}/${timestamp}"
            mkdir -p "${scan_dir}"

            if do_scan_manual_duplex "${scan_dir}"; then
                local pdf_path
                if pdf_path=$(assemble_pdf "${scan_dir}" "${timestamp}"); then
                    # Upload the PDF if enabled
                    upload_file "${pdf_path}"
                fi
            else
                log error "Scan failed"
            fi

            rm -rf "${scan_dir}"

            # Set grace period start time to suppress false ADF errors
            last_scan_time=$(date +%s)
        elif [[ ${adf_result} -eq 2 ]]; then
            # ADF error detected outside grace period
            log error "ADF error: ${ADF_ERROR_STATE}"
            log warn "ADF error detected - please press reset button on printer"
        fi

        sleep "${POLL_INTERVAL}"
    done
}

main
