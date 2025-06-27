#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

detect_system() {
    log_info "检测系统信息..."
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
        CODENAME=$VERSION_CODENAME
    else
        log_error "无法检测操作系统"; exit 1
    fi
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armhf" ;;
        *) log_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    log_success "系统: $PRETTY_NAME | 架构: $ARCH"
}

update_system() {
    log_info "更新系统包..."
    DEBIAN_FRONTEND=noninteractive sudo apt-get update
    packages=(apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common wget unzip)
    for package in "${packages[@]}"; do
        dpkg -l | grep -q "$package" || DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "$package"
    done
    log_success "系统包更新完成"
}

configure_apt_sources() {
    log_info "配置阿里云APT镜像源..."
    [[ -f /etc/apt/sources.list ]] && cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d_%H%M%S)
    case $OS in
        ubuntu)
            cat > /etc/apt/sources.list << UBUNTUEOF
deb https://mirrors.aliyun.com/ubuntu/ $CODENAME main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ $CODENAME-security main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ $CODENAME-updates main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ $CODENAME-proposed main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ $CODENAME-backports main restricted universe multiverse
UBUNTUEOF
            ;;
        debian)
            cat > /etc/apt/sources.list << DEBIANEOF
deb https://mirrors.aliyun.com/debian/ $CODENAME main non-free contrib
deb https://mirrors.aliyun.com/debian-security/ $CODENAME-security main
deb https://mirrors.aliyun.com/debian/ $CODENAME-updates main non-free contrib
deb https://mirrors.aliyun.com/debian/ $CODENAME-backports main non-free contrib
DEBIANEOF
            ;;
        *) log_warning "未明确支持的系统: $OS，跳过镜像源配置" ;;
    esac
    log_success "已配置阿里云APT镜像源"
}

detect_gpu() {
    log_info "检测显卡..."
    if command -v lspci >/dev/null; then
        NVIDIA_GPUS=$(lspci | grep -i nvidia | grep -i vga)
        if [[ -n "$NVIDIA_GPUS" ]]; then
            HAS_NVIDIA=true
            GPU_MODEL=$(echo "$NVIDIA_GPUS" | head -1 | sed 's/.*NVIDIA Corporation //' | sed 's/ \[.*\]//')
            log_success "检测到NVIDIA显卡: $GPU_MODEL"
        else
            HAS_NVIDIA=false; log_info "未检测到NVIDIA显卡"
        fi
    else
        log_warning "lspci命令不可用"; HAS_NVIDIA=false
    fi

    if command -v nvidia-smi >/dev/null; then
        NVIDIA_DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -1)
        CUDA_VERSION=$(nvidia-smi | grep -oP 'CUDA Version: \K[0-9.]+')
        log_success "NVIDIA驱动: $NVIDIA_DRIVER_VERSION | CUDA: $CUDA_VERSION"
        HAS_NVIDIA_DRIVER=true
    else
        HAS_NVIDIA_DRIVER=false
    fi
}

install_nvidia_docker() {
    if [[ "$HAS_NVIDIA" != "true" ]]; then
        log_info "未检测到NVIDIA显卡，跳过nvidia-docker安装"; return
    fi
    log_info "安装NVIDIA容器支持..."

    if [[ "$HAS_NVIDIA_DRIVER" != "true" ]]; then
        log_info "安装NVIDIA驱动..."
        add-apt-repository -y ppa:graphics-drivers/ppa && sudo apt-get update
        RECOMMENDED_DRIVER=$(ubuntu-drivers devices | grep recommended | awk '{print $3}' | head -1)
        sudo apt-get install -y "${RECOMMENDED_DRIVER:-nvidia-driver-535}"
        log_warning "驱动安装完成，需重启系统后再运行脚本继续"
        exit 0
    fi

    if ! dpkg -l | grep -q nvidia-container-toolkit; then
        log_info "安装nvidia-container-toolkit..."
        distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
        curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list
        sudo apt-get update
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y nvidia-container-toolkit nvidia-cuda-toolkit
        nvidia-ctk runtime configure --runtime=docker
        cat > /etc/docker/daemon.json << EOF
{
    "registry-mirrors": [
        "https://registry.cn-hangzhou.aliyuncs.com",
        "https://mirror.ccs.tencentyun.com",
        "https://reg-mirror.qiniu.com"
    ],
    "log-driver": "json-file",
    "log-opts": { "max-size": "100m", "max-file": "3" },
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": { "path": "nvidia-container-runtime", "runtimeArgs": [] }
    }
}
EOF
        systemctl restart docker
        log_success "NVIDIA Docker支持安装完成"
    else
        log_info "nvidia-container-toolkit已安装，跳过"
    fi
}

test_installation() {
    log_info "测试Docker..."
    sudo systemctl is-active --quiet docker || { log_warning "Docker未运行，正在重启"; sudo systemctl restart docker; }
    sudo docker run --rm hello-world &>/dev/null && log_success "Docker正常" || log_error "Docker测试失败"
    if [[ "$HAS_NVIDIA" == "true" && "$HAS_NVIDIA_DRIVER" == "true" ]]; then
        log_info "测试NVIDIA Docker..."
        sudo docker run --rm --gpus all nvidia/cuda:12.3.2-base-ubuntu22.04 nvidia-smi &>/dev/null && log_success "NVIDIA Docker正常" || log_warning "NVIDIA Docker测试失败"
    fi
}

domestic_docker_install() {
    log_info "开始国内Docker安装..."
    detect_system; update_system; configure_apt_sources
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $CODENAME stable" | sudo tee /etc/apt/sources.list.d/docker.list
    sudo apt-get update; sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker; systemctl restart docker
    detect_gpu; install_nvidia_docker; test_installation
}

foreign_docker_install() {
    log_info "开始国外Docker安装..."
    detect_system; update_system
    if ! command -v docker &>/dev/null; then curl -fsSL https://get.docker.com | sh; fi
    detect_gpu; install_nvidia_docker; test_installation
}

sudo apt-get update
for pkg in curl snap jq; do
    if ! command -v $pkg &>/dev/null; then log_info "$pkg 未安装，正在安装..."; sudo apt install -y $pkg; fi
done

IP_ADDRESS=$(curl -s http://ipinfo.io/ip)
LOCATION=$(curl -s "http://ip-api.com/json/$IP_ADDRESS" | jq -r '.country')
[[ "$LOCATION" == "China" ]] && log_info "检测到国内IP" && domestic_docker_install || log_info "检测到国外IP" && foreign_docker_install
