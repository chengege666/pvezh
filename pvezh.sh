#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

clear
echo "====================================================="
echo -e "${BLUE}     PVE 镜像转换工具 (VM & LXC)${NC}"
echo "====================================================="

# --- 1. 选择镜像文件 ---
echo "检测到以下镜像文件:"
# 搜索 PVE 常用模板目录和当前目录
files=($(find . /var/lib/vz/template/iso/ /var/lib/vz/template/cache/ -maxdepth 1 -name "*.img" -o -name "*.img.gz" -o -name "*.tar.gz" -o -name "*.tar.zst" 2>/dev/null))

if [ ${#files[@]} -eq 0 ]; then
    echo -e "${RED}[错误] 未找到任何 .img, .tar.gz 或 .tar.zst 文件。${NC}"
    exit 1
fi

for i in "${!files[@]}"; do
    echo " [$(($i+1))] $(basename "${files[$i]}")"
done
read -p "请选择镜像编号 (默认 1): " file_idx
file_idx=${file_idx:-1}
selected_file="${files[$(($file_idx-1))]}"
file_name=$(basename "$selected_file")
echo -e ">> 已选择: ${GREEN}$file_name${NC}\n"

# --- 2. 选择安装模式 ---
echo "请选择安装模式:"
echo " [1] 虚拟机 (VM) - 将磁盘注入到已有的空壳虚拟机"
echo " [2] 容器 (LXC) - 全自动创建并配置新容器"
read -p "您的选择 (1/2): " mode

# ==================== VM 模式逻辑 ====================
if [ "$mode" == "1" ]; then
    echo -e ">> 已进入 ${BLUE}[VM 虚拟机]${NC} 注入模式\n"
    
    # --- 2.1 指定目标虚拟机 ---
    echo "[提示] 当前系统中的虚拟机列表:"
    qm list
    echo ""
    read -p "请输入目标虚拟机 ID (VMID): " vmid

    if ! qm status $vmid >/dev/null 2>&1; then
        echo -e "${RED}[错误] 虚拟机 $vmid 不存在。请先在 PVE 界面创建。${NC}"
        exit 1
    fi
    vm_name=$(qm config $vmid | grep 'name:' | awk '{print $2}')
    echo -e ">> 目标虚拟机已锁定: ${GREEN}[$vmid] $vm_name${NC}\n"
    
    # --- 2.2 选择目标存储 ---
    echo "检测到可用存储位置:"
    storage_list=($(pvesm status -content images | awk 'NR>1 {print $1}'))
    for i in "${!storage_list[@]}"; do
        echo " [$(($i+1))] ${storage_list[$i]}"
    done
    read -p "请选择存储位置编号 (默认 1): " storage_idx
    storage_idx=${storage_idx:-1}
    selected_storage="${storage_list[$(($storage_idx-1))]}"
    echo -e ">> 磁盘将导入至存储: ${GREEN}$selected_storage${NC}\n"
    
    # --- 2.3 确认并执行 ---
    echo "-----------------------------------------------------"
    echo "确认导入计划:"
    echo " - 待转换镜像: $file_name"
    echo " - 目标虚拟机: $vmid ($vm_name)"
    echo " - 磁盘存放地: $selected_storage"
    echo "-----------------------------------------------------"
    read -p "确认开始转换并注入磁盘? (y/n): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0
    
    echo -ne "[进度] 正在准备镜像文件... "
    temp_img="/tmp/temp_import_$vmid.img"
    if [[ "$file_name" == *.gz ]]; then
        zcat "$selected_file" > "$temp_img"
    else
        cp "$selected_file" "$temp_img"
    fi
    echo -e "${GREEN}完成${NC}"

    echo -ne "[进度] 正在转换并导入磁盘... "
    qm importdisk $vmid "$temp_img" "$selected_storage" >/dev/null 2>&1
    echo -e "${GREEN}完成${NC}"

    echo -ne "[进度] 正在挂载磁盘并设为引导项... "
    qm set $vmid --scsi0 "$selected_storage:vm-$vmid-disk-0" >/dev/null 2>&1
    qm set $vmid --boot order=scsi0 >/dev/null 2>&1
    echo -e "${GREEN}完成${NC}"
    
    [[ "$file_name" == *.gz ]] && rm -f "$temp_img"
    
    echo -e "\n====================================================="
    echo -e "${GREEN}成功！磁盘已注入虚拟机 $vmid。${NC}"
    echo "请回到 PVE 界面，点击“启动”按钮即可。"
    echo "====================================================="

# ==================== LXC 模式逻辑 ====================
elif [ "$mode" == "2" ]; then
    echo -e ">> 已进入 ${BLUE}[LXC 容器]${NC} 配置模式\n"
    
    # --- 3.1 LXC 资源配置 ---
    max_id=$(pct list | awk 'NR>1 {print $1}' | sort -n | tail -1)
    suggest_id=$((max_id + 1)); [ "$suggest_id" -le 100 ] && suggest_id=100
    read -p "[配置] 请输入新容器 ID (建议 $suggest_id): " ctid; ctid=${ctid:-$suggest_id}
    read -p "[配置] 请输入 CPU 核心数 (默认 1): " cores; cores=${cores:-1}
    read -p "[配置] 请输入 内存大小 (MB) (默认 512): " memory; memory=${memory:-512}
    read -p "[配置] 请输入 虚拟硬盘大小 (G) (默认 2): " disk_size; disk_size=${disk_size:-2}
    read -p "[配置] 请输入 网桥 (默认 vmbr0): " bridge; bridge=${bridge:-vmbr0}
    read -p "[配置] 请输入 静态 IP (例如 192.168.1.5/24, 留空使用 DHCP): " static_ip
    echo ""

    # --- 3.2 选择存储位置 ---
    echo "检测到可用存储位置:"
    storage_list=($(pvesm status -content rootdir | awk 'NR>1 {print $1}'))
    for i in "${!storage_list[@]}"; do
        echo " [$(($i+1))] ${storage_list[$i]}"
    done
    read -p "请选择存储位置编号 (默认 1): " storage_idx
    storage_idx=${storage_idx:-1}
    selected_storage="${storage_list[$(($storage_idx-1))]}"
    echo -e ">> 目标存储: ${GREEN}$selected_storage${NC}\n"

    # --- 3.3 确认并创建 ---
    net_display="DHCP"
    [ -n "$static_ip" ] && net_display="$static_ip"
    echo "-----------------------------------------------------"
    echo "确认 LXC 创建计划:"
    echo " - 镜像文件: $file_name"
    echo " - 容器 ID: $ctid"
    echo " - 资源限制: $cores 核 / $memory MB / ${disk_size}G 硬盘"
    echo " - 网络配置: $bridge ($net_display)"
    echo " - 目标存储: $selected_storage"
    echo "-----------------------------------------------------"
    read -p "确认开始创建? (y/n): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0
    
    net_opts=""
    [ -n "$static_ip" ] && net_opts=",ip=$static_ip"

    echo -ne "[进度] 正在创建 LXC 容器 $ctid... "
    pct create $ctid "$selected_file" --hostname "lxc-$ctid" --storage "$selected_storage" --rootfs "$selected_storage:$disk_size" --cores "$cores" --memory "$memory" --unprivileged 0 --net0 name=eth0,bridge=$bridge$net_opts >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}创建失败，请检查镜像格式或 PVE 日志。${NC}"
        exit 1
    fi
    echo -e "${GREEN}完成${NC}"

    echo -e "\n====================================================="
    echo -e "${GREEN}成功！LXC 容器 $ctid 已成功创建并配置完成。${NC}"
    echo "您可以运行 'pct start $ctid' 或在网页端点击“启动”。"
    echo "====================================================="

else
    echo -e "${RED}无效的选择。脚本退出。${NC}"
    exit 1
fi