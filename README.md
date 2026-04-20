# 端口带宽监控部署指南 (V4 业务升级版)

## 一、管理机部署（Prometheus + Grafana）

### 1. 创建目录

```bash
mkdir -p /server/monitor && cd /server/monitor
```

### 2. 创建 docker-compose.yml

```yaml
networks:
  monitor-net:
    driver: bridge

volumes:
  prometheus_data: {}
  grafana_data: {}

services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: always
    volumes:
      - ./:/etc/prometheus/
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=30d"
      - "--web.enable-lifecycle"
      - "--web.enable-admin-api"
    ports:
      - "9090:9090"
    networks:
      - monitor-net

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: always
    user: "472"
    volumes:
      - grafana_data:/var/lib/grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=改成你的密码
      - GF_SECURITY_ALLOW_EMBEDDING=true
      - GF_AUTH_ANONYMOUS_ENABLED=true
      - GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
      - GF_AUTH_BASIC_ENABLED=true
      - GF_USERS_DEFAULT_LANGUAGE=zh-Hans
    networks:
      - monitor-net
```

### 3. 创建 prometheus.yml (初始化空壳)

*注意：不要手动在此文件填写 IP。请保持空壳状态，后续由管理脚本自动添加，以确保标签格式正确。*

```yaml
global:
  scrape_interval: 5s

scrape_configs:
  - job_name: 'relay-servers'
    static_configs:
  - job_name: 'landing-servers'
    static_configs:
```

### 4. 启动

*(如果是旧版本升级，请先执行 `docker compose down -v` 清空旧数据再启动)*

```bash
cd /server/monitor && docker compose up -d
```

### 5. 验证

```bash
docker compose ps
curl http://localhost:9090/-/healthy
curl http://localhost:3000/api/health
```

### 6. 配置 Grafana 数据源

1. 浏览器打开 `http://管理机IP:3000`
2. 用 `admin` + 你设的密码登录
3. 左侧菜单 → 连接 → 数据源 → 添加数据源
4. 选 Prometheus，URL 填 `http://prometheus:9090`
5. 点 保存并测试，显示绿色就 OK

### 7. 后续管理服务器

将 `prom_target.sh` 放到 `/server/monitor/` 目录下，用命令管理 target：

```bash
# 添加中转服务器 (必须带上第三个参数：服务器别名)
bash prom_target.sh add relay 1.2.3.4:59999 "沪日专线-01"

# 添加落地服务器
bash prom_target.sh add landing 5.6.7.8:59999 "东京落地-01"

# 删除服务器 (将自动清理配置文件及该机器的历史数据)
bash prom_target.sh del 1.2.3.4:59999

# 查看所有服务器
bash prom_target.sh list
```

添加和删除后会自动热重载 Prometheus，不用手动操作。

`prom_target.sh` 脚本内容：

```bash
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
```

---

## 二、中转/落地服务器部署（一键脚本）

### 1. 一键安装命令

国外服务器：
` ` `bash
bash <(curl -Ls https://raw.githubusercontent.com/farmer718/monitor-deploy-guide/main/deploy_monitor.sh)
` ` `

国内服务器：
` ` `bash
bash <(curl -Ls https://gitee.com/therfarmer/monitor-deploy-guide/raw/master/deploy_monitor.sh)
` ` `

### 2. 一键部署脚本 deploy_monitor.sh

将以下脚本保存为 `deploy_monitor.sh`，传到目标服务器上执行即可。
*(此版本集成 `user_map.txt` 主播别名读取功能)*

