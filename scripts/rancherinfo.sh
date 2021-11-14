#! /bin/bash


##################################################################################################
# 请提前安装 jq 、 kubectl 、 helm(如果是rancher是高可用部署) 命令行工具 
# jq 下载地址：https://stedolan.github.io/jq/download/
# kuectl & helm 下载地址：http://mirror.rancher.cn/
# note：如果rancher是docker run的方式安装的，请在执行完此脚本后，手动执行如下两个命令获取Rancher安装信息和日志信息
# 1. docker inspect <Rancher_Container_id> > inspect_rancher.json
# 2. docker logs --since $(echo $(date -d -3day +%Y-%m-%d)) <Rancher_Container_id> >& ./output/rancher.log
##################################################################################################

## 使用方法：替换Rancher_URL为Rancher访问地址，替换Bearer_Token为具体的Token值，然后将该文件保存在rancher/local集群的节点上
## Bearer_Token：请在浏览器使用admin用户登录Rancher UI，点击右上角-"API & Keys"，新建一个Key，作用范围不指定集群即可
Rancher_URL="https://rancher.zerchin.xyz"
Bearer_Token="token-2dthd:wgdxkm2txfr7lhrrnd6mch8cp8s42rdn4wg76m2n98xzz5zs46f529"

## check Ranchr_URL can be accessed
healthz=$(curl $Rancher_URL/healthz -k 2>/dev/null)
if [[ $healthz != "ok" ]]
then
    echo -e "\033[31m ERR \033[0m 请填写正确的Rancher URL，再重新执行该脚本"
    exit
fi
if ! curl -sk  $Rancher_URL/v3 >/dev/null 2>&1 
then
    echo -e "\033[31m ERR \033[0m 无法认证Bearer_Token"
    exit
fi


## check jq && kubectl is installed
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
echo "---start collect Rancher info---"

## 获取kubeconfig文件
get_kubeconfig() {
        curl -sk -X POST -u ${Bearer_Token} ${Rancher_URL}/v3/clusters/$1?action=generateKubeconfig | \
    jq .config -r > kubeconfig_$1.cfg 
}

