# 端口带宽监控部署指南

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
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=30d"
      - "--web.enable-lifecycle"
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

### 3. 创建 prometheus.yml

```yaml
global:
  scrape_interval: 5s

scrape_configs:
  - job_name: 'relay-servers'
    static_configs:
      - targets:
        - '中转1IP:9100'
        - '中转2IP:9100'

  - job_name: 'landing-servers'
    static_configs:
      - targets:
        - '落地1IP:9100'
        - '落地2IP:9100'
```

把 IP 换成实际服务器地址。

### 4. 启动

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

1. 浏览器打开 http://管理机IP:3000
2. 用 admin + 你设的密码登录
3. 左侧菜单 → 连接 → 数据源 → 添加数据源
4. 选 Prometheus，URL 填 http://prometheus:9090
5. 点 保存并测试，显示绿色就 OK

### 7. 后续管理服务器

将 prom_target.sh 放到 /server/monitor/ 目录下，用命令管理 target：

```bash
# 添加中转服务器
bash prom_target.sh add relay 1.2.3.4:59999

# 添加落地服务器
bash prom_target.sh add landing 5.6.7.8:59999

# 删除服务器
bash prom_target.sh del 1.2.3.4:59999

# 查看所有服务器
bash prom_target.sh list
```

添加和删除后会自动热重载 Prometheus，不用手动操作。

prom_target.sh 脚本内容：

```bash
#!/bin/bash
# Prometheus target 管理脚本
# 自动修复 Windows 换行符
if grep -qP '\r$' "$0" 2>/dev/null; then
  sed -i 's/\r$//' "$0"
  exec bash "$0" "$@"
fi
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

    if grep -q "$TARGET" "$CONFIG"; then
      echo "⚠ $TARGET 已存在，跳过"
      exit 0
    fi

    sed -i "/job_name: '$JOB_NAME'/,/job_name:/{/targets:/a\\        - '$TARGET'" "$CONFIG"
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
    ;;

  list)
    echo "===== 当前 targets ====="
    grep -E "^\s+- '" "$CONFIG" | sed "s/^[[:space:]]*- '//;s/'$//"
    ;;

  *)
    echo "用法:"
    echo "  $0 add relay <IP:端口>     添加中转服务器"
    echo "  $0 add landing <IP:端口>   添加落地服务器"
    echo "  $0 del <IP:端口>           删除服务器"
    echo "  $0 list                    查看所有服务器"
    ;;
esac
```

---

## 二、中转/落地服务器部署（一键脚本）

### 一键安装命令

