#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/alpine-release ]]; then
    release="alpine"
elif [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(arch)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

os_version=""

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release -y
        yum install wget curl unzip tar crontabs socat -y
    elif [[ x"${release}" == x"alpine" ]]; then
        # Alpine 环境依赖安装
        apk update
        apk add wget curl unzip tar socat
        # 安装 gcompat 解决 glibc 二进制程序的动态链接问题
        apk add gcompat libc6-compat
    else
        apt update -y
        apt install wget curl unzip tar cron socat -y
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ x"${release}" == x"alpine" ]]; then
        if [[ ! -f /etc/init.d/XrayR ]]; then
            return 2
        fi
        # Alpine OpenRC 状态检查
        rc-service XrayR status >/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            return 0
        else
            return 1
        fi
    else
        if [[ ! -f /etc/systemd/system/XrayR.service ]]; then
            return 2
        fi
        temp=$(systemctl status XrayR | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

install_acme() {
    curl https://get.acme.sh | sh
}

install_XrayR() {
    if [[ -e /usr/local/XrayR/ ]]; then
        rm /usr/local/XrayR/ -rf
    fi

    mkdir /usr/local/XrayR/ -p
    cd /usr/local/XrayR/

    if [ $# == 0 ] ;then
        last_version=$(curl -Ls "https://api.github.com/repos/liuliu2018/XrayR/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}检测 XrayR 版本失败，可能是超出 Github API 限制，请稍后再试，或手动指定 XrayR 版本安装${plain}"
            exit 1
        fi
        echo -e "检测到 XrayR 最新版本：${last_version}，开始安装"
        wget -q -N --no-check-certificate -O /usr/local/XrayR/XrayR-linux.zip https://github.com/liuliu2018/XrayR/releases/download/${last_version}/XrayR-linux-${arch}.zip
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 XrayR 失败，请确保你的服务器能够下载 Github 的文件${plain}"
            exit 1
        fi
    else
        if [[ $1 == v* ]]; then
            last_version=$1
        else
            last_version="v"$1
        fi
        url="https://github.com/liuliu2018/XrayR/releases/download/${last_version}/XrayR-linux-${arch}.zip"
        echo -e "开始安装 XrayR ${last_version}"
        wget -q -N --no-check-certificate -O /usr/local/XrayR/XrayR-linux.zip ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 XrayR ${last_version} 失败，请确保此版本存在${plain}"
            exit 1
        fi
    fi

    unzip XrayR-linux.zip
    rm XrayR-linux.zip -f
    chmod +x XrayR
    mkdir /etc/XrayR/ -p

    # 根据系统安装不同的守护服务
    if [[ x"${release}" == x"alpine" ]]; then
        # 生成 Alpine 的 OpenRC 启动脚本
        cat << 'EOF' > /etc/init.d/XrayR
#!/sbin/openrc-run

description="XrayR Service"
command="/usr/local/XrayR/XrayR"
command_args="--config /etc/XrayR/config.yml"
command_background="yes"
pidfile="/run/XrayR.pid"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/XrayR
        rc-update add XrayR default
        echo -e "${green}XrayR ${last_version}${plain} 安装完成，已设置 OpenRC 开机自启"
    else
        # Systemd 系统
        rm /etc/systemd/system/XrayR.service -f
        file="https://github.com/liuliu2018/XrayR-release/raw/master/XrayR.service"
        wget -q -N --no-check-certificate -O /etc/systemd/system/XrayR.service ${file}
        systemctl daemon-reload
        systemctl stop XrayR
        systemctl enable XrayR
        echo -e "${green}XrayR ${last_version}${plain} 安装完成，已设置 Systemd 开机自启"
    fi

    cp geoip.dat /etc/XrayR/
    cp geosite.dat /etc/XrayR/ 

    if [[ ! -f /etc/XrayR/config.yml ]]; then
        cp config.yml /etc/XrayR/
        echo -e ""
        echo -e "全新安装，请先参看教程：https://github.com/XrayR-project/XrayR，配置必要的内容"
    else
        if [[ x"${release}" == x"alpine" ]]; then
            rc-service XrayR restart
        else
            systemctl start XrayR
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}XrayR 重启成功${plain}"
        else
            echo -e "${red}XrayR 可能启动失败，请稍后使用 XrayR log 查看日志信息${plain}"
        fi
    fi

    if [[ ! -f /etc/XrayR/dns.json ]]; then
        cp dns.json /etc/XrayR/
    fi
    if [[ ! -f /etc/XrayR/route.json ]]; then
        cp route.json /etc/XrayR/
    fi
    if [[ ! -f /etc/XrayR/custom_outbound.json ]]; then
        cp custom_outbound.json /etc/XrayR/
    fi
    if [[ ! -f /etc/XrayR/custom_inbound.json ]]; then
        cp custom_inbound.json /etc/XrayR/
    fi
    if [[ ! -f /etc/XrayR/rulelist ]]; then
        cp rulelist /etc/XrayR/
    fi

    # 注意：原本的 XrayR.sh 管理菜单脚本内部基本全是 systemctl 命令，
    # 如果在 Alpine 上使用原版 XrayR.sh 菜单会报错。
    # 这里建议配合 Alpine 专用指令或后续单独重写管理菜单。
    curl -o /usr/bin/XrayR -Ls https://raw.githubusercontent.com/liuliu2018/XrayR-release/master/XrayR.sh
    chmod +x /usr/bin/XrayR
    ln -s /usr/bin/XrayR /usr/bin/xrayr 2>/dev/null
    chmod +x /usr/bin/xrayr 2>/dev/null
    cd $cur_dir
    rm -f install.sh
    
    echo -e ""
    if [[ x"${release}" == x"alpine" ]]; then
        echo "Alpine Linux 快捷管理命令: "
        echo "------------------------------------------"
        echo "rc-service XrayR start    - 启动 XrayR"
        echo "rc-service XrayR stop     - 停止 XrayR"
        echo "rc-service XrayR restart  - 重启 XrayR"
        echo "rc-service XrayR status   - 查看 XrayR 状态"
        echo "------------------------------------------"
    else
        echo "XrayR 管理脚本使用方法: "
        echo "------------------------------------------"
        echo "XrayR                    - 显示管理菜单"
        echo "XrayR start              - 启动 XrayR"
        echo "XrayR stop               - 停止 XrayR"
        echo "XrayR restart            - 重启 XrayR"
        echo "------------------------------------------"
    fi
}

echo -e "${green}开始安装${plain}"
install_base
install_XrayR $1
