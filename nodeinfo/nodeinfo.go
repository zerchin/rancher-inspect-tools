package main

import (
        "bufio"
        "encoding/json"
        "fmt"
        "io"
        "os"
        "strings"
        "time"
        "log"
        "os/exec"

        "github.com/shirou/gopsutil/cpu"
        "github.com/shirou/gopsutil/disk"
        "github.com/shirou/gopsutil/docker"
        "github.com/shirou/gopsutil/host"
        "github.com/shirou/gopsutil/load"
        "github.com/shirou/gopsutil/mem"
        "github.com/shirou/gopsutil/net"
)

type NodeStatus struct {
        CPU     CPUStatus
        Memory  MemoryStatus
        Swap    SwapStatus
        Disk    DiskStatus
        Host    HostStatus
        Network []NetworkStatus
        Docker  []DockerStatus
}

type CPUStatus struct {
        Total     cpu.TimesStat
        Load      *load.AvgStat
        Percent   float64
        ModelName string
        CPUs      int
}

type MemoryStatus struct {
        Total     uint64
        Used      uint64
        Available uint64
        Percent   float64
}

type SwapStatus struct {
        Total   uint64
        Used    uint64
        Free    uint64
        Percent float64
}

type DiskStatus struct {
        FsType  string
        Path    string
        Total   uint64
        Used    uint64
        Percent float64
}

type HostStatus struct {
        HostName string
        UpTime   uint64
        BootTime uint64
        OS                   string
        Platform             string
        PlatformFamily       string
        PlatformVersion      string
        KernelVersion        string
        KernelArch           string
}

type NetworkStatus struct {
        Name string
        Addr []string
}

type DockerStatus struct {
        ContainerID string
        Name    string
        Image       string
        Status  string
        Running bool
}

func GetNodeStatusJson() string {
        //new NodeStatus
        ns := new(NodeStatus)

        //get CPU info
        nodeCPUTimes, _ := cpu.Times(false)
        nodeLoad, _ := load.Avg()
        nodeCPUPercent, _ := cpu.Percent(time.Second, false)
        nodeCPUInfo, _ := cpu.Info()
        ns.CPU.Total = nodeCPUTimes[0]
        ns.CPU.Load = nodeLoad
        ns.CPU.Percent = nodeCPUPercent[0]
        cpus := 0
        for _, value := range nodeCPUInfo {
                ns.CPU.ModelName = value.ModelName
                cpus += 1
        }
        ns.CPU.CPUs = cpus * int(nodeCPUInfo[0].Cores)

        //get Memory info
        nodeMem, _ := mem.VirtualMemory()
        ns.Memory.Total = nodeMem.Total
        ns.Memory.Used = nodeMem.Used
        ns.Memory.Available = nodeMem.Available
        ns.Memory.Percent = nodeMem.UsedPercent

        //get Swap info
        nodeSwap, _ := mem.SwapMemory()
        ns.Swap.Total = nodeSwap.Total
        ns.Swap.Used = nodeSwap.Used
        ns.Swap.Free = nodeSwap.Free
        ns.Swap.Percent = nodeSwap.UsedPercent

        //get disk info
        nodeDisk, _ := disk.Usage("/")
        ns.Disk.Path = nodeDisk.Path
        fsType, _ := GetFsType("/etc/fstab")
        ns.Disk.FsType = fsType
        ns.Disk.Total = nodeDisk.Total
        ns.Disk.Used = nodeDisk.Used
        ns.Disk.Percent = nodeDisk.UsedPercent

        //get Host info
        nodeInfo, _ := host.Info()
        ns.Host.HostName = nodeInfo.Hostname
        ns.Host.UpTime = nodeInfo.Uptime
        ns.Host.BootTime = nodeInfo.BootTime
        ns.Host.OS = nodeInfo.OS
        ns.Host.Platform = nodeInfo.Platform
        ns.Host.PlatformFamily = nodeInfo.PlatformFamily
        ns.Host.KernelVersion = nodeInfo.KernelVersion
        ns.Host.KernelArch = nodeInfo.KernelArch


        //get network info
        nodeNetwork, _ := net.Interfaces()
        ns.Network = make([]NetworkStatus, 0)
        for _, value := range nodeNetwork {
                if len(value.Addrs) > 0 {
                        var networkObject NetworkStatus
                        networkObject.Name = value.Name
                        networkObject.Addr = make([]string, len(value.Addrs))
                        for key, addrs := range value.Addrs {
                                networkObject.Addr[key] = addrs.Addr
                        }
                        ns.Network = append(ns.Network, networkObject)
                }
        }

        //get docker info
        nodeDockers, _ := docker.GetDockerStat()
        var kubeComponents = [7]string{"kube-apiserver", "kube-controller-manager", "kubelet", "etcd", "kube-proxy", "kube-scheduler", "nginx-proxy"}
        ns.Docker = make([]DockerStatus, 0)
        for _, value := range nodeDockers {
                for _, kubeName := range kubeComponents {
                        if value.Name == kubeName {
                                var dockerObject DockerStatus
                                dockerObject.Name = value.Name
                                dockerObject.Status = value.Status
                                dockerObject.Running = value.Running
                                dockerObject.ContainerID = value.ContainerID[:12]
                                dockerObject.Image = value.Image
                                ns.Docker = append(ns.Docker, dockerObject)
                        }
                }
        }

        nodeStatus, _ := json.Marshal(ns)
        return string(nodeStatus)
}

