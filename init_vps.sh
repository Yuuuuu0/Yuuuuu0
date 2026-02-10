#!/bin/bash

# ============================================
# VPS 初始化脚本 - 优化版本
# ============================================

set -euo pipefail  # 严格模式：遇到错误立即退出，未定义变量报错，管道命令失败立即退出

# 彩色输出函数
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # 无颜色

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# 错误处理函数
error_exit() {
    log_error "$1"
    exit 1
}

# 检查命令执行结果
check_cmd() {
    if ! "$@"; then
        error_exit "命令执行失败: $*"
    fi
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "此脚本需要 root 权限运行，请使用 sudo 执行"
    fi
}

# 检查系统类型
check_system() {
    if [[ ! -f /etc/debian_version ]] && [[ ! -f /etc/redhat-release ]]; then
        log_warn "未检测到 Debian/Ubuntu 或 CentOS/RHEL 系统，脚本可能无法正常工作"
        read -p "是否继续？(y/N): " -t 5 continue_anyway || continue_anyway="n"
        if [[ "$continue_anyway" != "y" && "$continue_anyway" != "Y" ]]; then
            exit 1
        fi
    fi
}

# 验证端口号
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        return 1
    fi
    # 检查端口是否被占用
    if command -v netstat &>/dev/null; then
        if netstat -tuln | grep -q ":$port "; then
            return 1
        fi
    elif command -v ss &>/dev/null; then
        if ss -tuln | grep -q ":$port "; then
            return 1
        fi
    fi
    return 0
}

# 备份文件
backup_file() {
    local file=$1
    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$backup" || error_exit "备份文件失败: $file"
        log_info "已备份文件: $file -> $backup"
    fi
}

# 统一交互超时时间（秒）
readonly READ_TIMEOUT=10

# ============================================
# 初始化检查
# ============================================
check_root
check_system

# 提示用户脚本加载完成，按回车继续
read -p "脚本已加载完成，按回车键继续执行..."

# ============================================
# 1. 更新 apt
# ============================================
log_info "开始更新APT..."
if ! apt update && apt upgrade -y; then
    log_error "APT更新失败，但继续执行..."
fi
log_info "APT更新完成！"

# ============================================
# 2. 设置时区为北京时间
# ============================================
log_info "开始设置时区..."
if timedatectl set-timezone Asia/Shanghai; then
    log_info "时区设置为北京时间！"
else
    log_error "时区设置失败"
fi

# ============================================
# 3. 安装必要软件
# ============================================
log_info "安装必要软件（vim、wget、curl、vnstat）并配置..."
if apt install -y vim wget curl vnstat; then
    log_info "必要软件安装完成"
else
    log_error "软件安装失败"
fi

# 配置 vim
cat > ~/.vimrc <<'EOF'
set nopaste
EOF
log_info "Vim 配置完成！"

# ============================================
# 4. 修改 SSH 配置
# ============================================
log_info "开始配置SSH..."

# 备份 SSH 配置文件
backup_file /etc/ssh/sshd_config