国外服务器：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/farmer718/monitor-deploy-guide/main/deploy_monitor.sh)
```

国内服务器：

```bash
bash <(curl -Ls https://gitee.com/therfarmer/monitor-deploy-guide/raw/master/deploy_monitor.sh)
```

### 一键部署脚本 deploy_monitor.sh

将以下脚本保存为 deploy_monitor.sh，传到目标服务器上执行即可。
执行时会交互式询问端口配置，直接回车使用默认值。

```bash
#!/bin/bash
# 一键部署 node_exporter + 端口带宽采集脚本
# 自动修复 Windows 换行符
if grep -qP '\r$' "$0" 2>/dev/null; then
  sed -i 's/\r$//' "$0"
  exec bash "$0" "$@"
fi

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

# ========== 交互输入 ==========
read -p "请输入 node_exporter 监听端口 [默认 59999]: " input_port
NODE_EXPORTER_PORT=${input_port:-59999}

read -p "请输入带宽监控端口范围起始 [默认 10000]: " input_min
PORT_MIN=${input_min:-10000}

read -p "请输入带宽监控端口范围结束 [默认 63355]: " input_max
PORT_MAX=${input_max:-63355}

echo ""
echo "确认配置："
echo "  node_exporter 端口: ${NODE_EXPORTER_PORT}"
echo "  监控端口范围: ${PORT_MIN} - ${PORT_MAX}"
read -p "是否继续？[Y/n]: " confirm
if [[ "$confirm" =~ ^[nN] ]]; then
  echo "已取消"
  exit 0
fi
echo ""

# ========== 1. 安装 node_exporter ==========
echo ">>> 1. 安装 node_exporter"
cd /tmp
FILENAME="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
if [ ! -f "$FILENAME" ]; then
  wget -q "$DOWNLOAD_URL" -O "$FILENAME"
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

# ========== 3. 部署采集脚本 ==========
echo ">>> 3. 部署采集脚本"
mkdir -p /opt/scripts
cat > /opt/scripts/port_traffic.sh << SCRIPT
#!/bin/bash
PORT_MIN=${PORT_MIN}
PORT_MAX=${PORT_MAX}
OUTPUT="/var/lib/node_exporter/textfile/port_traffic.prom"
TMP="\${OUTPUT}.tmp"
HOSTNAME=\$(hostname)

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
  echo "port_traffic_in_bytes{port=\"\$port\",host=\"\$HOSTNAME\"} \${in_bytes:-0}" >> "\$TMP"
  echo "port_traffic_out_bytes{port=\"\$port\",host=\"\$HOSTNAME\"} \${out_bytes:-0}" >> "\$TMP"
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
cat /var/lib/node_exporter/textfile/port_traffic.prom
echo ""
echo "--- node_exporter 状态 ---"
systemctl is-active node_exporter
echo ""
echo "========================================="
echo "部署完成！"
echo "  node_exporter 端口: ${NODE_EXPORTER_PORT}"
echo "  监控端口范围: ${PORT_MIN} - ${PORT_MAX}"
echo "  请在管理机 prometheus.yml 中添加 target:"
echo "  $(hostname -I | awk '{print $1}'):${NODE_EXPORTER_PORT}"
echo "========================================="
```

### 单台部署

```bash
# 传到服务器上执行
scp deploy_monitor.sh root@服务器IP:/tmp/
ssh root@服务器IP "bash /tmp/deploy_monitor.sh"
```

### 批量部署

```bash
#!/bin/bash
# batch_deploy.sh
SERVERS="
1.1.1.1
2.2.2.2
3.3.3.3
"

for ip in $SERVERS; do
  echo "====== 部署 $ip ======"
  scp deploy_monitor.sh root@$ip:/tmp/
  ssh root@$ip "bash /tmp/deploy_monitor.sh"
  echo ""
done
```

### 部署后回管理机加 target

编辑 /server/monitor/prometheus.yml，加上服务器 IP（注意端口是 59999）：

```yaml
- '服务器IP:59999'
```

然后热重载：

```bash
curl -X POST http://localhost:9090/-/reload
```

打开 http://管理机IP:9090/targets 确认状态是 UP。

---

## 三、导入 Grafana 仪表盘

在管理机上执行以下命令（先把"你的密码"改成实际的 Grafana 密码）：

```bash
cat > /tmp/import_dashboard.sh << 'ENDSCRIPT'
curl -X POST http://admin:你的密码@localhost:3000/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d '{
  "dashboard": {
    "uid": "43d1b614-6b39-40a1-9c32-68a69188e995",
    "title": "直播带宽监控",
    "timezone": "browser",
    "refresh": "5s",
    "time": {"from": "now-1h", "to": "now"},
    "templating": {
      "list": [
        {
          "name": "instance",
          "label": "服务器",
          "type": "query",
          "query": "label_values(up, instance)",
          "refresh": 2,
          "includeAll": true,
          "multi": true,
          "current": {"selected": true, "text": "All", "value": "$__all"}
        },
        {
          "name": "port",
          "label": "端口",
          "type": "query",
          "query": "label_values(port_traffic_in_bytes{instance=~\"$instance\"}, port)",
          "refresh": 2,
          "includeAll": true,
          "multi": true,
          "current": {"selected": true, "text": "All", "value": "$__all"}
        }
      ]
    },
    "panels": [
      {"id":1,"title":"端口入站带宽 (Mbps)","type":"timeseries","gridPos":{"h":8,"w":12,"x":0,"y":0},"targets":[{"expr":"rate(port_traffic_in_bytes{instance=~\"$instance\",port=~\"$port\"}[1m]) * 8 / 1000000","legendFormat":"{{host}} - {{port}}"}],"fieldConfig":{"defaults":{"unit":"Mbps"},"overrides":[]}},
      {"id":2,"title":"端口出站带宽 (Mbps)","type":"timeseries","gridPos":{"h":8,"w":12,"x":12,"y":0},"targets":[{"expr":"rate(port_traffic_out_bytes{instance=~\"$instance\",port=~\"$port\"}[1m]) * 8 / 1000000","legendFormat":"{{host}} - {{port}}"}],"fieldConfig":{"defaults":{"unit":"Mbps"},"overrides":[]}},
      {"id":3,"title":"带宽 Top 10 端口","type":"timeseries","gridPos":{"h":8,"w":24,"x":0,"y":8},"targets":[{"expr":"topk(10, rate(port_traffic_in_bytes{instance=~\"$instance\",port=~\"$port\"}[1m]) * 8 / 1000000)","legendFormat":"{{host}} - {{port}}"}],"fieldConfig":{"defaults":{"unit":"Mbps"},"overrides":[]}},
      {"id":4,"title":"服务器入站带宽 (Mbps)","type":"timeseries","gridPos":{"h":8,"w":12,"x":0,"y":16},"targets":[{"expr":"rate(node_network_receive_bytes_total{instance=~\"$instance\",device!~\"lo|docker.*|veth.*|br-.*\"}[1m]) * 8 / 1000000","legendFormat":"{{instance}} - {{device}}"}],"fieldConfig":{"defaults":{"unit":"Mbps"},"overrides":[]}},
      {"id":5,"title":"服务器出站带宽 (Mbps)","type":"timeseries","gridPos":{"h":8,"w":12,"x":12,"y":16},"targets":[{"expr":"rate(node_network_transmit_bytes_total{instance=~\"$instance\",device!~\"lo|docker.*|veth.*|br-.*\"}[1m]) * 8 / 1000000","legendFormat":"{{instance}} - {{device}}"}],"fieldConfig":{"defaults":{"unit":"Mbps"},"overrides":[]}},
      {"id":6,"title":"CPU 使用率 (%)","type":"timeseries","gridPos":{"h":8,"w":8,"x":0,"y":24},"targets":[{"expr":"100 - avg by (instance) (rate(node_cpu_seconds_total{instance=~\"$instance\",mode=\"idle\"}[1m])) * 100","legendFormat":"{{instance}}"}],"fieldConfig":{"defaults":{"unit":"percent","min":0,"max":100},"overrides":[]}},
      {"id":7,"title":"内存使用率 (%)","type":"timeseries","gridPos":{"h":8,"w":8,"x":8,"y":24},"targets":[{"expr":"(1 - node_memory_MemAvailable_bytes{instance=~\"$instance\"} / node_memory_MemTotal_bytes{instance=~\"$instance\"}) * 100","legendFormat":"{{instance}}"}],"fieldConfig":{"defaults":{"unit":"percent","min":0,"max":100},"overrides":[]}},
      {"id":8,"title":"磁盘使用率 (%)","type":"timeseries","gridPos":{"h":8,"w":8,"x":16,"y":24},"targets":[{"expr":"(1 - node_filesystem_avail_bytes{instance=~\"$instance\",mountpoint=\"/\"} / node_filesystem_size_bytes{instance=~\"$instance\",mountpoint=\"/\"}) * 100","legendFormat":"{{instance}}"}],"fieldConfig":{"defaults":{"unit":"percent","min":0,"max":100},"overrides":[]}}
    ],
    "schemaVersion": 39
  },
  "overwrite": true
}'
ENDSCRIPT
```

执行导入：

```bash
sed -i 's/你的密码/实际密码/' /tmp/import_dashboard.sh
bash /tmp/import_dashboard.sh
```

返回 `"status":"success"` 就成功了。仪表盘顶部有两个下拉筛选框：
- 服务器：按 IP 筛选所有面板
- 端口：按端口号筛选，跟着服务器联动

---

## 四、Grafana 面板查询参考

### 端口级别带宽

```promql
# 每个端口实时带宽（Mbps）
rate(port_traffic_in_bytes[1m]) * 8 / 1000000