```bash
#!/bin/bash
# 一键部署 node_exporter + 端口带宽采集脚本 (V4.3 终极版 - 主播名在前端口在后)
if [ -f "$0" ] && grep -qP '\r$' "$0" 2>/dev/null; then sed -i 's/\r$//' "$0"; exec bash "$0" "$@"; fi

NODE_EXPORTER_VERSION="1.8.2"

# ========== 自动判断国内/国外，选择下载地址 ==========
COUNTRY=$(curl -s --max-time 3 https://ipinfo.io/country)
if [ "$COUNTRY" = "CN" ]; then
    echo "🌏 检测到中国地区，使用国内下载源"
    DOWNLOAD_URL="http://159.27.62.103:18084/soft/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
else
    echo "🌍 非中国地区，使用 GitHub 下载源"
    DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
fi

# ========== 交互输入 (支持批量脚本静默跳过) ==========
read -t 10 -p "请输入 node_exporter 监听端口 [默认 59999 (10秒自动跳过)]: " input_port < /dev/tty 2>/dev/null
echo ""
NODE_EXPORTER_PORT=${input_port:-59999}

read -t 10 -p "请输入带宽监控端口范围起始 [默认 10000]: " input_min < /dev/tty 2>/dev/null
echo ""
PORT_MIN=${input_min:-10000}

read -t 10 -p "请输入带宽监控端口范围结束 [默认 63355]: " input_max < /dev/tty 2>/dev/null
echo ""
PORT_MAX=${input_max:-63355}

echo "确认配置："
echo "  node_exporter 端口: ${NODE_EXPORTER_PORT}"
echo "  监控端口范围: ${PORT_MIN} - ${PORT_MAX}"
read -t 5 -p "是否继续？[Y/n (5秒自动继续)]: " confirm < /dev/tty 2>/dev/null
echo ""
if [[ "$confirm" =~ ^[nN] ]]; then echo "已取消"; exit 0; fi

# ========== 0. 检查依赖 ==========
if ! command -v iptables &>/dev/null; then
  echo ">>> 0. 安装 iptables"
  apt install -y iptables 2>/dev/null || yum install -y iptables 2>/dev/null
fi

# ========== 1. 安装 node_exporter ==========
echo ">>> 1. 安装 node_exporter"
cd /tmp
FILENAME="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
if [ ! -f "$FILENAME" ]; then
  if command -v wget &>/dev/null; then wget -q "$DOWNLOAD_URL" -O "$FILENAME"; else curl -Ls "$DOWNLOAD_URL" -o "$FILENAME"; fi
fi
tar xzf "$FILENAME"
cp node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/

# ========== 2. 创建 systemd 服务 ==========
echo ">>> 2. 创建 systemd 服务"
mkdir -p /var/lib/node_exporter/textfile
cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
ExecStart=/usr/local/bin/node_exporter \\
  --web.listen-address=:${NODE_EXPORTER_PORT} \\
  --collector.textfile.directory=/var/lib/node_exporter/textfile \\
  --no-collector.arp \\
  --no-collector.bcache \\
  --no-collector.bonding \\
  --no-collector.btrfs \\
  --no-collector.cpufreq \\
  --no-collector.edac \\
  --no-collector.entropy \\
  --no-collector.fibrechannel \\
  --no-collector.hwmon \\
  --no-collector.infiniband \\
  --no-collector.ipvs \\
  --no-collector.mdadm \\
  --no-collector.nfs \\
  --no-collector.nfsd \\
  --no-collector.nvme \\
  --no-collector.rapl \\
  --no-collector.schedstat \\
  --no-collector.tapestats \\
  --no-collector.thermal_zone \\
  --no-collector.zfs
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now node_exporter

# ========== 3. 部署采集脚本与映射表 ==========
echo ">>> 3. 部署采集脚本"
mkdir -p /opt/scripts
# 初始化空的映射表
if [ ! -f /opt/scripts/user_map.txt ]; then
  echo "# 格式: 端口号 主播名字 (例如: 10001 虚拟主播-七七)" > /opt/scripts/user_map.txt
fi

cat > /opt/scripts/port_traffic.sh << SCRIPT
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PORT_MIN=${PORT_MIN}
PORT_MAX=${PORT_MAX}
OUTPUT="/var/lib/node_exporter/textfile/port_traffic.prom"
TMP="\${OUTPUT}.tmp"

mkdir -p "\$(dirname "\$OUTPUT")"
> "\$TMP"

iptables -N PORT_MONITOR_IN 2>/dev/null
iptables -N PORT_MONITOR_OUT 2>/dev/null
iptables -C INPUT -j PORT_MONITOR_IN 2>/dev/null || iptables -A INPUT -j PORT_MONITOR_IN
iptables -C OUTPUT -j PORT_MONITOR_OUT 2>/dev/null || iptables -A OUTPUT -j PORT_MONITOR_OUT

PORTS=\$(ss -tlnp | awk '{print \$4}' | grep -oP ':\K[0-9]+' | awk -v min=\$PORT_MIN -v max=\$PORT_MAX '\$1>=min && \$1<=max' | sort -n | uniq)

for port in \$PORTS; do
  iptables -C PORT_MONITOR_IN -p tcp --dport \$port 2>/dev/null || iptables -A PORT_MONITOR_IN -p tcp --dport \$port
  iptables -C PORT_MONITOR_OUT -p tcp --sport \$port 2>/dev/null || iptables -A PORT_MONITOR_OUT -p tcp --sport \$port

  in_bytes=\$(iptables -L PORT_MONITOR_IN -vnx | awk -v p="dpt:\$port" '\$0 ~ p {print \$2}')
  out_bytes=\$(iptables -L PORT_MONITOR_OUT -vnx | awk -v p="spt:\$port" '\$0 ~ p {print \$2}')
  
  # === 提取别名，拼接为 [别名-端口] 格式 ===
  ALIAS_NAME=\$(awk -v p="\$port" '\$1==p {sub(/\\r\$/,"",\$2); print \$2}' /opt/scripts/user_map.txt 2>/dev/null)
  USER_NAME="\${ALIAS_NAME:-未分配}-\$port"
  
  echo "port_traffic_in_bytes{port=\"\$port\",user=\"\$USER_NAME\"} \${in_bytes:-0}" >> "\$TMP"
  echo "port_traffic_out_bytes{port=\"\$port\",user=\"\$USER_NAME\"} \${out_bytes:-0}" >> "\$TMP"
done

mv "\$TMP" "\$OUTPUT"
SCRIPT
chmod +x /opt/scripts/port_traffic.sh

# ========== 4. 配置 crontab ==========
echo ">>> 4. 配置 crontab（5秒一次）"
(crontab -l 2>/dev/null | grep -v port_traffic; echo "* * * * * for i in 0 5 10 15 20 25 30 35 40 45 50 55; do sleep \$i && /opt/scripts/port_traffic.sh & done") | crontab -

# ========== 5. 验证 ==========
echo ">>> 5. 验证"
/opt/scripts/port_traffic.sh
echo "--- 采集文件内容 ---"
head -n 5 /var/lib/node_exporter/textfile/port_traffic.prom
echo ""
echo "--- node_exporter 状态 ---"
systemctl is-active node_exporter
echo ""
echo "========================================="
echo "部署完成！"
echo "  node_exporter 端口: ${NODE_EXPORTER_PORT}"
echo "  监控端口范围: ${PORT_MIN} - ${PORT_MAX}"
echo "  请去管理机执行 prom_target.sh add 添加本服务器"
echo "  主播名称配置文件: /opt/scripts/user_map.txt"
echo "========================================="
```

