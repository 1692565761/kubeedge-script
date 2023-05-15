#作者：王书展
#时间：2023-04-23
#版本：1.1
#环境：CentOS 7.9.2009 , root 用户, 需要国内网和国外网
#容器运行时：docker
#kubeedge版本：1.13.0
#功能：安装kubeedge edge节点

#让用户输入ip地址
read -p "请输入cloudip地址：" cloudip

#让用户输入当前节点的名称
read -p "请输入当前节点的名称：" nodename

#编写环境检查函数
function check_system(){
    if [[ ! -f /etc/redhat-release ]] || [[ $(awk '{print $4}' /etc/redhat-release) != "7.9.2009" ]] || [[ $UID -ne 0 ]]; then
        echo "请在 CentOS 7.9.2009 的 root 用户下运行此脚本"
        exit 1
    fi
}

#判断当前系统是否有网
function check_network(){
    if [[ $(ping -c 1 www.baidu.com | grep "100% packet loss") != "" ]]; then
        echo "当前系统无法访问外网，请检查网络"
        exit 1
    fi
}

#编写系统预处理函数
function system_preparation(){
    #设置主机名为$nodename
    hostnamectl set-hostname $nodename

    #判断hosts文件中是否包含 myedge 字段 如果包含则不添加
    if [[ $(cat /etc/hosts | grep $nodename) == "" ]]; then
        echo "$cloudip mycloud" >> /etc/hosts
        #获取hostname -i 的ip地址
        ip=$(hostname -i)
        # 添加hosts
        echo "$ip $nodename" >> /etc/hosts
    fi

    #设置时区为中国上海
    timedatectl set-timezone Asia/Shanghai

    #修改chrony配置文件 同步阿里云的时间服务器
    sed -i "s/0.centos.pool.ntp.org/ntp.aliyun.com/g" /etc/chrony.conf && systemctl restart chronyd

    #关闭防火墙
    systemctl stop firewalld && systemctl disable firewalld

    #关闭selinux
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config && setenforce 0

    # 设置yum源为ustc
    sed -i.bak \
        -e 's|^mirrorlist=|#mirrorlist=|g' \
        -e 's|^#baseurl=http://mirror.centos.org/centos|baseurl=https://mirrors.ustc.edu.cn/centos|g' \
        /etc/yum.repos.d/CentOS-Base.repo

    # 安装必要软件包
    yum install -y vim bash-completion lrzsz tar wget curl net-tools tee
}


#安装docker函数
function install_docker(){
    wget https://mirrors.ustc.edu.cn/docker-ce/linux/centos/docker-ce.repo -O /etc/yum.repos.d/docker-ce.repo
    #修改docker源为ustc
    sed -i 's+download.docker.com+mirrors.ustc.edu.cn/docker-ce+' /etc/yum.repos.d/docker-ce.repo
    #安装docker
    yum -y install docker-ce
    #启动docker
    systemctl enable docker
    #设置docker加速器
    mkdir -p /etc/docker
    #设置daemon
    cat > /etc/docker/daemon.json <<EOF
    {
      "registry-mirrors": ["https://dockerproxy.com"]
    }
EOF
    #重载配置
    systemctl daemon-reload
    #重启docker
    systemctl restart docker
}

#安装kubeedge函数
function install_kubeedge(){
    #判断当前目录下是否有keadm-v1.13.0-linux-amd64.tar.gz，如果没有则从github下载
    if [ ! -f keadm-v1.13.0-linux-amd64.tar.gz ];then
        if ping -c 1 github.com;then
            echo "可以访问github"
            wget https://github.com/kubeedge/kubeedge/releases/download/v1.13.0/keadm-v1.13.0-linux-amd64.tar.gz
        else
            echo "不能访问github，请检查网络，或从github下载keadm-v1.13.0-linux-amd64.tar.gz到当前目录"
            exit
        fi
    
    #解压keadm-v1.13.0-linux-amd64.tar.gz
    tar -zxvf keadm-v1.13.0-linux-amd64.tar.gz
    #添加执行权限 # 并且将keadm拷贝到/usr/local/bin目录下
    chmod +x keadm-v1.13.0-linux-amd64/keadm/keadm && cp keadm-v1.13.0-linux-amd64/keadm/keadm /usr/local/bin/keadm

    #获取用户输入的token
    read -p "请输入token：" token

    #加入云端,指定运行时为docker,并且指定kubeedge版本为1.13.0,并且指定云端的ip地址和端口,并且指定token
    keadm join --cloudcore-ipport=$cloudip:10000 --token=$token --kubeedge-version=1.13.0 --runtimetype=docker

    #修改edgecore配置文件,使edgecore可以访问云端,并且启用edgeStream,这样就可以在云端看到当前节点的状态
    sed -i '/^  edgeStream:/,/^[^ ]/ s/enable: false/enable: true/' /etc/kubeedge/config/edgecore.yaml 

    #重启edgecore
    systemctl restart edgecore

    #用红色打印出来安装kubeedge任务已经完成
    echo -e "\033[31m当前任务已经完成\033[0m"
    fi
}

#调用上面的函数
check_system
check_network
system_preparation
install_docker
install_kubeedge