# 按服务器汇总
sum by (host) (rate(port_traffic_in_bytes[1m])) * 8 / 1000000

# 带宽最高的 Top 10 端口
topk(10, rate(port_traffic_in_bytes[1m]) * 8 / 1000000)

# 某个端口的入站+出站总带宽
(rate(port_traffic_in_bytes{port="10001"}[1m]) + rate(port_traffic_out_bytes{port="10001"}[1m])) * 8 / 1000000
```

### 服务器整体带宽

```promql
# 整体入站带宽（Mbps），自动匹配物理网卡，排除虚拟网卡
rate(node_network_receive_bytes_total{device!~"lo|docker.*|veth.*|br-.*"}[1m]) * 8 / 1000000

# 整体出站带宽（Mbps）
rate(node_network_transmit_bytes_total{device!~"lo|docker.*|veth.*|br-.*"}[1m]) * 8 / 1000000
```

### CPU

```promql
# CPU 使用率（%）
100 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100
```

### 内存

```promql
# 内存使用率（%）
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100
```

### 磁盘

```promql
# 磁盘使用率（%），mountpoint 按实际情况改
(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100
```

---

## 四、批量部署（可选）

先在一台上验证通过后，用脚本批量推到所有服务器：

```bash
#!/bin/bash
SERVERS="IP1 IP2 IP3 IP4"
for ip in $SERVERS; do
  echo ">>> 部署 $ip"
  scp /opt/scripts/port_traffic.sh root@$ip:/opt/scripts/
  ssh root@$ip "mkdir -p /opt/scripts /var/lib/node_exporter/textfile"
  ssh root@$ip "bash /tmp/deploy.sh"
done
```
