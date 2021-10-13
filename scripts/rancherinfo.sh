#! /bin/bash


##################################################################################################
# 请提前安装 jq 、 kubectl 、 helm 命令行工具 
# jq 下载地址：https://stedolan.github.io/jq/download/
# kuectl & helm 下载地址：http://mirror.rancher.cn/
# note：如果rancher是docker run的方式安装的，请在执行完此脚本后，手动执行如下两个命令获取Rancher安装信息和日志信息
# 1. docker inspect <Rancher_Container_id> > inspect_rancher.json
# 2. docker logs --since $(echo $(date -d -3day +%Y-%m-%d)) <Rancher_Container_id> >& ./output/rancher.log
##################################################################################################

## 使用方法：替换Rancher_URL为Rancher访问地址，替换Bearer_Token为具体的Token值，然后保存文件可访问Rancher的服务器上执行即可
## Bearer_Token：请在浏览器使用admin用户登录Rancher UI，点击右上角-"API & Keys"，新建一个Key，作用范围不指定集群即可
Rancher_URL="https://rancher.zerchin.xyz"
Bearer_Token="token-gdtf2:6vtqw9v86dz2q7zfhkljqrhrjwxf4x9xslc4hxp748zcr8bnlw9b8m"


## check jq && kubectl is installed
echo "---start Rancher info collect---"
if command -v jq >/dev/null 2>&1
then
    echo -e " \033[32m PASS \033[0m jq command already exists. "
else
  echo " jq command not found. Please install jq."
  exit
fi

if command -v kubectl >/dev/null 2>&1 ;then
    echo -e " \033[32m PASS \033[0m kubectl command already exists."
else
  echo " kubectl command not found. Please install kubectl."
  exit
fi


## 获取kubeconfig文件
get_kubeconfig() {
	curl -s -X POST -u ${Bearer_Token} ${Rancher_URL}/v3/clusters/$1?action=generateKubeconfig | \
    jq .config -r > kubeconfig_$1.cfg 
}

