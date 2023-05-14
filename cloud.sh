#作者：王书展
#时间：2023-04-23
#版本：1.2
#环境：CentOS 7.9.2009 , root 用户, 需要国内网和国外网
#kubernetes版本：1.25.8
#kubeedgtes容器运行时：containerd
#kubeedge版本：1.13.0
#功能：安装kubeedge cloud节点


#让用户输入ip地址
read -p "请输入ip地址：" cloudip

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
    #设置主机名为mycloud
    hostnamectl set-hostname mycloud

    #判断hosts文件中是否包含 mycloud 字段 如果包含则不添加
    if [[ $(cat /etc/hosts | grep mycloud) == "" ]]; then
        echo "$cloudip mycloud" >> /etc/hosts
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
    yum install -y vim bash-completion lrzsz tar wget curl net-tools tee git
}


#安装docker函数
function install_docker(){
    wget https://mirrors.ustc.edu.cn/docker-ce/linux/centos/docker-ce.repo -O /etc/yum.repos.d/docker-ce.repo
    sed -i 's+download.docker.com+mirrors.ustc.edu.cn/docker-ce+' /etc/yum.repos.d/docker-ce.repo
    yum -y install docker-ce
    systemctl enable containerd
}

#安装kubernetes函数
function install_kubernetes(){
    #新建kubernetes.repo 内容为kubernets的源
    cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.tuna.tsinghua.edu.cn/kubernetes/yum/repos/kubernetes-el7-x86_64/
enabled=1
gpgcheck=0
EOF
    
    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    modprobe overlay
    modprobe br_netfilter

    # 设置所需的 sysctl 参数，参数在重新启动后保持不变
    cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    # 应用 sysctl 参数而不重新启动
    sysctl --system

    #重置的containerd的配置文件
    containerd config default  > /etc/containerd/config.toml
    #修改/etc/containerd/config.toml中的SystemdCgroup = true
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    #查看修改sandbox_image的值为k8s.dockerproxy.com/pause:3.8
    sed -i "s+$(cat /etc/containerd/config.toml | grep sandbox_image | awk -F '"' '{print $2}')+registry.aliyuncs.com/google_containers/pause:3.8+g" /etc/containerd/config.toml
    
    #编写/etc/crictl.yaml 
    cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
pull-image-on-create: false
disable-pull-on-run: false
EOF

    #重启containerd
    systemctl daemon-reload
    systemctl enable --now containerd

    #安装kubeadm-1.25.8 kubelet-1.25.8 kubectl-1.25.8
    yum install -y kubelet-1.25.8 kubeadm-1.25.8 kubectl-1.25.8    

    #在root目录下生成kubeadm.yaml
    cat > /root/kubeadm.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: abcdef.0123456789abcdef
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $cloudip
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  name: mycloud
  taints: null
---
apiServer:
  timeoutForControlPlane: 4m0s
apiVersion: kubeadm.k8s.io/v1beta3
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controllerManager: {}
dns: {}
etcd:
  local:
    dataDir: /var/lib/etcd
imageRepository: registry.aliyuncs.com/google_containers
kind: ClusterConfiguration
kubernetesVersion: 1.25.8
networking:
  dnsDomain: cluster.local
  serviceSubnet: 10.96.0.0/12
  podSubnet: 10.244.0.0/16
scheduler: {}
EOF

    #初始化kubernetes集群
    kubeadm init --config /root/kubeadm.yaml

    #将kubernetes的配置文件拷贝到root目录下
    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config


    #安装flannel网络插件
        cat > /root/kube-flannel.yml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  labels:
    k8s-app: flannel
    pod-security.kubernetes.io/enforce: privileged
  name: kube-flannel
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: flannel
  name: flannel
  namespace: kube-flannel
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    k8s-app: flannel
  name: flannel
rules:
- apiGroups:
  - ""
  resources:
  - pods
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - nodes/status
  verbs:
  - patch
- apiGroups:
  - networking.k8s.io
  resources:
  - clustercidrs
  verbs:
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    k8s-app: flannel
  name: flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
- kind: ServiceAccount
  name: flannel
  namespace: kube-flannel
---
apiVersion: v1
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "type": "flannel",
          "delegate": {
            "hairpinMode": true,
            "isDefaultGateway": true
          }
        },
        {
          "type": "portmap",
          "capabilities": {
            "portMappings": true
          }
        }
      ]
    }
  net-conf.json: |
    {
      "Network": "10.244.0.0/16",
      "Backend": {
        "Type": "vxlan"
      }
    }
kind: ConfigMap
metadata:
  labels:
    app: flannel
    k8s-app: flannel
    tier: node
  name: kube-flannel-cfg
  namespace: kube-flannel
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  labels:
    app: flannel
    k8s-app: flannel
    tier: node
  name: kube-flannel-ds
  namespace: kube-flannel
