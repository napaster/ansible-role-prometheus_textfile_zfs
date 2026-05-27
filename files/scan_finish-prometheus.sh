#!/usr/bin/bash
# ZED hook — после scrub_finish / resilver_finish немедленно обновить textfile,
# чтобы метрики последнего scrub/resilver были свежими (а не ждать cron).
#
# Устанавливается symlink'ами в /etc/zfs/zed.d/:
#   scrub_finish-prometheus.sh
#   resilver_finish-prometheus.sh

exec /usr/local/bin/zfs_textfile_collect.sh
