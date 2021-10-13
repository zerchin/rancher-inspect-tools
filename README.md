# rancher-inspect-tools

## 简介
- 基于Rancher-URL对Rancher集群进行巡检
- 对所有k8s节点进行巡检

## 用法
1. 基于Rancher-URL对Rancher集群进行巡检

下载`scripts/rancherinfo.sh`脚本到主机上执行即可
```bash
wget https://raw.githubusercontent.com/zerchin/rancher-inspect-tools/main/scripts/rancherinfo.sh
chmod +x rancherinfo.sh
./rancherinfo.sh
```
其中，替换`Rancher_URL`为Rancher访问地址，替换`Bearer_Token`为具体的Token值，`Bearer_token`请使用用admin用户登录进行获取

执行结束后，会得到`output`和`cluster_output`两个目录，将这两个目录收集起来即可

2. 对所有k8s节点进行巡检

下载`nodeinfo-amd64`可执行文件到主机上执行即可
```bash
wget https://raw.githubusercontent.com/zerchin/rancher-inspect-tools/main/nodeinfo-amd64
chmod +x nodeinfo-amd64
./nodeinfo-amd64
```
执行结束后，会得到`output`这个目录，将这个目录收集起来即可
