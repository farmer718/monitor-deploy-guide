#!/bin/bash
# 一键部署 node_exporter + 端口带宽采集脚本
# 用法: bash deploy_monitor.sh

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