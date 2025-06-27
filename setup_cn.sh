#!/bin/bash

set -e

print_message() {
    echo -e "\n===> $1"
}

check_status() {
    if [ $? -eq 0 ]; then
        print_message "成功: $1"
    else
        print_message "错误: $1 失败"
        exit 1
    fi
}

check_cuda_version() {
    if ! command -v nvidia-smi &> /dev/null; then
        print_message "nvidia-smi 未找到"
        return 1
    fi

    driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | cut -d. -f1)
    print_message "当前 NVIDIA 驱动版本: $driver_version"

    if [ -z "$driver_version" ] || [ "$driver_version" -lt 555 ]; then
        print_message "驱动版本过低，不满足 CUDA 12.5+ 要求"
        return 1
    fi

    print_message "驱动版本满足 CUDA 12.5+ 要求"
    return 0
}

check_requirements_installed() {
    if ! command -v docker &> /dev/null; then return 1; fi
    if ! dpkg -l | grep -q nvidia-container-toolkit; then return 1; fi
    if ! check_cuda_version; then return 1; fi
    return 0
}

if [ "$EUID" -ne 0 ]; then 
    print_message "请使用 sudo 运行本脚本"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

if check_requirements_installed; then
    print_message "依赖满足，跳过系统配置与驱动部署"
else
    print_message "更新系统..."
    apt update && apt upgrade -y
    check_status "系统更新"

    print_message "安装 NVIDIA Docker 环境..."
    curl -s https://gh-proxy.com/raw.githubusercontent.com/xiaoyu2691/node-x/refs/heads/main/env/install_nvidia_docker.sh | bash
    check_status "NVIDIA Docker 部署"

    print_message "重启 Docker 以应用 NVIDIA 运行时"
    systemctl restart docker
fi

export PROVE_PER_BPGU=1.01
export PGUS_PER_SECOND=10485606

print_message "欢迎使用 Succinct Prover 快速部署脚本 By 推特雪糕战神@Xuegaogx"
print_message "请确保你已在官网注册 Prover 地址：https://staking.sepolia.succinct.xyz/prover"

read -p "输入 Prover Address (0x...) ：" PROVER_ADDRESS
read -p "输入 Private Key（建议新钱包）：" PRIVATE_KEY

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

print_message "配置完成，启动 Prover 容器中..."
echo "PROVE_PER_BPGU: $PROVE_PER_BPGU"
echo "PGUS_PER_SECOND: $PGUS_PER_SECOND"
echo "PROVER_ADDRESS: $PROVER_ADDRESS"
echo "PRIVATE_KEY: [隐藏]"

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
