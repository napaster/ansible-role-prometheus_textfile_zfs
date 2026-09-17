# prometheus_textfile_zfs

Раскатывает shell-скрипт `zfs_textfile_collect.sh` (cron каждые N минут) и
ZED-hook (scrub_finish / resilver_finish — immediate refresh) для сбора
ZFS-метрик которых **не выдаёт** ни `node_exporter --collector.zfs`, ни
`pdf/zfs_exporter`:

* `zfs_pool_last_{scrub,resilver}_{timestamp_seconds,duration_seconds,errors,repaired_bytes}` —
  результаты последнего scrub/resilver
* `zfs_pool_snapshots_total{pool}` — кол-во snapshot'ов в пуле
* `zfs_pool_filesystems_total{pool}` — кол-во filesystem'ов
* `zfs_pool_compression_ratio{pool}` — compression ratio (pdf/zfs_exporter этого не отдаёт)
* `zfs_pool_iostat_{read,write}_bytes_per_second{pool}` — I/O throughput (1-сек snapshot)
* `zfs_pool_iostat_{read,write}_ops_per_second{pool}` — IOPS
* **`zfs_vdev_state{pool,vdev}`** — 0=ONLINE 1=DEGRADED ... per-disk
* **`zfs_vdev_{read,write,checksum}_errors_total{pool,vdev}`** — per-disk
  cumulative error counters. **CKSUM > 0 = data corruption signal!**

## Платформы

* ArchLinux (zfs hooks в `/usr/lib/zfs/zed.d/`)
* Debian (zfs hooks в `/usr/lib/zfs-linux/zed.d/`)
* EL (то же)

Роль **сама определяет** путь zed.d через `stat` (см. `tasks/main.yml`).

## Требования

* ZFS on Linux установлен
* `zfs-zed.service` доступен (роль рестартит его после установки hook'ов)
* `node_exporter` запущен с `--collector.textfile.directory=...`
* cron в системе (для периодического refresh без ZED-event'а)

## Переменные

| Переменная | По умолчанию | Описание |
|---|---|---|
| `prometheus_textfile_zfs_script_dest` | `/usr/local/bin/zfs_textfile_collect.sh` | Куда install collector |
| `prometheus_textfile_zfs_textfile_dir` | `/var/lib/prometheus-node-exporter/textfile_collector` | textfile dir — **обязан совпадать с `--collector.textfile.directory` node_exporter'а на этом хосте** |
| `prometheus_textfile_zfs_textfile_name` | `zfs_pools.prom` | имя файла метрик |
| `prometheus_textfile_zfs_textfile_dir_owner` | `prometheus` | владелец каталога; `root`, если каталог принадлежит пакету |
| `prometheus_textfile_zfs_textfile_dir_group` | `prometheus` | группа каталога |
| `prometheus_textfile_zfs_cron_path` | `/etc/cron.d/zfs_textfile_collect` | cron file |
| `prometheus_textfile_zfs_interval_min` | `5` | Cron interval (минут) |
| `prometheus_textfile_zfs_zed_dir` | auto-detect | Override если нужно |
| `prometheus_textfile_zfs_zed_hook_dest` | `<zed_dir>/scan_finish-prometheus.sh` | Путь hook script'а |

## Пример использования

```yaml
- name: Deploy prometheus_textfile_zfs
  become: true
  hosts: storage_zfs
  roles:
    - prometheus_textfile_zfs
```

## Сопутствующие алёрты Prometheus

```yaml
- alert: ZfsVdevChecksumErrors
  expr: zfs_vdev_checksum_errors_total > 0
  for: 2m
  labels: { severity: critical }
  annotations:
    summary: 'ZFS CKSUM errors — data corruption signal'

- alert: ZfsSnapshotCountHigh
  expr: zfs_pool_snapshots_total > 1000
  for: 30m
  labels: { severity: warning }
```

## Зависимости

* ZFS on Linux (`zpool`, `zfs`, `zfs-zed`)
* `node_exporter` с включённым `--collector.textfile.directory=...`

## Лицензия

MIT

## Про каталог

`prometheus_textfile_zfs_textfile_dir` передаётся и в cron-строку, и в ZED-hook
как `TEXTFILE_DIR` — у скрипта есть собственный дефолт, и без явной передачи
переменная роли управляла бы только созданием каталога, а писалось бы всё равно
в дефолтный. Так и было до 17.09.2026.

Расхождение каталогов **не даёт ни одной ошибки**: `node_textfile_scrape_error`
честные `0`, потому что каталог, куда node_exporter смотрит, существует и
разбирается — просто он другой. Метрики молча не доезжают, и заметно это только
по отсутствию серий в Prometheus.

На Debian дефолт сборки node_exporter — `/var/lib/prometheus/node-exporter`, туда
же пишет пакет `prometheus-node-exporter-collectors`, и путь у него зашит в
юнитах. Если на хосте стоит этот пакет, ставить каталог роли туда же и
`*_owner`/`*_group` в `root`, чтобы не перебивать владельца пакетного каталога.