### 3. 为端口绑定主播名称
在目标服务器上编辑配置文件：
```bash
vi /opt/scripts/user_map.txt
```
按 `端口号 主播名称` 的格式填入并保存，例如：
```text
10001 虚拟主播-七七
10002 游戏主播-张三
```
保存后即刻生效，无需重启服务。

---

## 三、导入 Grafana 仪表盘 (V4 终极多维面板)

在管理机上执行以下命令（**先把"你的密码"改成实际的 Grafana 密码**）。

```bash
cat > /tmp/import_dashboard_v4_3.sh << 'ENDSCRIPT'
curl -X POST http://admin:你的密码@localhost:3000/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d '{
  "dashboard": {
    "uid": "live-stream-pro-v4",
    "title": "直播业务全景监控",
    "timezone": "browser",
    "refresh": "5s",
    "time": {"from": "now-1h", "to": "now"},
    "templating": {
      "list": [
        {
          "name": "job",
          "label": "节点类型",
          "type": "query",
          "query": "label_values(up, job)",
          "refresh": 2, "multi": false, "includeAll": true,
          "current": {"selected": true, "text": "relay-servers", "value": "relay-servers"}
        },
        {
          "name": "alias",
          "label": "🏷️ 服务器别名",
          "type": "query",
          "query": "label_values(up{job=~\"$job\"}, alias)",
          "refresh": 2, "multi": true, "includeAll": true,
          "current": {"selected": true, "text": "All", "value": "$__all"}
        },
        {
          "name": "instance",
          "label": "💻 服务器 IP",
          "type": "query",
          "query": "label_values(up{job=~\"$job\", alias=~\"$alias\"}, instance)",
          "refresh": 2, "multi": true, "includeAll": true,
          "current": {"selected": true, "text": "All", "value": "$__all"}
        },
        {
          "name": "user",
          "label": "👤 端口与主播",
          "type": "query",
          "query": "label_values(port_traffic_in_bytes{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\"}, user)",
          "refresh": 2, "multi": true, "includeAll": true,
          "current": {"selected": true, "text": "All", "value": "$__all"}
        }
      ]
    },
    "panels": [
      {
        "id": 101,
        "title": "已消耗总流量 (入站)",
        "type": "stat",
        "gridPos": {"h": 4, "w": 12, "x": 0, "y": 0},
        "targets": [{"expr": "sum(increase(port_traffic_in_bytes{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\", user=~\"$user\"}[$__range]))"}],
        "fieldConfig": {"defaults": {"unit": "bytes", "color": {"mode": "value", "fixedColor": "green"}}}
      },
      {
        "id": 102,
        "title": "已消耗总流量 (出站)",
        "type": "stat",
        "gridPos": {"h": 4, "w": 12, "x": 12, "y": 0},
        "targets": [{"expr": "sum(increase(port_traffic_out_bytes{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\", user=~\"$user\"}[$__range]))"}],
        "fieldConfig": {"defaults": {"unit": "bytes", "color": {"mode": "value", "fixedColor": "orange"}}}
      },
      {
        "id": 1,
        "title": "【端口明细】入站带宽 (支持多选对比)",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4},
        "targets": [{"expr": "rate(port_traffic_in_bytes{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\", user=~\"$user\"}[1m]) * 8 / 1000000", "legendFormat": "{{alias}} | {{user}}"}],
        "fieldConfig": {"defaults": {"unit": "Mbps"}}
      },
      {
        "id": 2,
        "title": "【端口明细】出站带宽 (支持多选对比)",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4},
        "targets": [{"expr": "rate(port_traffic_out_bytes{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\", user=~\"$user\"}[1m]) * 8 / 1000000", "legendFormat": "{{alias}} | {{user}}"}],
        "fieldConfig": {"defaults": {"unit": "Mbps"}}
      },
      {
        "id": 3,
        "title": "【Top 10 排行】入站大户监控",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 12},
        "targets": [{"expr": "topk(10, rate(port_traffic_in_bytes{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\", user=~\"$user\"}[1m]) * 8 / 1000000)", "legendFormat": "{{alias}} | {{user}}"}],
        "fieldConfig": {"defaults": {"unit": "Mbps"}}
      },
      {
        "id": 4,
        "title": "【Top 10 排行】出站大户监控",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 12},
        "targets": [{"expr": "topk(10, rate(port_traffic_out_bytes{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\", user=~\"$user\"}[1m]) * 8 / 1000000)", "legendFormat": "{{alias}} | {{user}}"}],
        "fieldConfig": {"defaults": {"unit": "Mbps"}}
      },
      {
        "id": 5,
        "title": "【服务器】物理机入站总带宽",
        "type": "timeseries",
        "gridPos": {"h": 7, "w": 12, "x": 0, "y": 20},
        "targets": [{"expr": "rate(node_network_receive_bytes_total{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\", device!~\"lo|docker.*|veth.*|br-.*\"}[1m]) * 8 / 1000000", "legendFormat": "{{alias}} | 网卡: {{device}} (入站)"}],
        "fieldConfig": {"defaults": {"unit": "Mbps"}}
      },
      {
        "id": 6,
        "title": "【服务器】物理机出站总带宽",
        "type": "timeseries",
        "gridPos": {"h": 7, "w": 12, "x": 12, "y": 20},
        "targets": [{"expr": "rate(node_network_transmit_bytes_total{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\", device!~\"lo|docker.*|veth.*|br-.*\"}[1m]) * 8 / 1000000", "legendFormat": "{{alias}} | 网卡: {{device}} (出站)"}],
        "fieldConfig": {"defaults": {"unit": "Mbps"}}
      },
      {
        "id": 7,
        "title": "CPU 使用率 (%)",
        "type": "timeseries",
        "gridPos": {"h": 6, "w": 8, "x": 0, "y": 27},
        "targets": [{"expr": "100 - avg by (alias) (rate(node_cpu_seconds_total{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\", mode=\"idle\"}[1m])) * 100", "legendFormat": "{{alias}}"}],
        "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100}}
      },
      {
        "id": 8,
        "title": "内存 使用率 (%)",
        "type": "timeseries",
        "gridPos": {"h": 6, "w": 8, "x": 8, "y": 27},
        "targets": [{"expr": "(1 - node_memory_MemAvailable_bytes{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\"} / node_memory_MemTotal_bytes{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\"}) * 100", "legendFormat": "{{alias}}"}],
        "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100}}
      },
      {
        "id": 9,
        "title": "磁盘 使用率 (%)",
        "type": "timeseries",
        "gridPos": {"h": 6, "w": 8, "x": 16, "y": 27},
        "targets": [{"expr": "(1 - node_filesystem_avail_bytes{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\", mountpoint=\"/\"} / node_filesystem_size_bytes{job=~\"$job\", alias=~\"$alias\", instance=~\"$instance\", mountpoint=\"/\"}) * 100", "legendFormat": "{{alias}}"}],
        "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100}}
      }
    ],
    "schemaVersion": 39
  },
  "overwrite": true
}'
ENDSCRIPT

bash /tmp/import_dashboard_v4_3.sh
```

