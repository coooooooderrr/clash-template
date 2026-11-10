#!/usr/bin/env bash
# fix-dns.sh — 把系统 DNS 统一替换为 8.8.8.8 / 1.1.1.1
# 兼容: Ubuntu (netplan) / Debian (systemd-resolved / 静态 resolv.conf / ifupdown)
# 用法: sudo bash fix-dns.sh
# 特性: 自动识别配置方式 / 自动备份 / 幂等可重复 / 验证失败自动回滚
set -euo pipefail

WANT="8.8.8.8 1.1.1.1"
WANT1="8.8.8.8"
WANT2="1.1.1.1"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/dns-backup-$STAMP"

[[ $EUID -eq 0 ]] || { echo "错误: 请用 sudo 运行"; exit 1; }

# ========== 1/5 备份 ==========
echo "==> 1/5 备份到 $BACKUP_DIR"
for f in /etc/netplan /etc/systemd/network /etc/systemd/resolved.conf /etc/resolv.conf /etc/network/interfaces; do
    if [ -e "$f" ]; then
        mkdir -p "$BACKUP_DIR$(dirname "$f")"
        cp -a "$f" "$BACKUP_DIR$f"
    fi
done

rollback() {
    echo "❌ 验证失败，回滚..."
    cp -a "$BACKUP_DIR"/. /
    command -v netplan >/dev/null 2>&1 && ls /etc/netplan/*.yaml >/dev/null 2>&1 && netplan apply 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true
    echo "已回滚到原配置（备份在 $BACKUP_DIR）"
    exit 1
}

# ========== 2/5 检测 ==========
echo "==> 2/5 检测 DNS 配置方式"
if ls /etc/netplan/*.yaml >/dev/null 2>&1; then
    MODE="netplan"
elif [ -L /etc/resolv.conf ] && readlink /etc/resolv.conf 2>/dev/null | grep -qi "systemd"; then
    MODE="systemd"
else
    MODE="resolv"
fi
echo "    检测到: $MODE"

# ========== 3/5 修改 ==========
echo "==> 3/5 修改配置"
case "$MODE" in
netplan)
    python3 -c "import yaml" >/dev/null 2>&1 \
        || { echo "错误: netplan 模式需要 python3-yaml: apt install -y python3-yaml"; exit 1; }
    python3 - "$WANT1" "$WANT2" <<'PYEOF'
import yaml, glob, sys
WANT = [sys.argv[1], sys.argv[2]]
changed = 0
for f in sorted(glob.glob('/etc/netplan/*.yaml')):
    try:
        with open(f) as fh:
            doc = yaml.safe_load(fh) or {}
    except Exception as e:
        print(f"  [跳过] {f}: {e}", file=sys.stderr)
        continue
    if not isinstance(doc, dict) or not isinstance(doc.get('network'), dict):
        continue
    modified = False
    for key in ('ethernets', 'vlans', 'bonds', 'bridges'):
        for ifname, iconf in (doc['network'].get(key) or {}).items():
            if not isinstance(iconf, dict):
                continue
            if 'nameservers' in iconf:
                ns = iconf['nameservers'] or {}
                old = list(ns.get('addresses') or [])
                if old and old != WANT:
                    ns['addresses'] = WANT
                    iconf['nameservers'] = ns
                    modified = True
                    changed += 1
                    print(f"  [修改] {ifname}: {' '.join(old)} -> {' '.join(WANT)}")
    if modified:
        with open(f, 'w') as fh:
            yaml.safe_dump(doc, fh, default_flow_style=False, sort_keys=False)
if changed == 0:
    print("  当前已是目标值，无需修改")
PYEOF
    ;;

systemd)
    # 3a. 改 systemd-networkd 的 per-link DNS
    NETWORKD_CHANGED=0
    for f in /etc/systemd/network/*.network; do
        [ -f "$f" ] || continue
        if grep -qE '^\s*DNS=' "$f"; then
            sed -i -E "s/^\s*DNS=.*/DNS=$WANT/" "$f"
            echo "  [修改] $f: DNS=$WANT"
            NETWORKD_CHANGED=1
        fi
    done
    # 3b. 全局兜底也写上
    if [ -f /etc/systemd/resolved.conf ]; then
        if grep -qE '^\s*DNS=' /etc/systemd/resolved.conf; then
            sed -i -E "s/^\s*DNS=.*/DNS=$WANT/" /etc/systemd/resolved.conf
        elif grep -q '^\[Resolve\]' /etc/systemd/resolved.conf; then
            sed -i "/^\[Resolve\]/a DNS=$WANT" /etc/systemd/resolved.conf
        else
            printf '[Resolve]\nDNS=%s\n' "$WANT" >> /etc/systemd/resolved.conf
        fi
        echo "  [修改] /etc/systemd/resolved.conf: DNS=$WANT"
    else
        mkdir -p /etc/systemd
        printf '[Resolve]\nDNS=%s\n' "$WANT" > /etc/systemd/resolved.conf
        echo "  [新增] /etc/systemd/resolved.conf: DNS=$WANT"
    fi
    ;;

resolv)
    # 静态 resolv.conf（Debian 常见）
    if [ -L /etc/resolv.conf ]; then
        CONTENT=$(cat /etc/resolv.conf 2>/dev/null || true)
        rm -f /etc/resolv.conf
        printf '%s\n' "$CONTENT" > /etc/resolv.conf
        echo "  [注意] resolv.conf 原是符号链接，已替换为静态文件"
    fi
    sed -i '/^nameserver/d' /etc/resolv.conf
    printf 'nameserver %s\nnameserver %s\n' "$WANT1" "$WANT2" >> /etc/resolv.conf
    echo "  [修改] /etc/resolv.conf -> $WANT1 $WANT2"
    # ifupdown 的持久化配置也一并更新
    if [ -f /etc/network/interfaces ] && grep -q 'dns-nameservers' /etc/network/interfaces; then
        sed -i -E "s/^\s*dns-nameservers\s+.*/dns-nameservers $WANT/" /etc/network/interfaces
        echo "  [修改] /etc/network/interfaces: dns-nameservers $WANT"
    fi
    ;;
esac

# ========== 4/5 应用 ==========
echo "==> 4/5 应用配置"
case "$MODE" in
netplan)
    chmod 600 /etc/netplan/*.yaml
    netplan apply
    ;;
systemd)
    [ "$NETWORKD_CHANGED" = "1" ] && networkctl reload 2>/dev/null || true
    systemctl restart systemd-resolved
    ;;
esac
sleep 2

# ========== 5/5 验证 ==========
echo "==> 5/5 验证"
if getent hosts google.com >/dev/null 2>&1; then
    echo "✅ DNS 解析正常，当前生效的 DNS:"
    if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then
        resolvectl status | grep -E "^Link|DNS Servers" || true
    else
        grep ^nameserver /etc/resolv.conf
    fi
    echo ""
    echo "完成。原配置备份在 $BACKUP_DIR"
else
    rollback
fi