spec:
  selector:
    matchLabels:
      app: flannel
      k8s-app: flannel
  template:
    metadata:
      labels:
        app: flannel
        k8s-app: flannel
        tier: node
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/edge
                operator: DoesNotExist
      containers:
      - args:
        - --ip-masq
        - --kube-subnet-mgr
        command:
        - /opt/bin/flanneld
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: EVENT_QUEUE_DEPTH
          value: "5000"
        image: dockerproxy.com/flannel/flannel:v0.21.4
        name: kube-flannel
        resources:
          requests:
            cpu: 100m
            memory: 50Mi
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
            - NET_RAW
          privileged: false
        volumeMounts:
        - mountPath: /run/flannel
          name: run
        - mountPath: /etc/kube-flannel/
          name: flannel-cfg
        - mountPath: /run/xtables.lock
          name: xtables-lock
      hostNetwork: true
      initContainers:
      - args:
        - -f
        - /flannel
        - /opt/cni/bin/flannel
        command:
        - cp
        image: dockerproxy.com/flannel/flannel-cni-plugin:v1.1.2
        name: install-cni-plugin
        volumeMounts:
        - mountPath: /opt/cni/bin
          name: cni-plugin
      - args:
        - -f
        - /etc/kube-flannel/cni-conf.json
        - /etc/cni/net.d/10-flannel.conflist
        command:
        - cp
        image: dockerproxy.com/flannel/flannel:v0.21.4
        name: install-cni
        volumeMounts:
        - mountPath: /etc/cni/net.d
          name: cni
        - mountPath: /etc/kube-flannel/
          name: flannel-cfg
      priorityClassName: system-node-critical
      serviceAccountName: flannel
      tolerations:
      - effect: NoSchedule
        operator: Exists
      volumes:
      - hostPath:
          path: /run/flannel
        name: run
      - hostPath:
          path: /opt/cni/bin
        name: cni-plugin
      - hostPath:
          path: /etc/cni/net.d
        name: cni
      - configMap:
          name: kube-flannel-cfg
        name: flannel-cfg
      - hostPath:
          path: /run/xtables.lock
          type: FileOrCreate
        name: xtables-lock
EOF
    #应用flannel
    kubectl apply -f /root/kube-flannel.yml
}

#编写检测flannel容器是否启动成功函数
function check_flannel(){
    #检测flannel容器是否启动成功 flannel容器在kube-flannel命名空间下
    while true
    do
        #获取flannel容器的状态
        flannel_status=`kubectl get pods -n kube-flannel | grep kube-flannel | awk '{print $3}'`
        #判断flannel容器的状态是否为Running
        if [ $flannel_status == "Running" ];then
            break
        fi
        #等待5s
        wait
    done
}

#编写安装kubeedge函数
function install_kubeedge(){
    #此命令用于更新kube-system命名空间中所有daemon set的affinity规范，以确保它们的pod不会被调度到边缘节点上。
    kubectl get daemonset -n kube-system | grep -v NAME | awk '{print $1}' | xargs -n 1 kubectl patch daemonset -n kube-system --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/affinity", "value":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/edge","operator":"DoesNotExist"}]}]}}}}]'

    #删除master节点的污点
    kubectl taint nodes mycloud node-role.kubernetes.io/control-plane-

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
    #安装kubeedge
    keadm deprecated init --advertise-address=$cloudip  --kubeedge-version=1.13.0

    export CLOUDCOREIPS="$cloudip"

    #生成证书和密钥
    bash /root/certgen.sh genCertAndKey

    #stream 证书
    bash /root/certgen.sh stream
    fi
}

#编写等待函数,用来等待函数执行完成
function wait(){
    for i in {1..8}
    do
        echo -e "\033[34m 等待$i秒 \033[0m"
        sleep 1
    done
}

#编写主函数,并用红色打印出来当前正在执行的是哪个函数,并且调用上面的函数,并且等待函数执行完成,并且打印出来当前函数执行完成
#并且调用上面的等待函数
function main(){
    check_network
    check_system
    system_preparation 
    echo -e "\033[31m 系统预处理完成 \033[0m"
    wait
    install_docker
    echo -e "\033[31m docker安装完成 \033[0m"
    wait
    install_kubernetes 
    echo -e "\033[31m kubernetes安装完成 \033[0m"
    wait
    check_flannel 
    echo -e "\033[31mflannel启动成功\033[0m"
    wait
    install_kubeedge 
    echo -e "\033[31m kubeedge安装完成 \033[0m"
    wait
    #打印出边缘节点加入命令,并且将边缘节点加入命令打印出来，token通过keadm gettoken获得
    echo -e "\033[31m 边缘节点加入命令为: \033[0m"
    echo -e "\033[31m keadm join --cloudcore-ipport=$cloudip:10000 --profile version=v1.13.0 --token=$(keadm gettoken) \033[0m"
}

#调用主函数
main