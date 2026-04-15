#!/bin/bash
# Prometheus target 管理脚本
# 自动修复 Windows 换行符（仅文件方式执行时）
if [ -f "$0" ] && grep -qP '\r$' "$0" 2>/dev/null; then
  sed -i 's/\r$//' "$0"
  exec bash "$0" "$@"
fi
# 用法:
#   bash prom_target.sh add relay 1.2.3.4:59999
#   bash prom_target.sh add landing 5.6.7.8:59999
#   bash prom_target.sh del 1.2.3.4:59999
#   bash prom_target.sh list

CONFIG="/server/monitor/prometheus.yml"
ACTION=$1

reload_prometheus() {
  curl -s -X POST http://localhost:9090/-/reload > /dev/null
  echo "✔ Prometheus 已重载"
}

case "$ACTION" in
  add)
    JOB=$2    # relay 或 landing
    TARGET=$3 # IP:端口

    if [ -z "$JOB" ] || [ -z "$TARGET" ]; then
      echo "用法: $0 add <relay|landing> <IP:端口>"
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

    # 检查是否已存在
    if grep -q "$TARGET" "$CONFIG"; then
      echo "⚠ $TARGET 已存在，跳过"
      exit 0
    fi

    # 在对应 job 的 targets 下添加
    sed -i "/job_name: '$JOB_NAME'/,/targets:/{/targets:/a\\        - '$TARGET'
}" "$CONFIG"
    echo "✔ 已添加 $TARGET 到 $JOB_NAME"
    reload_prometheus
    ;;

  del)
    TARGET=$2
    if [ -z "$TARGET" ]; then
      echo "用法: $0 del <IP:端口>"
      exit 1
    fi

    if ! grep -q "$TARGET" "$CONFIG"; then
      echo "⚠ $TARGET 不存在"
      exit 0
    fi

    sed -i "/$TARGET/d" "$CONFIG"
    echo "✔ 已删除 $TARGET"
    reload_prometheus
    # 清理该 target 的历史数据
    curl -s -X POST http://localhost:9090/api/v1/admin/tsdb/delete_series -d "match[]={instance=\"$TARGET\"}" > /dev/null
    curl -s -X POST http://localhost:9090/api/v1/admin/tsdb/clean_tombstones > /dev/null
    echo "✔ 已清理 $TARGET 历史数据"
    ;;

  list)
    echo "===== 当前 targets ====="
    grep -E "^\s+- '" "$CONFIG" | sed "s/^[[:space:]]*- '//;s/'$//"
    ;;

  reload)
    reload_prometheus
    ;;

  *)
    echo "Prometheus target 管理脚本"
    echo ""
    echo "用法:"
    echo "  $0 add relay <IP:端口>     添加中转服务器"
    echo "  $0 add landing <IP:端口>   添加落地服务器"
    echo "  $0 del <IP:端口>           删除服务器"
    echo "  $0 list                    查看所有服务器"
    echo "  $0 reload                  重载 Prometheus"
    ;;
esac
