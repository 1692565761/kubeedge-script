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

# 输出所有ready状态的edge节点
kubectl get nodes -o wide | awk 'NR>1{print $1"\t\t"$6"\t\t"$2}'

# 让用户输入要部署的节点名，并检查其是否是ready和edge节点
read -p "请输入要部署到哪个节点：" nodename
while ! kubectl get node $nodename &> /dev/null || \
      [[ $(kubectl get nodes -o wide $nodename | awk '{print $3}') != "agent,edge" ]]; do
    echo "当前节点不是edge节点或者不存在，请重新选择"
    read -p "请输入要部署到哪个节点：" nodename
done

# 重写counter-model.yaml文件
cat > /root/kubeedge-counter-demo/crds/kubeedge-counter-instance.yaml <<EOF
apiVersion: devices.kubeedge.io/v1alpha2
kind: Device
metadata:
  name: counter
  labels:
    description: 'counter'
spec:
  deviceModelRef:
    name: counter-model
  nodeSelector:
    nodeSelectorTerms:
    - matchExpressions:
      - key: ''
        operator: In
        values:
        - $nodename

status:
  twins:
    - propertyName: status
      desired:
        metadata:
          type: string
        value: 'OFF'
      reported:
        metadata:
          type: string
        value: '0'
EOF

# 部署kubeedge-counter-demo
kubectl apply -f /root/kubeedge-counter-demo/crds/kubeedge-counter-model.yaml
kubectl apply -f /root/kubeedge-counter-demo/crds/kubeedge-counter-instance.yaml

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
cd /root/kubeedge-counter-demo/web-controller-app
make && make docker

# 导出镜像到root目录下，并导入到containerd中
docker save kubeedge/kubeedge-counter-app:v1.0.0 -o /root/kubeedge-counter-app.tar
ctr -n k8s.io image import /root/kubeedge-counter-app.tar

# 输出镜像信息
crictl images | grep kubeedge-counter-app

# 重写kubeedge-web-controller-app.yaml文件
cat > /root/kubeedge-counter-demo/crds/kubeedge-web-controller-app.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    k8s-app: kubeedge-counter-app
  name: kubeedge-counter-app
  namespace: default
spec:
  selector:
    matchLabels:
      k8s-app: kubeedge-counter-app
  template:
    metadata:
      labels:
        k8s-app: kubeedge-counter-app
    spec:
      hostNetwork: true
      nodeName: mycloud
      containers:
      - name: kubeedge-counter-app
        image: kubeedge/kubeedge-counter-app:v1.0.0
        imagePullPolicy: IfNotPresent
      restartPolicy: Always
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kubeedge-counter
  namespace: default
rules:
- apiGroups: ["devices.kubeedge.io"]
  resources: ["devices"]
  verbs: ["get", "patch"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kubeedge-counter-rbac
  namespace: default
subjects:
  - kind: ServiceAccount
    name: default
roleRef:
  kind: Role
  name: kubeedge-counter
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f /root/kubeedge-counter-demo/crds/kubeedge-web-controller-app.yaml

# 重写kubeedge-pi-counter-app.yaml文件
cat > /root/kubeedge-counter-demo/crds/kubeedge-pi-counter-app.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    k8s-app: kubeedge-pi-counter
  name: kubeedge-pi-counter
  namespace: default
spec:
  selector:
    matchLabels:
      k8s-app: kubeedge-pi-counter
  template:
    metadata:
      labels:
        k8s-app: kubeedge-pi-counter
    spec:
      nodeName: $nodename
      hostNetwork: true
      containers:
      - name: kubeedge-pi-counter
        image: kubeedge/kubeedge-pi-counter:v1.0.0
        imagePullPolicy: IfNotPresent
      restartPolicy: Always
EOF

kubectl apply -f /root/kubeedge-counter-demo/crds/kubeedge-pi-counter-app.yaml