## 检查rancher部署模式
check_rancher() {
    CLUSTER=$1
	KUBECONFIG="kubeconfig_$CLUSTER.cfg"
    OUTPUT_PATH="./output/rancherinfo.log"

    ## check rancher install mode
	echo "- 检查Rancher部署模式" && echo -n "rancher_install_mode: " > $OUTPUT_PATH
	if  kubectl --kubeconfig=$KUBECONFIG get clusters.management.cattle.io local > /dev/null 2>&1 && 
        kubectl --kubeconfig=$KUBECONFIG -n cattle-system get deployment rancher  > /dev/null 2>&1
    then
        echo "  Rancher is in local cluster." && echo "HA" >> $OUTPUT_PATH
        mode="ha"
    else
        echo "  Rancher is not in local cluster." && "single" >> $OUTPUT_PATH
    fi

    ## check rancher version
    echo "- 检查Rancher版本" && echo -n "rancher_version: " >> $OUTPUT_PATH
    version=$(kubectl --kubeconfig=$KUBECONFIG get settings.management.cattle.io server-version -ojsonpath="{.value}")
    echo "  Rancher 版本：$version" && echo $version >> $OUTPUT_PATH

    ## check Rancher install option
    echo "- 检查Rancher部署参数"
    if [[ $mode == "ha" ]]
    then
        helm --kubeconfig=$KUBECONFIG get values rancher -n cattle-system > ./output/rancher_values.yaml
        echo -e " \033[32m PASS \033[0m"
    else
        echo -e " \033[31m Rancher不是Helm方式部署，请到Rancher所在的节点上执行docker inspect <Rancher_Container_id> > inspect_rancher.json 命令进行获取 \033[0m"
        echo -e " \033[31m 并收集Rancher的日志：docker logs --since $(echo $(date -d -3day +%Y-%m-%d)) <Rancher_Container_id> >& ./output/rancher.log"
    fi


    ## check pod status
    echo "- 检查系统工作负载" && echo "check_workload:" >> $OUTPUT_PATH
    check_pod rancher cattle-system
    check_pod cattle-cluster-agent cattle-system

    ## check cluster status
    echo "- 检查所有集群状态" && echo "clusters:" >> $OUTPUT_PATH
    clusters_id=$(kubectl --kubeconfig=$KUBECONFIG get clusters.management.cattle.io | awk '(NR>1) {print $1}')
    clusters_num=0
    mkdir -p ./output/cluster
    for i in ${clusters_id}
    do
        kubectl --kubeconfig=$KUBECONFIG get clusters.management.cattle.io ${i} -ojson > ./output/cluster/cluster_${i}.json
        clusters_num=$[$clusters_num+1]
        nodes_num=$(kubectl --kubeconfig=$KUBECONFIG get nodes.management.cattle.io --all-namespaces | grep $i | wc -l)
        display_name=$(cat ./output/cluster/cluster_${i}.json | jq -r .spec.displayName)
        k8s_version=$(cat ./output/cluster/cluster_${i}.json | jq -r .status.version.gitVersion)
        is_direct=$(cat ./output/cluster/cluster_${i}.json | jq . |grep "management.cattle.io/direct-access"|grep true)
        cluster_monitoring=$(cat ./output/cluster/cluster_${i}.json | jq .spec.enableClusterMonitoring)
        cluster_alerting=$(cat ./output/cluster/cluster_${i}.json | jq .spec.enableClusterAlerting)
        ucc_index=$(cat ./output/cluster/cluster_${i}.json | jq .metadata.labels.\"mcm.pandaria.io/cluster-manager-restart\" )
        ucc_rancher_pod=$(cat ./output/cluster/cluster_${i}.json | jq .metadata.labels.\"mcm.pandaria.io/cluster-rancher-pod\")
        echo "  ${i}:" | tee -a $OUTPUT_PATH
        echo "    display_name: $display_name" | tee -a $OUTPUT_PATH
        echo "    k8s_version: $k8s_version" | tee -a $OUTPUT_PATH
        echo "    nodes_num: $nodes_num" | tee -a $OUTPUT_PATH
        echo "    cluster_monitoring: $cluster_monitoring" | tee -a $OUTPUT_PATH
        echo "    cluster_alerting: $cluster_alerting" | tee -a $OUTPUT_PATH
        echo "    ucc_index: $ucc_index" | tee -a $OUTPUT_PATH
        echo "    ucc_rancher_pod: $ucc_rancher_pod" | tee -a $OUTPUT_PATH
        if [[ $is_direct == "" ]]
        then
            echo "    is_direct: false" | tee -a $OUTPUT_PATH
        else
            echo "    is_direct: true" | tee -a $OUTPUT_PATH
        fi

        projects=$(kubectl --kubeconfig=$KUBECONFIG get projects.management.cattle.io --all-namespaces | grep ${i} | awk '{print $2}')
        projects_num=$(echo "$projects" | wc -l)
        projects_logging=""
        echo "    projects:" | tee -a $OUTPUT_PATH
        for i in $projects 
        do
            if [[ $(kubectl --kubeconfig=$KUBECONFIG get projectloggings.management.cattle.io -n $i |wc -l) != 0 ]]
            then
                projects_logging+=" ${i}"
            fi
        done
        if [[ $projects_logging != null ]]
        then
            echo "      projects_logging:$projects_logging" | tee -a $OUTPUT_PATH
        else
            echo "      projects_logging: null" | tee -a $OUTPUT_PATH
        fi
        echo "    projects_num: $projects_num" | tee -a $OUTPUT_PATH

    done
    echo "clusters_num: $clusters_num" | tee -a $OUTPUT_PATH

    ## check users 
    echo "- 获取用户数量"
    users_num=$(kubectl --kubeconfig=$KUBECONFIG get users.management.cattle.io | awk '(NR>1)' | wc -l)
    echo "user_num: $users_num" | tee -a $OUTPUT_PATH

    ## check prtb
    echo "- 获取prtb数量"
    prtb_num=$(kubectl --kubeconfig=$KUBECONFIG get projectroletemplatebindings.management.cattle.io --all-namespaces | awk '(NR>1)' | wc -l)
    echo "prtb_num: $prtb_num" | tee -a $OUTPUT_PATH

    ## check prtb
    echo "- 获取prtb数量"
    crtb_num=$(kubectl --kubeconfig=$KUBECONFIG  get clusterroletemplatebindings.management.cattle.io --all-namespaces | awk '(NR>1)' | wc -l)
    echo "crtb_num: $crtb_num" | tee -a $OUTPUT_PATH
}

## 检查pod
check_pod() {
    POD=$1
    NAMESPACE=$2
    echo "  - 检查 $POD 应用" && echo "  $POD: " >> $OUTPUT_PATH
    pods=$(kubectl --kubeconfig=$KUBECONFIG get pods -n $NAMESPACE -l app=$1 -o wide | awk '(NR>1) {print $1}')
    if [[ $pods == "" ]]
    then
        echo "  应用$POD不存在"
        echo "    pod: not_exist" >> $OUTPUT_PATH
        return
    fi

    pods_num=0
    for i in ${pods}
    do
        pods_num=$[$pods_num+1]
        pod_phase=$(kubectl --kubeconfig=$KUBECONFIG get pod -n $NAMESPACE $i -ojsonpath='{.status.phase}')
        pod_nodename=$(kubectl --kubeconfig=$KUBECONFIG get pod -n $NAMESPACE $i -ojson | jq -r .spec.nodeName)
        other_pods=$(kubectl --kubeconfig=$KUBECONFIG get pod --all-namespaces -o wide | grep $pod_nodename | awk '{print $2}')
        echo "    ${i}:" | tee -a $OUTPUT_PATH
        echo "      phase: $pod_phase" | tee -a $OUTPUT_PATH
        echo "      nodename: $pod_nodename" | tee -a $OUTPUT_PATH
        echo "      other_pod_in_this_node:" $other_pods | tee -a $OUTPUT_PATH
        ## get pod log
        mkdir -p ./output/pod_log
        echo "  get logging..."
        kubectl --kubeconfig=$KUBECONFIG logs -n $NAMESPACE  $i --tail=-1 --since=72h > ./output/pod_log/pod_$i.log 
    done
    echo "  ${POD}_pods_num: $pods_num" | tee -a $OUTPUT_PATH

    echo "---Rancher data collected---"
}

NATIVE_RESOURCES=(Pod
PodTemplate
ReplicaSet
Deployment
StatefulSet
DaemonSet
Job
CronJob
HorizontalPodAutoscaler
Service
Endpoints
Ingress
ConfigMap
Secret
PersistentVolumeClaim
PersistentVolume
StorageClass
ServiceAccount
Role
RoleBinding
ClusterRoleBinding
ClusterRole
LimitRange
ResourceQuota
NetworkPolicy
PodDisruptionBudget
Namespace
Node
Event
RuntimeClass
Lease)

check_cluster() {
	CLUSTER=$1
    KUBECONFIG="kubeconfig_$CLUSTER.cfg"
    CLUSTER_OUTPUT_PATH="./cluster_output/${CLUSTER}"
    CLUSTER_OUTPUT_FILE="${CLUSTER_OUTPUT_PATH}/cluster_info_${CLUSTER}.txt"
    mkdir -p $CLUSTER_OUTPUT_PATH

    ## collect node info
    echo "---start collecting cluster: ${CLUSTER}---"
    echo "- 收集节点信息"
    nodes=$(kubectl --kubeconfig=$KUBECONFIG get nodes | awk '(NR>1) {print $1}')
    nodes_num=$(echo $nodes|wc -l)
    for i in $nodes
    do
        kubectl --kubeconfig=$KUBECONFIG describe nodes $i > ${CLUSTER_OUTPUT_PATH}/${i}.txt
    done
    echo -e " \033[32m PASS \033[0m"

    ## collect node resource usage
    echo "- 收集节点资源使用情况"
    echo "nodes_resource_useage:" > $CLUSTER_OUTPUT_FILE
    echo "  nodes_num: $nodes_num" >> $CLUSTER_OUTPUT_FILE
    kubectl --kubeconfig=$KUBECONFIG top node | tee -a $CLUSTER_OUTPUT_FILE
    echo "" >> $CLUSTER_OUTPUT_FILE

    ## collect pod resource usage
    echo "- 收集pod资源使用情况"
    pods_num=$(kubectl --kubeconfig=$KUBECONFIG get pods -A | wc -l)
    echo "pods_resource_useage:" >> $CLUSTER_OUTPUT_FILE
    echo "  pods_num: $pods_num" >> $CLUSTER_OUTPUT_FILE
    kubectl --kubeconfig=$KUBECONFIG top pods --all-namespaces | tee -a $CLUSTER_OUTPUT_FILE
    echo "" >> $CLUSTER_OUTPUT_FILE

    ## collect all pods
    echo "- 收集所有pod的状态"
    echo "all_pods:" >> $CLUSTER_OUTPUT_FILE
    kubectl --kubeconfig=$KUBECONFIG get pods --all-namespaces -o wide >> $CLUSTER_OUTPUT_FILE
    echo "" >> $CLUSTER_OUTPUT_FILE
    echo -e " \033[32m PASS \033[0m"

    ## collect native resource
    echo "- 收集原生资源数量（wait a moment）"
    echo "native_reources:" >> $CLUSTER_OUTPUT_FILE
    map=()
    for i in `seq 0 $((${#NATIVE_RESOURCES[*]} - 1))`
    do
        map[$i]=$(kubectl --kubeconfig=$KUBECONFIG get ${NATIVE_RESOURCES[$i]} --all-namespaces 2>/dev/null| wc -l)
        echo "${map[$i]} ${NATIVE_RESOURCES[$i]}" | tee -a ${CLUSTER_OUTPUT_PATH}/tmp.data 
    done
    cat ${CLUSTER_OUTPUT_PATH}/tmp.data | sort -nr >> $CLUSTER_OUTPUT_FILE
    rm -f ${CLUSTER_OUTPUT_PATH}/tmp.data
    echo "" >> $CLUSTER_OUTPUT_FILE


    ## collect crd resource
    echo "- 收集crd资源数量（wait a moment）"
    echo "crd_reources:" >> $CLUSTER_OUTPUT_FILE
    crd=($(kubectl --kubeconfig=$KUBECONFIG get crd --no-headers | awk '{print $1}'))
    map=()
    for i in `seq 0 $((${#crd[*]} - 1))`
    do
        map[$i]=$(kubectl --kubeconfig=$KUBECONFIG get ${crd[$i]} --all-namespaces 2>/dev/null| wc -l)
        echo "${map[$i]} ${crd[$i]}" | tee -a ${CLUSTER_OUTPUT_PATH}/tmp.data 
    done
    cat ${CLUSTER_OUTPUT_PATH}/tmp.data | sort -nr >> $CLUSTER_OUTPUT_FILE
    rm -f ${CLUSTER_OUTPUT_PATH}/tmp.data
    echo "" >> $CLUSTER_OUTPUT_FILE

	echo "---${CLUSTER} cluster info collected---"
}


## check rancher 
# mkdir -p ./output
# get_kubeconfig local
# check_rancher local

## check downstream cluster
mkdir -p ./cluster_output
clusters_id=$(kubectl --kubeconfig=$KUBECONFIG get clusters.management.cattle.io | awk '(NR>1) {print $1}')
for i in $clusters_id
do
    get_kubeconfig ${i}
    check_cluster ${i}
done