---

## 四、Grafana 面板查询参考 (更新至 V4 别名版)

### 主播/端口级别带宽

```promql
# 搜索特定主播的实时带宽（Mbps）
rate(port_traffic_in_bytes{user="虚拟主播-七七"}[1m]) * 8 / 1000000

# 带宽最高的 Top 10 主播大户
topk(10, rate(port_traffic_in_bytes[1m]) * 8 / 1000000)

# 特定主播的 累计消耗流量 (GB/MB)
sum(increase(port_traffic_in_bytes{user="虚拟主播-七七"}[24h]))
```

### 服务器整体带宽

```promql
# 特定物理机的整体入站带宽（排除虚拟网卡）
rate(node_network_receive_bytes_total{alias="沪日专线-01", device!~"lo|docker.*|veth.*|br-.*"}[1m]) * 8 / 1000000
```

### 硬件负载

```promql
# 特定机器的 CPU 使用率（%）
100 - avg by (alias) (rate(node_cpu_seconds_total{alias="沪日专线-01", mode="idle"}[1m])) * 100

# 特定机器的 内存使用率（%）
(1 - node_memory_MemAvailable_bytes{alias="沪日专线-01"} / node_memory_MemTotal_bytes{alias="沪日专线-01"}) * 100
```

---

## 五、批量部署（可选）

先在一台上验证通过后，用脚本批量推到所有服务器：

```bash
#!/bin/bash
SERVERS="IP1 IP2 IP3 IP4"
for ip in $SERVERS; do
  echo ">>> 部署 $ip"
  scp deploy_monitor.sh root@$ip:/tmp/
  ssh root@$ip "bash /tmp/deploy_monitor.sh"
done
```

**部署完成后，切记回管理机执行：**
`bash /server/monitor/prom_target.sh add relay <目标IP>:59999 <服务器别名>`
```