# 删除 /etc/ssh/sshd_config.d/ 下的所有文件
if [[ -d /etc/ssh/sshd_config.d/ ]]; then
    rm -f /etc/ssh/sshd_config.d/*
    log_info "/etc/ssh/sshd_config.d/ 目录中的文件已删除"
else
    log_info "/etc/ssh/sshd_config.d/ 目录不存在"
fi

# 获取自定义SSH端口号
while true; do
    read -p "请输入新的SSH端口号（留空则随机选择10000~65535）： " ssh_port
    if [[ -z "$ssh_port" ]]; then
        # 随机生成端口，确保在有效范围内
        ssh_port=$((RANDOM % 55536 + 10000))
        if validate_port "$ssh_port"; then
            log_info "使用随机生成的SSH端口号： $ssh_port"
            break
        else
            log_warn "随机端口 $ssh_port 不可用，重新生成..."
            continue
        fi
    else
        if validate_port "$ssh_port"; then
            log_info "使用指定SSH端口号： $ssh_port"
            break
        else
            log_error "端口号无效或已被占用，请重新输入"
        fi
    fi
done

# 修改SSH端口
sed -i "/^#*Port /c\Port $ssh_port" /etc/ssh/sshd_config

# 获取公钥输入
read -p "请输入SSH公钥（留空则下载默认公钥）： " ssh_pubkey

# 如果输入为空，则下载默认公钥
if [[ -z "$ssh_pubkey" ]]; then
    log_info "未输入公钥，下载默认公钥..."
    # 尝试 HTTPS，失败则回退到 HTTP
    ssh_pubkey=$(curl -fsSL https://static.1024.do/key.pub 2>/dev/null || curl -fsSL http://static.1024.do/key.pub 2>/dev/null)
    if [[ -z "$ssh_pubkey" ]]; then
        log_error "默认公钥下载失败，保留密码登录"
    else
        log_info "默认公钥下载成功"
    fi
fi

# 如果获取到公钥，则写入 authorized_keys 并禁用密码登录
if [[ -n "$ssh_pubkey" ]]; then
    mkdir -p ~/.ssh
    # 检查公钥是否已存在，避免重复添加
    if ! grep -Fxq "$ssh_pubkey" ~/.ssh/authorized_keys 2>/dev/null; then
        echo "$ssh_pubkey" >> ~/.ssh/authorized_keys
    fi
    chmod 600 ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
    log_info "公钥已添加到 ~/.ssh/authorized_keys"

    sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    log_info "已禁用密码登录并开启密钥认证"
else
    log_error "未成功添加公钥，保留密码登录"
fi

# 测试 SSH 配置
log_info "测试 SSH 配置..."
if sshd -t; then
    log_info "SSH 配置测试通过"
    # 重启SSH服务
    if systemctl restart ssh || systemctl restart sshd; then
        log_info "SSH服务重启成功"
    else
        log_error "SSH服务重启失败，请检查配置"
    fi
else
    log_error "SSH 配置测试失败，已恢复备份文件"
    if [[ -f /etc/ssh/sshd_config.backup.* ]]; then
        cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config
        systemctl restart ssh || systemctl restart sshd
    fi
    error_exit "SSH 配置错误，脚本已停止"
fi

log_info "SSH配置完成，新的端口号为 $ssh_port"
log_warn "请确保您可以使用新端口和密钥连接，否则可能无法再次登录！"

# ============================================
# 5. 开启 BBR 加速
# ============================================
log_info "开启BBR加速..."
sysctl_conf="/etc/sysctl.conf"

# 检查文件是否存在，如果不存在则创建它
if [[ ! -f "$sysctl_conf" ]]; then
    log_warn "配置文件 $sysctl_conf 不存在，正在创建..."
    touch "$sysctl_conf" || error_exit "创建 $sysctl_conf 失败"
fi

backup_file "$sysctl_conf"

sed -i '/net.core.default_qdisc/d' "$sysctl_conf"
sed -i '/net.ipv4.tcp_congestion_control/d' "$sysctl_conf"
echo "net.core.default_qdisc=fq" >> "$sysctl_conf"
echo "net.ipv4.tcp_congestion_control=bbr" >> "$sysctl_conf"

if sysctl -p >/dev/null 2>&1; then
    if lsmod | grep -q "bbr"; then
        log_info "BBR加速已启用！"
    else
        log_warn "BBR加速配置已添加，但内核模块未加载，可能需要重启系统"
    fi
else
    log_error "BBR加速配置失败"
fi

# ============================================
# 6. 配置 ~/.bashrc
# ============================================
log_info "配置~/.bashrc..."
backup_file ~/.bashrc

cat <<'EOF' > ~/.bashrc
# ~/.bashrc: executed by bash(1) for non-login shells.

# Note: PS1 and umask are already set in /etc/profile. You should not
# need this unless you want different defaults for root.
# PS1='${debian_chroot:+($debian_chroot)}\h:\w\$ '
# umask 022

# Fix backspace key (Ctrl+H / DEL mismatch)
if [ -t 0 ] && [ -n "${PS1:-}" ]; then
  case "$(stty -a 2>/dev/null)" in
    *"erase = ^?"*) stty erase '^H' 2>/dev/null || true ;;
    *"erase = ^H"*) stty erase '^?' 2>/dev/null || true ;;
    *) stty erase '^H' 2>/dev/null || true ;;
  esac
fi

# You may uncomment the following lines if you want `ls` to be colorized:
export LS_OPTIONS='--color=auto'
eval "$(dircolors)"
alias ls='ls $LS_OPTIONS'
alias ll='ls $LS_OPTIONS -lhF'
alias l='ls $LS_OPTIONS -lA'

# Some more alias to avoid making mistakes:
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# 
stty erase '^H'
EOF
log_info "~/.bashrc 配置完成！"

# ============================================
# 设置日志最大空间
# ============================================
log_info "设置系统日志最大可用空间..."
backup_file /etc/systemd/journald.conf

if sed -i 's/#SystemMaxUse=/SystemMaxUse=1G/' /etc/systemd/journald.conf; then
    systemctl restart systemd-journald || log_warn "systemd-journald 重启失败"
    log_info "系统日志最大可用空间设置完成！当前：1G"
else
    log_error "日志配置失败"
fi

# 设置日志自动清理
if [[ -d /etc/cron.d ]]; then
    echo "0 3 * * * root journalctl --vacuum-time=7d" > /etc/cron.d/cleanup_logs
    chmod 644 /etc/cron.d/cleanup_logs
    log_info "已设置日志自动清理，每7天清理一次"
else
    log_warn "cron.d 目录不存在，跳过日志清理配置"
fi

# ============================================
# 设置登录信息 (MOTD)
# ============================================
log_info "是否需要配置登录欢迎信息 (MOTD)？输入 y/n（默认n），${READ_TIMEOUT}秒内未输入则默认不设置"
read -t "$READ_TIMEOUT" -p "您的选择： " setup_motd || setup_motd="n"

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
echo "SSH 端口     : $(grep -oP '^Port \K[0-9]+' /etc/ssh/sshd_config 2>/dev/null || echo '未知')"

# 获取公网 IPv4 和 IPv6
ipv4=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || echo "未检测到 IPv4")
ipv6=$(curl -6 -s --max-time 3 ifconfig.me 2>/dev/null || echo "未检测到 IPv6")

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
echo "BBR 加速     : $(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || echo '未知')"
if systemctl is-active fail2ban >/dev/null 2>&1; then
    echo "Fail2Ban 状态: 运行中"
else
    echo "Fail2Ban 状态: 未安装或未运行"
fi
if command -v ufw &>/dev/null; then
    echo "防火墙状态   : $(ufw status | grep Status || echo '未知')"
else
    echo "防火墙状态   : 未安装"
fi

echo "===================================================="
EOF

    chmod +x /etc/update-motd.d/99-custom
    rm -f /etc/motd
    log_info "登录欢迎信息配置完成！"
else
    log_info "跳过登录欢迎信息配置"
fi

# ============================================
# 7. Docker 安装选项
# ============================================
log_info "是否需要安装Docker？输入 y/n（默认n），${READ_TIMEOUT}秒内未输入则默认不安装"
read -t "$READ_TIMEOUT" -p "您的选择： " install_docker || install_docker="n"

if [[ "$install_docker" == "y" || "$install_docker" == "Y" ]]; then
    log_info "开始安装Docker..."
    if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
        if sh /tmp/get-docker.sh; then
            rm -f /tmp/get-docker.sh
            log_info "Docker安装完成！"
        else
            log_error "Docker安装失败"
            rm -f /tmp/get-docker.sh
        fi
    else
        log_error "Docker安装脚本下载失败"
    fi
else
    log_info "跳过Docker安装"
fi

# ============================================
# 8. Fail2ban 安装配置
# ============================================
log_info "是否需要安装fail2ban（入侵防御系统）？输入 y/n（默认n），${READ_TIMEOUT}秒内未输入则默认不安装"
read -t "$READ_TIMEOUT" -p "您的选择： " install_fail2ban || install_fail2ban="n"

if [[ "$install_fail2ban" == "y" || "$install_fail2ban" == "Y" ]]; then
    log_info "开始安装fail2ban..."
    if apt install -y fail2ban; then
        log_info "fail2ban安装完成！"

        # 询问是否配置SSH规则
        read -t "$READ_TIMEOUT" -p "是否配置fail2ban的SSH防护规则？输入 y/n（默认y）： " configure_ssh_jail || configure_ssh_jail="y"
        configure_ssh_jail=${configure_ssh_jail:-y}
        
        if [[ "$configure_ssh_jail" == "y" || "$configure_ssh_jail" == "Y" ]]; then
            log_info "配置fail2ban的SSH防护规则..."

            # 获取SSH端口号（默认使用已配置的端口）
            read -p "请输入需要防护的SSH端口（当前SSH端口为$ssh_port，回车默认）： " fail2ban_port
            fail2ban_port=${fail2ban_port:-$ssh_port}

            # 验证端口
            if ! validate_port "$fail2ban_port"; then
                log_error "端口号无效，使用默认端口 $ssh_port"
                fail2ban_port=$ssh_port
            fi

            # 获取ban配置参数
            read -p "请输入封禁时长（默认24h，格式如：24h、1d、3600s）： " ban_time
            ban_time=${ban_time:-24h}

            # 备份原配置
            backup_file /etc/fail2ban/jail.local

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
            if systemctl restart fail2ban; then
                log_info "SSH防护规则已配置！端口：$fail2ban_port，封禁时长：$ban_time"
            else
                log_error "fail2ban 服务重启失败"
            fi
        else
            log_info "跳过fail2ban SSH规则配置"
        fi
    else
        log_error "fail2ban安装失败"
    fi
else
    log_info "跳过fail2ban安装"
fi

# ============================================
# 9. Swap 设置
# ============================================
log_info "是否需要设置Swap？输入大小（单位GB），默认不设置，${READ_TIMEOUT}秒内未输入也不设置"
read -t "$READ_TIMEOUT" -p "请输入Swap大小（单位GB）： " swap_size || swap_size=""

if [[ -n "$swap_size" && "$swap_size" =~ ^[0-9]+$ ]]; then
    swapfile="/swapfile"
    
    # 检查是否已存在 Swap
    if swapon --show | grep -q "$swapfile" || [[ -f "$swapfile" ]]; then
        log_warn "检测到已存在的 Swap 文件，是否删除并重新创建？(y/N)"
        read -t "$READ_TIMEOUT" -p "您的选择： " recreate_swap || recreate_swap="n"
        if [[ "$recreate_swap" == "y" || "$recreate_swap" == "Y" ]]; then
            swapoff "$swapfile" 2>/dev/null || true
            rm -f "$swapfile"
            # 从 fstab 中移除
            sed -i "\|$swapfile|d" /etc/fstab
        else
            log_info "保留现有 Swap，跳过设置"
            swap_size=""
        fi
    fi
    
    if [[ -n "$swap_size" ]]; then
        log_info "开始设置Swap，大小为 ${swap_size}G..."
        # 检查磁盘空间
        available_space=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
        if [[ "$available_space" -lt "$swap_size" ]]; then
            log_error "磁盘空间不足，可用空间：${available_space}G，需要：${swap_size}G"
        else
            # 用1M block，避免内存溢出
            if dd if=/dev/zero of="$swapfile" bs=1M count=$((swap_size * 1024)) status=progress; then
                chmod 600 "$swapfile"
                if mkswap "$swapfile" && swapon "$swapfile"; then
                    # 确保不会重复写入 fstab
                    if ! grep -q "$swapfile" /etc/fstab; then
                        echo "$swapfile none swap sw 0 0" >> /etc/fstab
                    fi
                    log_info "Swap设置完成，大小为 ${swap_size}G"
                else
                    log_error "Swap 激活失败"
                    rm -f "$swapfile"
                fi
            else
                log_error "Swap 文件创建失败"
            fi
        fi
    fi
else
    log_info "跳过Swap设置"
fi

# ============================================
# 完成
# ============================================
log_info "初始化脚本执行完成！"
log_info "重要提示："
log_info "1. SSH 新端口：$ssh_port"
log_info "2. 请确保可以使用新端口和密钥连接服务器"
log_info "3. 建议重启系统以确保所有配置生效"
