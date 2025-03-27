#!/bin/bash

# 提示用户脚本加载完成，按回车继续
read -p "脚本已加载完成，按回车键继续执行..."

# 彩色输出函数
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

log_info() {
    echo -e "${GREEN}$1${NC}"
}

log_error() {
    echo -e "${RED}$1${NC}"
}

# 1. 更新apt
log_info "开始更新APT..."
apt update && apt upgrade -y
log_info "APT更新完成！"

# 2. 设置时区为北京时间
log_info "开始设置时区..."
timedatectl set-timezone Asia/Shanghai
log_info "时区设置为北京时间！"

# 3. 安装必要软件
log_info "安装必要软件（vim、wget、curl、vnstat）并配置..."
apt install -y vim wget curl vnstat
echo "set nopaste" > ~/.vimrc
log_info "必要软件安装完成，Vim 配置完成！"

# 4. 修改ssh配置
log_info "开始配置SSH..."

# 删除 /etc/ssh/sshd_config.d/ 下的所有文件
if [ -d /etc/ssh/sshd_config.d/ ]; then
    rm -f /etc/ssh/sshd_config.d/*
    log_info "/etc/ssh/sshd_config.d/ 目录中的文件已删除"
else
    log_info "/etc/ssh/sshd_config.d/ 目录中的没有文件"
fi

# 获取自定义SSH端口号
read -p "请输入新的SSH端口号（留空则随机选择10000~65535）： " ssh_port
if [[ -z "$ssh_port" ]]; then
    ssh_port=$((RANDOM % 55536 + 10000))
    log_info "使用随机生成的SSH端口号： $ssh_port"
else
    log_info "使用指定SSH端口号： $ssh_port"
fi

# 修改SSH端口
sed -i "/^#*Port /c\Port $ssh_port" /etc/ssh/sshd_config

# 获取公钥输入
read -p "请输入SSH公钥（留空则下载默认公钥）： " ssh_pubkey

# 如果输入为空，则下载默认公钥
if [[ -z "$ssh_pubkey" ]]; then
    log_info "未输入公钥，下载默认公钥..."
    ssh_pubkey=$(curl -fsSL http://static.1024.do/key.pub)
    if [[ -z "$ssh_pubkey" ]]; then
        log_error "默认公钥下载失败，保留密码登录"
    else
        log_info "默认公钥下载成功，已添加到 ~/.ssh/authorized_keys"
    fi
fi

# 如果获取到公钥，则写入 authorized_keys 并禁用密码登录
if [[ -n "$ssh_pubkey" ]]; then
    mkdir -p ~/.ssh
    echo "$ssh_pubkey" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
    log_info "公钥已添加到 ~/.ssh/authorized_keys"

    sed -i "s/^#PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^#PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    log_info "已禁用密码登录并开启密钥认证"
else
    log_error "未成功添加公钥，保留密码登录"
fi

# 重启SSH服务
systemctl restart ssh
log_info "SSH配置完成，新的端口号为 $ssh_port"

# 5. 开启BBR加速
log_info "开启BBR加速..."
sysctl_conf="/etc/sysctl.conf"
sed -i '/net.core.default_qdisc/d' $sysctl_conf
sed -i '/net.ipv4.tcp_congestion_control/d' $sysctl_conf
echo "net.core.default_qdisc=fq" >> $sysctl_conf
echo "net.ipv4.tcp_congestion_control=bbr" >> $sysctl_conf
sysctl -p
if lsmod | grep -q "bbr"; then
    log_info "BBR加速已启用！"
else
    log_error "BBR加速启用失败，请检查系统支持情况。"
fi

# 6. 配置~/.bashrc
log_info "配置~/.bashrc..."
cat <<EOF > ~/.bashrc
# ~/.bashrc: executed by bash(1) for non-login shells.

# Note: PS1 and umask are already set in /etc/profile. You should not
# need this unless you want different defaults for root.
# PS1='${debian_chroot:+(\$debian_chroot)}\h:\w\$ '
# umask 022

# You may uncomment the following lines if you want \`ls\` to be colorized:
export LS_OPTIONS='--color=auto'
eval "\$(dircolors)"
alias ls='ls \$LS_OPTIONS'
alias ll='ls \$LS_OPTIONS -lhF'
alias l='ls \$LS_OPTIONS -lA'

# Some more alias to avoid making mistakes:
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
EOF
log_info "~/.bashrc 配置完成！"

# 设置日志最大空间
sed -i 's/#SystemMaxUse=/SystemMaxUse=1G/' /etc/systemd/journald.conf && systemctl restart systemd-journald
log_info "系统日志最大可用空间设置完成！当前：1G"
echo "0 3 * * * root journalctl --vacuum-time=7d" > /etc/cron.d/cleanup_logs
log_info "已设置日志自动清理，每7天清理一次 /etc/cron.d/cleanup_logs"

# 设置登录信息
log_info "是否需要配置登录欢迎信息 (MOTD)？输入 y/n（默认n），3秒内未输入则默认不设置"
read -t 3 -p "您的选择： " setup_motd

if [[ "$setup_motd" == "y" || "$setup_motd" == "Y" ]]; then
    log_info "开始配置登录欢迎信息 (MOTD)..."

    cat <<'EOF' > /etc/update-motd.d/99-custom
#!/bin/bash
echo "===================================================="
echo "  欢迎使用Yuの VPS！"
echo "  $(date "+%Y-%m-%d %H:%M:%S") 服务器时间"
echo "===================================================="

echo "💻 系统信息"
echo "----------------------------------------------------"
echo "主机名       : $(hostname)"
echo "操作系统     : $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
echo "内核版本     : $(uname -r)"

echo ""
echo "🌐 网络信息"
echo "----------------------------------------------------"
echo "SSH 端口     : $(grep -oP '^Port \K[0-9]+' /etc/ssh/sshd_config)"

# 获取公网 IPv4 和 IPv6
ipv4=$(curl -4 -s ifconfig.me || echo "未检测到 IPv4")
ipv6=$(curl -6 -s ifconfig.me || echo "未检测到 IPv6")

echo "公网 IPv4    : $ipv4"
echo "公网 IPv6    : $ipv6"
echo "内网 IP      : $(hostname -I | awk '{print $1}')"

echo ""
echo "📊 资源使用情况"
echo "----------------------------------------------------"
echo "CPU 使用率   : $(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8"%"}')"
echo "内存使用     : $(free -h | awk '/^Mem:/ {print $3 " / " $2}')"
echo "磁盘使用     : $(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"

echo ""
echo "🛡  安全状态"
echo "----------------------------------------------------"
echo "BBR 加速     : $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
echo "Fail2Ban 状态: $(systemctl is-active fail2ban>/dev/null || echo "未安装")"
echo "防火墙状态   : $(ufw status | grep Status || echo "未安装")"

echo "===================================================="
EOF

    chmod +x /etc/update-motd.d/99-custom
    rm -f /etc/motd
    log_info "登录欢迎信息配置完成！"
else
    log_info "跳过登录欢迎信息配置"
fi

# 7. Docker安装选项
log_info "是否需要安装Docker？输入 y/n（默认n），3秒内未输入则默认不安装"
read -t 3 -p "您的选择： " install_docker

if [[ "$install_docker" == "y" || "$install_docker" == "Y" ]]; then
    log_info "开始安装Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh
    rm -f get-docker.sh
    log_info "Docker安装完成！"
else
    log_info "跳过Docker安装"
fi

# 8. Fail2ban安装配置
log_info "是否需要安装fail2ban（入侵防御系统）？输入 y/n（默认n）"
read -t 3 -p "您的选择： " install_fail2ban
if [[ "$install_fail2ban" == "y" || "$install_fail2ban" == "Y" ]]; then
    log_info "开始安装fail2ban..."
    apt install fail2ban -y
    log_info "fail2ban安装完成！"

    # 询问是否配置SSH规则
    read -t 3 -p "是否配置fail2ban的SSH防护规则？输入 y/n（默认y）： " configure_ssh_jail
    configure_ssh_jail=${configure_ssh_jail:-y}
    if [[ "$configure_ssh_jail" == "y" || "$configure_ssh_jail" == "Y" ]]; then
        log_info "配置fail2ban的SSH防护规则..."

        # 获取SSH端口号（默认使用已配置的端口）
        read -p "请输入需要防护的SSH端口（当前SSH端口为$ssh_port，回车默认）： " fail2ban_port
        fail2ban_port=${fail2ban_port:-$ssh_port}

        # 获取ban配置参数
        read -p "请输入封禁时长（默认24h）： " ban_time
        ban_time=${ban_time:-24h}

        # 创建自定义配置文件
        cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime  = 86400
findtime = 600
maxretry = 3
allowipv6 = true

[sshd]
enabled  = true
filter   = sshd
action   = iptables[name=SSH, port=$fail2ban_port, protocol=tcp]
logpath  = /var/log/journal/
backend  = systemd
maxretry = 3
bantime  = $ban_time
findtime = 600
EOF

        # 重启fail2ban服务
        systemctl restart fail2ban
        log_info "SSH防护规则已配置！端口：$fail2ban_port，封禁时长：$ban_time"
    else
        log_info "跳过fail2ban SSH规则配置"
    fi
else
    log_info "跳过fail2ban安装"
fi

# 添加是否设置Swap的选项
log_info "是否需要设置Swap？输入大小（单位GB），默认不设置，3秒内未输入也不设置"
read -t 3 -p "请输入Swap大小（单位GB）： " swap_size

if [[ -n "$swap_size" && "$swap_size" =~ ^[0-9]+$ ]]; then
    log_info "开始设置Swap，大小为 ${swap_size}G..."
    swapfile="/swapfile"
    dd if=/dev/zero of=$swapfile bs=1G count=$swap_size
    chmod 600 $swapfile
    mkswap $swapfile
    swapon $swapfile
    echo "$swapfile none swap sw 0 0" >> /etc/fstab
    log_info "Swap设置完成，大小为 ${swap_size}G"
else
    log_info "跳过Swap设置"
fi

log_info "初始化脚本执行完成！"
