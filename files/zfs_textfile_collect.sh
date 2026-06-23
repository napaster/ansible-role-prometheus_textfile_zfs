#!/usr/bin/bash
# zfs_textfile_collect.sh — генерит prometheus textfile metrics для всех ZFS pools
# на хосте. Запускается как cron каждые N минут И как ZED-hook (scan_finish).
#
# Output: /var/lib/prometheus-node-exporter/textfile_collector/zfs_pools.prom
# Метрики (атрибуты подписаны pool='<name>'):
#   zfs_pool_last_scrub_timestamp_seconds  — unix-ts последнего scrub-completion
#   zfs_pool_last_scrub_duration_seconds   — длительность последнего scrub
#   zfs_pool_last_scrub_errors             — кол-во errors во время scrub
#   zfs_pool_last_scrub_repaired_bytes     — bytes repaired
#   zfs_pool_last_resilver_timestamp_seconds, _duration_seconds, _errors, _repaired_bytes
#   zfs_pool_snapshots_total{pool="X"}     — кол-во snapshot'ов пула
#   zfs_pool_filesystems_total{pool="X"}   — кол-во filesystems пула
#
# Atomic write — пишем в tmp, потом mv. Чтобы node_exporter не прочитал
# полу-обновлённый файл.
#
# Принципиально НЕ используем `set -e` / `set -o pipefail` — слишком хрупко
# для пайплайнов с grep/head на полях которые могут отсутствовать (свежий пул
# без scrub-line). Все expected-failures обрабатываются через `|| true`.

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/prometheus-node-exporter/textfile_collector}"
OUT="${TEXTFILE_DIR}/zfs_pools.prom"
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

ZPOOL=${ZPOOL:-/usr/sbin/zpool}
ZFS=${ZFS:-/usr/sbin/zfs}

mkdir -p "$TEXTFILE_DIR" 2>/dev/null

