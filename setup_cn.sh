#!/bin/bash

# 遇到错误时立即退出
set -e

# 打印信息的函数
print_message() {
    echo "===> $1"
}

# 检查命令是否执行成功
check_status() {
    if [ $? -eq 0 ]; then
        print_message "成功: $1"
    else
        print_message "错误: $1 失败"
        exit 1
    fi
}

# 检测 CUDA/NVIDIA 驱动版本是否符合要求
check_cuda_version() {
    if ! command -v nvidia-smi &> /dev/null; then
        print_message "nvidia-smi 未找到"
        return 1
    fi

    driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | cut -d. -f1)
    print_message "当前 NVIDIA 驱动版本: $driver_version"

    if [ -z "$driver_version" ] || [ "$driver_version" -lt 555 ]; then
        print_message "驱动版本 $driver_version 低于 CUDA 12.5 需求"
        return 1
    fi

    print_message "驱动版本满足 CUDA 12.5+ 需求"
    return 0
}

# 检测 Docker/NVIDIA 完整环境
check_requirements_installed() {
    if ! command -v docker &> /dev/null; then return 1; fi
    if ! dpkg -l | grep -q nvidia-container-toolkit; then return 1; fi
    if ! check_cuda_version; then return 1; fi
    return 0
}

# 检测是否以 root 运行
if [ "$EUID" -ne 0 ]; then 
    print_message "请使用 sudo 运行本脚本"
    exit 1
fi

# 设置静默式 APT 前端
export DEBIAN_FRONTEND=noninteractive

# 如果已经部署过，则略过
if check_requirements_installed; then
    print_message "依赖已完成部署，跳过系统更新"
else
    print_message "更新系统包..."
    apt update && apt upgrade -y
    check_status "系统更新"

    print_message "执行 NVIDIA Docker 一键部署脚本..."
    bash -c "$(curl -s https://gh-proxy.com/raw.githubusercontent.com/xiaoyu2691/node-x/refs/heads/main/env/install_nvidia_docker.sh)"
    check_status "NVIDIA Docker 环境部署"
fi

# 配置 prover 参数
export PROVE_PER_BPGU=1.01
export PGUS_PER_SECOND=10485606

print_message "欢迎使用 Succinct Prover 部署脚本"
echo
print_message "请先前往 https://staking.sepolia.succinct.xyz/prover 创建 prover 地址"
read -p "输入 Prover Address (0x...) ：" PROVER_ADDRESS

print_message "输入用于进行 staking 的银包私钥"
print_message "建议使用新建银包，防止私钥泄露"
read -p "输入 Private Key：" PRIVATE_KEY

if [[ ! $PROVER_ADDRESS =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    print_message "错误: Prover Address 格式不正确"
    exit 1
fi

if [[ -z "$PRIVATE_KEY" ]]; then
    print_message "错误: 私钥不能为空"
    exit 1
fi

export PROVER_ADDRESS
export PRIVATE_KEY

print_message "配置完成，即将启动 prover"
echo "PROVE_PER_BPGU: $PROVE_PER_BPGU"
echo "PGUS_PER_SECOND: $PGUS_PER_SECOND"
echo "PROVER_ADDRESS: $PROVER_ADDRESS"
echo "PRIVATE_KEY: [隐藏]"

# 启动 docker prover 容器

docker run --gpus all \
    --network host \
    -e NETWORK_PRIVATE_KEY=$PRIVATE_KEY \
    -v /var/run/docker.sock:/var/run/docker.sock \
    public.ecr.aws/succinct-labs/spn-node:latest-gpu \
    prove \
    --rpc-url https://rpc.sepolia.succinct.xyz \
    --throughput $PGUS_PER_SECOND \
    --bid $PROVE_PER_BPGU \
    --private-key $PRIVATE_KEY \
    --prover $PROVER_ADDRESS
