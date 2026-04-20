#!/bin/bash
# Prometheus target 管理脚本 (V4 修复版 - 使用 awk 保证绝对稳定)
if [ -f "$0" ] && grep -qP '\r$' "$0" 2>/dev/null; then sed -i 's/\r$//' "$0"; exec bash "$0" "$@"; fi

CONFIG="/server/monitor/prometheus.yml"
ACTION=$1

reload_prometheus() {
  curl -s -X POST http://localhost:9090/-/reload > /dev/null
  echo "✔ Prometheus 已重载"
}

case "$ACTION" in
  add)
    JOB=$2; TARGET=$3; ALIAS=$4
    if [ -z "$JOB" ] || [ -z "$TARGET" ] || [ -z "$ALIAS" ]; then
      echo "用法: $0 add <relay|landing> <IP:端口> <服务器别名>"
      exit 1
    fi

    if [ "$JOB" = "relay" ]; then
      JOB_NAME="relay-servers"
    elif [ "$JOB" = "landing" ]; then
      JOB_NAME="landing-servers"
    else
      echo "类型只能是 relay 或 landing"
      exit 1
    fi

    if grep -q "$TARGET" "$CONFIG"; then echo "⚠ $TARGET 已存在，跳过"; exit 0; fi

    # 核心修复：使用更稳健的 awk 进行多行插入
    awk -v job="job_name: '$JOB_NAME'" \
        -v tgt="      - targets: ['$TARGET']" \
        -v lab="        labels:" \
        -v ali="          alias: '$ALIAS'" '
    $0 ~ job {in_job=1}
    in_job==1 && $0 ~ /static_configs:/ {
        print $0
        print tgt
        print lab
        print ali
        in_job=0
        next
    }
    {print $0}' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

    echo "✔ 已添加 $TARGET ($ALIAS) 到 $JOB_NAME"
    reload_prometheus
    ;;

  del)
    TARGET=$2
    if [ -z "$TARGET" ]; then echo "用法: $0 del <IP:端口>"; exit 1; fi
    if ! grep -q "$TARGET" "$CONFIG"; then echo "⚠ $TARGET 不存在"; exit 0; fi

    # 修复：连同关联的 alias 一起安全删除
    awk -v tgt="$TARGET" '
    $0 ~ tgt {skip=2; next}
    skip > 0 {skip--; next}
    {print $0}' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

    echo "✔ 已删除 $TARGET 及关联别名"
    reload_prometheus

    curl -s -X POST http://localhost:9090/api/v1/admin/tsdb/delete_series -d "match[]={instance=\"$TARGET\"}" > /dev/null
    curl -s -X POST http://localhost:9090/api/v1/admin/tsdb/clean_tombstones > /dev/null
    echo "✔ 已清理 $TARGET 历史数据"
    ;;

  list)
    echo "===== 当前 targets (IP | 别名) ====="
    grep -E "targets:|alias:" "$CONFIG" | sed "s/^[[:space:]]*- targets: \['//;s/'\]//;s/^[[:space:]]*alias: '//;s/'//" | awk 'NR%2{printf "%s | ",$0} !NR%2'
    ;;

  reload)
    reload_prometheus
    ;;

  *)
    echo "用法: $0 <add|del|list|reload> ..."
    ;;
esac
