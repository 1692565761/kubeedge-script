#作者：王书展
#时间：2023-04-25
#版本：1.1
#环境：CentOS 7.9.2009 , root 用户, 需要国内网和国外网
#功能：部署kubeedge edge Counter Demo （KubeEdge 计数器演示）

#!/bin/bash

# 检查kubeedge-counter-demo文件夹是否存在，不存在则提示用户下载
if [[ ! -d kubeedge-counter-demo ]]; then
    echo "请下载kubeedge-counter-demo文件夹到当前目录 https://github.com/1692565761/kubeedge-script"
    exit 1
fi


# 安装go环境
if ! go version &> /dev/null; then
    wget https://golang.org/dl/go1.16.3.linux-amd64.tar.gz
    tar -C /usr/local -xzf go1.16.3.linux-amd64.tar.gz
    echo "export PATH=$PATH:/usr/local/go/bin" >> /etc/profile
    source /etc/profile
fi

# 启动docker服务
systemctl start docker

# 编译镜像
cd /root/kubeedge-counter-demo/counter-mapper
make && make docker