func GetFsType(fileName string) (string, error) {
        var fsType string
        fsFile, err := os.Open(fileName)
        if err != nil {
                fmt.Printf("Error: %s\n", err)
                return "", err
        }
        defer fsFile.Close()
        fsBufio := bufio.NewReader(fsFile)
        for {
                fileLine, _, c := fsBufio.ReadLine()
                if c == io.EOF {
                        break
                }
                if string(fileLine) != "" {
                        if !strings.HasPrefix(string(fileLine), "#") && strings.Fields(string(fileLine))[1] == "/" {
                                fsType = strings.Fields(string(fileLine))[2]
                        }
                }
        }
        return fsType, nil
}

func CMD() {
    input := `
    alias cp=cp
    ## get docker info
    docker info > ./output/docker_info.log
    cp /etc/docker/daemon.json ./output/daemon.json
    docker version > ./output/docker_version.log

    ## get modules
    lsmod > ./output/mod.log

    ## get ps info
    ps aux > ./output/ps_info.log

    ## get sysctl kernel
    sysctl -a 2>/dev/null > ./output/sysctl.log

    ## get limit
    ulimit -a > ./output/limit-a.log
    cp /etc/security/limits.conf ./output/limits.conf

    ## get disk fs
    df -h | egrep -v "tmpfs|shm|overlay" > ./output/df.log

    ## get uptime
    uptime > ./output/uptime.log

    ## get k8s component
    kube_component=(kube-apiserver kube-controller-manager kubelet etcd kube-proxy kube-scheduler)
    for i in $(seq 0 $((${#kube_component[*]} - 1)))
    do
        if [[ $(docker ps | grep ${kube_component[i]}) ]]
        then
            docker inspect  -f '{{.Args}}' ${kube_component[i]} > ./output/${kube_component[i]}_args.txt
            docker logs --since $(echo $(date -d -3day +%Y-%m-%d)) ${kube_component[i]} >& ./output/${kube_component[i]}.log
        fi

    done

    `
    c := exec.Command("/bin/bash", "-c", input)
    c.CombinedOutput()
}

func Output2File(input string,filename string) {
    //创建文件
    f, err := os.OpenFile(filename, os.O_WRONLY|os.O_CREATE|os.O_APPEND|os.O_TRUNC, 0644)
    if err != nil {
        log.Fatal(err)
    }
    //完成后，延迟关闭
    defer f.Close()
    // 设置日志输出到文件
    log.SetOutput(f)
    log.SetFlags(0)
    // 写入日志内容
    log.Println(input)
}



func main() {
    fmt.Println("Start collecting data...")
    //fmt.Println(GetNodeStatusJson())
    //创建输出目录
    _, err := os.Stat("./output")
    if os.IsNotExist(err) {
        os.Mkdir("./output", 0777)
    }
    Output2File(GetNodeStatusJson(), "./output/nodeinfo.json")
    CMD()
    fmt.Println("Completed.")
}