# Парсит "scan: ..." строку из `zpool status` и пишет метрики в $TMP.
parse_scan_line() {
    local pool="$1"
    local line="$2"

    local type
    if echo "$line" | grep -q 'scrub repaired'; then
        type='scrub'
    elif echo "$line" | grep -q 'resilvered'; then
        type='resilver'
    else
        return 0
    fi

    # "5 days HH:MM:SS" offset
    local days_offset=0
    local days=0
    if echo "$line" | grep -q ' days '; then
        days_offset=2
        if [ "$type" = "scrub" ]; then
            days=$(awk '{print $6}' <<<"$line")
        else
            days=$(awk '{print $5}' <<<"$line")
        fi
    fi

    local repaired length errors timestamp
    if [ "$type" = "scrub" ]; then
        repaired=$(awk '{print $4}' <<<"$line")
        length=$(awk -v o=$days_offset '{print $(6+o)}' <<<"$line")
        errors=$(awk -v o=$days_offset '{print $(8+o)}' <<<"$line")
        timestamp=$(awk -v o=$days_offset '{print substr($0, index($0, $(11+o)))}' <<<"$line")
    else
        repaired=$(awk '{print $3}' <<<"$line")
        length=$(awk -v o=$days_offset '{print $(5+o)}' <<<"$line")
        errors=$(awk -v o=$days_offset '{print $(7+o)}' <<<"$line")
        timestamp=$(awk -v o=$days_offset '{print substr($0, index($0, $(10+o)))}' <<<"$line")
    fi

    local repaired_bytes
    repaired_bytes=$(numfmt --from=auto <<<"${repaired%B}" 2>/dev/null || echo 0)

    local h m s
    IFS=: read -r h m s <<<"$length"
    local length_seconds=$(( 10#${s:-0} + (10#${m:-0} * 60) + (10#${h:-0} * 3600) + (days * 86400) ))

    local ts_unix
    ts_unix=$(date -d "$timestamp" +'%s' 2>/dev/null || echo 0)

    {
        echo "zfs_pool_last_${type}_timestamp_seconds{pool=\"${pool}\"} ${ts_unix}"
        echo "zfs_pool_last_${type}_duration_seconds{pool=\"${pool}\"} ${length_seconds}"
        echo "zfs_pool_last_${type}_errors{pool=\"${pool}\"} ${errors}"
        echo "zfs_pool_last_${type}_repaired_bytes{pool=\"${pool}\"} ${repaired_bytes}"
    } >> "$TMP"
}

{
    echo "# HELP zfs_pool_last_scrub_timestamp_seconds Unix timestamp of last successful scrub"
    echo "# TYPE zfs_pool_last_scrub_timestamp_seconds gauge"
    echo "# HELP zfs_pool_last_resilver_timestamp_seconds Unix timestamp of last successful resilver"
    echo "# TYPE zfs_pool_last_resilver_timestamp_seconds gauge"
    echo "# HELP zfs_pool_snapshots_total Number of snapshots in the pool"
    echo "# TYPE zfs_pool_snapshots_total gauge"
    echo "# HELP zfs_pool_filesystems_total Number of filesystems in the pool"
    echo "# TYPE zfs_pool_filesystems_total gauge"
} > "$TMP"

{
    echo "# HELP zfs_pool_compression_ratio Compression ratio for the pool (pdf/zfs_exporter does not expose this)"
    echo "# TYPE zfs_pool_compression_ratio gauge"
    echo "# HELP zfs_pool_iostat_read_bytes_per_second Pool I/O read throughput (B/s, 1-sec sample)"
    echo "# TYPE zfs_pool_iostat_read_bytes_per_second gauge"
    echo "# HELP zfs_pool_iostat_write_bytes_per_second Pool I/O write throughput (B/s, 1-sec sample)"
    echo "# TYPE zfs_pool_iostat_write_bytes_per_second gauge"
    echo "# HELP zfs_pool_iostat_read_ops_per_second Pool I/O read ops/sec (1-sec sample)"
    echo "# TYPE zfs_pool_iostat_read_ops_per_second gauge"
    echo "# HELP zfs_pool_iostat_write_ops_per_second Pool I/O write ops/sec (1-sec sample)"
    echo "# TYPE zfs_pool_iostat_write_ops_per_second gauge"
    echo "# HELP zfs_vdev_read_errors_total Cumulative READ errors per vdev (since pool create / clear)"
    echo "# TYPE zfs_vdev_read_errors_total counter"
    echo "# HELP zfs_vdev_write_errors_total Cumulative WRITE errors per vdev"
    echo "# TYPE zfs_vdev_write_errors_total counter"
    echo "# HELP zfs_vdev_checksum_errors_total Cumulative CKSUM errors per vdev (critical — data corruption signal)"
    echo "# TYPE zfs_vdev_checksum_errors_total counter"
    echo "# HELP zfs_vdev_state State code of individual vdev: 0=ONLINE, 1=DEGRADED, 2=FAULTED, 3=OFFLINE, 4=UNAVAIL, 5=REMOVED"
    echo "# TYPE zfs_vdev_state gauge"
} >> "$TMP"

# vdev state code mapping
vdev_state_code() {
    case "$1" in
        ONLINE)   echo 0 ;;
        DEGRADED) echo 1 ;;
        FAULTED)  echo 2 ;;
        OFFLINE)  echo 3 ;;
        UNAVAIL)  echo 4 ;;
        REMOVED)  echo 5 ;;
        *)        echo -1 ;;
    esac
}