## 检查rancher
check_rancher() {
    OUTPUT_PATH="./output/rancherinfo.log"

    ## check rancher version
    echo "- 检查Rancher版本" && echo -n "rancher_version: " > $OUTPUT_PATH
    version=$(curl -sk -X GET -u ${Bearer_Token} ${Rancher_URL}/v3/settings/server-version | jq .value  -r)
    echo "  Rancher 版本：$version" && echo $version >> $OUTPUT_PATH

    ## check rancher install mode
    echo "- 检查Rancher部署模式" && echo -n "rancher_install_mode: " >> $OUTPUT_PATH
    if [[ `echo $version | awk -F '.' '{print $2}'` < 5 ]]
    then
        local_name=$(curl -X GET -sk -u ${Bearer_Token} "${Rancher_URL}/v3/clusters?limit=-1"  | jq .data[].id -r| grep local)
    else
        driver=$(curl -X GET -sk -u ${Bearer_Token} "${Rancher_URL}/v3/clusters/local" | jq -r .driver)
    fi
    if [[ $local_name == "local" || $driver == "imported" ]]
    then
        echo "  Rancher is in local cluster." && echo "HA" >> $OUTPUT_PATH
        mode="ha"
    else
        echo "  Rancher is not in local cluster." && echo "single" >> $OUTPUT_PATH
    fi

   
    ## check Rancher install option
    echo "- 检查Rancher部署参数"
    if [[ $mode == "ha" ]]
    then
        if command -v helm >/dev/null 2>&1 ;then
            echo -e " \033[32m PASS \033[0m helm command already exists. "
        else
            echo " helm command not found. Please install helm."
            exit
        fi

        get_kubeconfig local
        KUBECONFIG=kubeconfig_local.cfg
        helm --kubeconfig=$KUBECONFIG get values rancher -n cattle-system > ./output/rancher_values.yaml
        echo -e " \033[32m PASS \033[0m get the values for rancher"

        ## check pod status
        echo "- 检查系统工作负载" && echo "check_workload:" >> $OUTPUT_PATH
        check_pod rancher cattle-system
        check_pod cattle-cluster-agent cattle-system

    else
        echo -e " \033[31m Rancher不是Helm方式部署，请到Rancher所在的节点上执行docker inspect <Rancher_Container_id> > inspect_rancher.json 命令进行获取 \033[0m"
        echo -e " \033[31m 并收集Rancher的日志：docker logs --since $(echo $(date -d -3day +%Y-%m-%d)) <Rancher_Container_id> >& ./output/rancher.log \033[0m"
    fi



    ## check cluster status
    echo "- 检查所有集群状态" && echo "clusters:" >> $OUTPUT_PATH
    clusters_id=$(curl -X GET -sk -u ${Bearer_Token} ${Rancher_URL}/v3/clusters | jq .data[].id -r)
    clusters_num=0
    mkdir -p ./output/cluster
    for i in ${clusters_id}
    do
        curl -X GET -sk -u ${Bearer_Token} ${Rancher_URL}/v3/clusters/${i} | jq . > ./output/cluster/cluster_${i}.json
        clusters_num=$[$clusters_num+1]
        nodes_num=$(curl -X GET -sk -u ${Bearer_Token} "${Rancher_URL}/v3/nodes?limit=-1" | jq .data[].clusterId | grep $i | wc -l)
        display_name=$(cat ./output/cluster/cluster_${i}.json | jq -r .appliedSpec.displayName)
        k8s_version=$(cat ./output/cluster/cluster_${i}.json | jq -r .version.gitVersion)
        is_direct=$(cat ./output/cluster/cluster_${i}.json | jq . |grep "management.cattle.io/direct-access"|grep true)
        cluster_monitoring=$(cat ./output/cluster/cluster_${i}.json | jq .appliedSpec.enableClusterMonitoring)
        cluster_alerting=$(cat ./output/cluster/cluster_${i}.json | jq .appliedSpec.enableClusterAlerting)
        ucc_index=$(cat ./output/cluster/cluster_${i}.json | jq .labels.\"mcm.pandaria.io/cluster-manager-restart\" )
        ucc_rancher_pod=$(cat ./output/cluster/cluster_${i}.json | jq .labels.\"mcm.pandaria.io/cluster-rancher-pod\")
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

        projects=$(curl -X GET -sk -u ${Bearer_Token} "${Rancher_URL}/v3/projects?limit=-1" | jq .data[].id -r | grep $i )
        projects_num=$(echo "$projects" | wc -l)
        projects_logging=""
        echo "    projects:" | tee -a $OUTPUT_PATH
        for project in $projects 
        do
            if [[ $(curl -X GET -sk -u ${Bearer_Token} "${Rancher_URL}/v3/projectloggings?limit=-1" | jq  .data[].id |wc -l) != 0 ]]
            then
                projects_logging+=" ${project}"
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
    users_num=$(curl -X GET -sk -u ${Bearer_Token} "${Rancher_URL}/v3/users?limit=1" | jq .pagination.total)
    echo "user_num: $users_num" | tee -a $OUTPUT_PATH

    ## check prtb
    echo "- 获取prtb数量"
    prtb_num=$(curl -X GET -sk -u ${Bearer_Token} "${Rancher_URL}/v3/projectroletemplatebindings?limit=1" | jq .pagination.total)
    echo "prtb_num: $prtb_num" | tee -a $OUTPUT_PATH

    ## check prtb
    echo "- 获取prtb数量"
    crtb_num=$(curl -X GET -sk -u ${Bearer_Token} "${Rancher_URL}/v3/clusterroletemplatebindings?limit=1" | jq .pagination.total)
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
    for pod in ${pods}
    do
        pods_num=$[$pods_num+1]
        pod_phase=$(kubectl --kubeconfig=$KUBECONFIG get pod -n $NAMESPACE $pod -ojsonpath='{.status.phase}')
        pod_nodename=$(kubectl --kubeconfig=$KUBECONFIG get pod -n $NAMESPACE $pod -ojson | jq -r .spec.nodeName)
        other_pods=$(kubectl --kubeconfig=$KUBECONFIG get pod --all-namespaces -o wide | grep $pod_nodename | awk '{print $2}')
        echo "    ${pod}:" | tee -a $OUTPUT_PATH
        echo "      phase: $pod_phase" | tee -a $OUTPUT_PATH
        echo "      nodename: $pod_nodename" | tee -a $OUTPUT_PATH
        echo "      other_pod_in_this_node:" $other_pods | tee -a $OUTPUT_PATH
        ## get pod log
        mkdir -p ./output/pod_log
        echo "  get logging..."
        for container in $(kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE get pods $pod -ojson | jq -r .spec.containers[].name)
        do
            kubectl --kubeconfig=$KUBECONFIG logs -n $NAMESPACE  $pod -c $container --tail=-1 --since=72h > ./output/pod_log/pod_${NAMESPACE}_${pod}_${container}.log 
        done
    done
    echo "  ${POD}_pods_num: $pods_num" | tee -a $OUTPUT_PATH

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
    nodes_num=0
    for i in $nodes
    do
        kubectl --kubeconfig=$KUBECONFIG describe nodes $i > ${CLUSTER_OUTPUT_PATH}/${i}.txt
        nodes_num=$((${nodes_num} + 1))
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
    pods_num=$(kubectl --kubeconfig=$KUBECONFIG get pods --all-namespaces | wc -l)
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
mkdir -p ./output
check_rancher local

## check downstream cluster
mkdir -p ./cluster_output
clusters_id=$(curl -X GET -sk -u ${Bearer_Token} "${Rancher_URL}/v3/clusters?limit=-1" | jq -r .data[].id)
for i in $clusters_id
do
    get_kubeconfig ${i}
    check_cluster ${i}
done
