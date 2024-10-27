#!/bin/bash

# 提示用户脚本加载完成，按回车继续
read -p "脚本已加载完成，按回车键继续执行..."

# 彩色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

# 1. 更新apt
echo -e "${GREEN}开始更新APT...${NC}"
apt update && apt upgrade -y
echo -e "${GREEN}APT更新完成！${NC}"

# 2. 设置时区为北京时间
echo -e "${GREEN}开始设置时区...${NC}"
timedatectl set-timezone Asia/Shanghai
echo -e "${GREEN}时区设置为北京时间！${NC}"

# 3. 安装vim，配置~/.vimrc
echo -e "${GREEN}安装Vim并配置...${NC}"
apt install -y vim
echo "set nopaste" > ~/.vimrc
echo -e "${GREEN}Vim安装完成并配置完成！${NC}"

# 4. 安装vnstat
echo -e "${GREEN}开始安装vnstat...${NC}"
apt install -y vnstat
echo -e "${GREEN}vnstat安装完成！${NC}"

# 5. 修改ssh配置
echo -e "${GREEN}开始配置SSH...${NC}"

# 删除 /etc/ssh/sshd_config.d/ 下的所有文件
if [ -d /etc/ssh/sshd_config.d/ ]; then
    rm -f /etc/ssh/sshd_config.d/*
    echo -e "${GREEN}/etc/ssh/sshd_config.d/ 目录中的文件已删除${NC}"
else
    echo -e "${GREEN}/etc/ssh/sshd_config.d/ 目录中的没有文件${NC}"
fi

# 获取自定义SSH端口号
read -p "请输入新的SSH端口号（留空则随机选择10000~65535）： " ssh_port
if [[ -z "$ssh_port" ]]; then
    ssh_port=$((RANDOM % 55536 + 10000))
fi

# 修改SSH端口
sed -i "/^#*Port /c\Port $ssh_port" /etc/ssh/sshd_config

# 获取公钥输入
read -p "请输入SSH公钥（留空则保留密码登录）： " ssh_pubkey

# 如果输入了公钥，则写入authorized_keys并禁用密码登录
if [[ -n "$ssh_pubkey" ]]; then
    # 创建~/.ssh目录并写入公钥
    mkdir -p ~/.ssh
    echo "$ssh_pubkey" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
    echo -e "${GREEN}公钥已添加到~/.ssh/authorized_keys${NC}"

    # 禁用密码登录，开启密钥认证
    sed -i "s/^#PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^#PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    echo -e "${GREEN}已禁用密码登录并开启密钥认证${NC}"
else
    echo -e "${RED}未输入公钥，保留密码登录${NC}"
fi

# 重启SSH服务
systemctl restart ssh
echo -e "${GREEN}SSH配置完成，新的端口号为 $ssh_port${NC}"


echo -e "${GREEN}初始化脚本执行完成！${NC}"