# Парсит vdev-таблицу из `zpool status -P <pool>` (-P = full path для дисков).
# Output формат:
#   NAME                          STATE     READ WRITE CKSUM
#   <pool>                        ONLINE       0     0     0
#     mirror-0                    ONLINE       0     0     0
#       /dev/disk/by-id/<wwn>     ONLINE       0     0     0
#       <wwn>                     ONLINE       0     0     0
#     <single-disk>               ONLINE       0     0     0
#
# Для каждой строки с STATE+READ+WRITE+CKSUM пишем metric'и.
# Игнорируем blank-lines и "errors:" footer.
parse_vdev_status() {
    local pool="$1"

    # awk парсит с-by-line; учитываем что NAME может быть с leading-pad,
    # ловим формат "  X+spaces  STATE  N  N  N" где STATE — одно из known.
    # STATE READ WRITE CKSUM ищем через regex — после CKSUM zpool может
    # приписать "too many errors" / "(awaiting resilver)" / "(repairing)" и
    # последние NF полей оказываются словами вместо чисел.
    "$ZPOOL" status -P "$pool" 2>/dev/null | awk -v pool="$pool" '
        /^[[:space:]]+NAME[[:space:]]+STATE/ { in_table=1; next }
        /^errors:/                            { in_table=0 }
        /^[[:space:]]*$/                      { next }
        in_table && match($0, /(ONLINE|DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED)[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+/) {
            s = substr($0, RSTART, RLENGTH)
            split(s, parts, /[ \t]+/)
            state = parts[1]; r = parts[2]; w = parts[3]; c = parts[4]
            name = $1
            if (name == pool) next
            print name, state, r, w, c
        }
    ' | while read -r vdev state r w c; do
        # short-name (basename) для compactности в labels
        short=$(basename "$vdev")
        sc=$(vdev_state_code "$state")
        {
            echo "zfs_vdev_state{pool=\"${pool}\",vdev=\"${short}\"} ${sc}"
            echo "zfs_vdev_read_errors_total{pool=\"${pool}\",vdev=\"${short}\"} ${r}"
            echo "zfs_vdev_write_errors_total{pool=\"${pool}\",vdev=\"${short}\"} ${w}"
            echo "zfs_vdev_checksum_errors_total{pool=\"${pool}\",vdev=\"${short}\"} ${c}"
        } >> "$TMP"
    done
}

# `zpool iostat -p -H -y 1 1` — одно sample-окно 1 сек, в parseable -p (raw bytes),
# -H (no header), -y (skip startup boot stats). Output per pool:
#   <name> <alloc> <free> <ops_read> <ops_write> <bw_read> <bw_write>
iostat_lines=$("$ZPOOL" iostat -p -H -y 1 1 2>/dev/null || true)

# Все пулы на хосте
pools=$("$ZPOOL" list -H -o name 2>/dev/null || true)
for pool in $pools; do
    # scan line — `grep -m1` останавливается на первом match → не SIGPIPE.
    # Trim ТОЛЬКО ведущие пробелы (но НЕ "scan: " префикс) — awk-индексы в
    # parse_scan_line рассчитаны на формат `scan: ...` (как в zabbix-роли).
    line=$("$ZPOOL" status "$pool" 2>/dev/null | grep -m1 -E '^[[:space:]]*scan:' | sed 's/^[[:space:]]*//' || true)
    if [ -n "$line" ]; then
        parse_scan_line "$pool" "$line"
    fi

    # snapshots count
    snap_count=$("$ZFS" list -H -t snapshot -r "$pool" 2>/dev/null | wc -l)
    echo "zfs_pool_snapshots_total{pool=\"${pool}\"} ${snap_count:-0}" >> "$TMP"

    # filesystems count
    fs_count=$("$ZFS" list -H -t filesystem -r "$pool" 2>/dev/null | wc -l)
    echo "zfs_pool_filesystems_total{pool=\"${pool}\"} ${fs_count:-0}" >> "$TMP"

    # compression ratio — `zfs get -H -p -o value compressratio <pool>` (raw, e.g. "1.42")
    comp=$("$ZFS" get -H -p -o value compressratio "$pool" 2>/dev/null || echo "0")
    echo "zfs_pool_compression_ratio{pool=\"${pool}\"} ${comp:-0}" >> "$TMP"

    # vdev errors + state per-disk
    parse_vdev_status "$pool"

    # I/O stats — pick line from iostat output по имени pool'а (поле 1).
    # Не пугаемся если pool отсутствует в iostat snapshot — пишем 0.
    iostat_row=$(echo "$iostat_lines" | awk -v p="$pool" '$1 == p {print; exit}')
    if [ -n "$iostat_row" ]; then
        ops_r=$(awk '{print $4}' <<<"$iostat_row")
        ops_w=$(awk '{print $5}' <<<"$iostat_row")
        bw_r=$(awk '{print $6}' <<<"$iostat_row")
        bw_w=$(awk '{print $7}' <<<"$iostat_row")
        {
            echo "zfs_pool_iostat_read_ops_per_second{pool=\"${pool}\"} ${ops_r:-0}"
            echo "zfs_pool_iostat_write_ops_per_second{pool=\"${pool}\"} ${ops_w:-0}"
            echo "zfs_pool_iostat_read_bytes_per_second{pool=\"${pool}\"} ${bw_r:-0}"
            echo "zfs_pool_iostat_write_bytes_per_second{pool=\"${pool}\"} ${bw_w:-0}"
        } >> "$TMP"
    fi
done

# atomic rename
chmod 0644 "$TMP"
mv -f "$TMP" "$OUT"
trap - EXIT
