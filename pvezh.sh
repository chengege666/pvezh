#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo "====================================================="
echo -e "${BLUE}          PVE 镜像转换工具 (VM & LXC)${NC}"
echo "====================================================="

# --- 1. 扫描并分类镜像文件 ---
scan_dirs=("./" "/var/lib/vz/template/iso/" "/var/lib/vz/template/cache/")
all_found=($(find "${scan_dirs[@]}" -maxdepth 1 -type f \( -name "*.img" -o -name "*.img.gz" -o -name "*.tar.gz" -o -name "*.tar.zst" -o -name "*.tar.xz" \) 2>/dev/null))

if [ ${#all_found[@]} -eq 0 ]; then
    echo -e "${RED}[错误] 未找到任何可用镜像文件。${NC}"
    exit 1
fi

vm_files=()
lxc_files=()
for f in "${all_found[@]}"; do
    if [[ "$f" == *.img || "$f" == *.img.gz ]]; then
        vm_files+=("$f")
    else
        lxc_files+=("$f")
    fi
done

# --- 显示列表 ---
count=1
merged_files=()

# VM 分组显示
echo -e "${YELLOW}--- VM 镜像 (需提前创建 VM 空壳) ---${NC}"
if [ ${#vm_files[@]} -eq 0 ]; then 
    echo "  [无可用 .img 镜像]"
else
    # 醒目的重要提示
    echo -e "${CYAN}💡 提示: 选择 VM 镜像前，请确保您已在 PVE 网页端创建好一个${NC}"
    echo -e "${CYAN}   不带硬盘的虚拟机 (记住它的 ID)。${NC}"
    for f in "${vm_files[@]}"; do
        echo " [$count] $(basename "$f")"
        merged_files+=("$f")
        ((count++))
    done
fi

echo ""
# LXC 分组显示
echo -e "${YELLOW}--- LXC 镜像 (支持全自动创建) ---${NC}"
if [ ${#lxc_files[@]} -eq 0 ]; then 
    echo "  [无可用 .tar 镜像]"
else
    for f in "${lxc_files[@]}"; do
        echo " [$count] $(basename "$f")"
        merged_files+=("$f")
        ((count++))
    done
fi
echo "====================================================="

# --- 用户选择 ---
read -p "请选择镜像编号 (默认 1): " file_idx
file_idx=${file_idx:-1}
selected_file="${merged_files[$(($file_idx-1))]}"

if [ -z "$selected_file" ]; then
    echo -e "${RED}选择无效！${NC}"
    exit 1
fi

file_name=$(basename "$selected_file")
echo -e ">> 已选择: ${GREEN}$file_name${NC}\n"

# --- 2. 选择安装模式 ---
suggest_mode=1
[[ "$file_name" == *.tar* ]] && suggest_mode=2

echo "请选择安装模式:"
echo -e " [1] 虚拟机 (VM) $( [[ $suggest_mode -eq 1 ]] && echo -e "${BLUE}(推荐)${NC}" )"
echo -e " [2] 容器 (LXC) $( [[ $suggest_mode -eq 2 ]] && echo -e "${BLUE}(推荐)${NC}" )"
read -p "您的选择 (默认 $suggest_mode): " mode
mode=${mode:-$suggest_mode}

# ==================== 模式 1: VM 注入逻辑 ====================
if [ "$mode" == "1" ]; then
    echo -e "\n${RED}⚠️  操作确认：${NC}"
    echo -e "${RED}请确认您已经手动创建了对应 VM ID 的虚拟机。${NC}"
    echo -e "${RED}创建时请选择“不使用任何介质”且“不添加硬盘”。${NC}"
    echo "-----------------------------------------------------"
    
    # 列出当前 VM 方便参考
    echo "当前已有的 VM 列表:"
    qm list
    echo ""
    
    read -p "请输入目标 VM ID: " vmid
    
    if ! qm status $vmid >/dev/null 2>&1; then
        echo -e "${RED}[错误] VM $vmid 不存在。请先去 PVE 网页端创建它。${NC}"
        exit 1
    fi

    # 选择存储
    echo -e "\n可用存储:"
    storage_list=($(pvesm status -content images | awk 'NR>1 {print $1}'))
    for i in "${!storage_list[@]}"; do echo " [$((i+1))] ${storage_list[$i]}"; done
    read -p "请选择磁盘存放的存储编号 (默认 1): " s_idx; s_idx=${s_idx:-1}
    selected_storage="${storage_list[$((s_idx-1))]}"

    echo -e "\n[进度] 正在注入磁盘到 VM $vmid..."
    temp_img="/tmp/temp_$vmid.img"
    if [[ "$file_name" == *.gz ]]; then
        zcat "$selected_file" > "$temp_img"
    else
        temp_img="$selected_file"
    fi

    # 导入磁盘并自动挂载到 scsi0，设置引导
    if qm importdisk $vmid "$temp_img" "$selected_storage" >/dev/null; then
        # 兼容性设置：将导入的未使用的磁盘挂载到 scsi0
        qm set $vmid --scsi0 "$selected_storage:vm-$vmid-disk-0" >/dev/null 2>&1
        # 设置启动顺序
        qm set $vmid --boot order=scsi0 >/dev/null 2>&1
        echo -e "${GREEN}完成！磁盘已成功注入并设为第一启动项。${NC}"
    else
        echo -e "${RED}导入失败。请检查存储空间或 VM 状态。${NC}"
    fi
    
    [[ "$file_name" == *.gz ]] && rm -f "$temp_img"

# ==================== 模式 2: LXC 自动创建逻辑 ====================
elif [ "$mode" == "2" ]; then
    echo -e ">> 进入 ${BLUE}[LXC 容器]${NC} 全自动创建模式"
    echo "提示：LXC 模式无需提前创建空壳，脚本将自动完成所有配置。"
    echo "-----------------------------------------------------"
    
    suggest_id=$(pvesh get /cluster/nextid)
    read -p "[配置] 容器 ID (建议 $suggest_id): " ctid; ctid=${ctid:-$suggest_id}
    read -p "[配置] CPU 核心 (默认 1): " cores; cores=${cores:-1}
    read -p "[配置] 内存 MB (默认 512): " mem; mem=${mem:-512}
    read -p "[配置] 磁盘 GB (默认 2): " dsize; dsize=${dsize:-2}
    read -p "[配置] 网络桥接 (默认 vmbr0): " br; br=${br:-vmbr0}

    # 选择存储
    echo -e "\n可用存储:"
    storage_list=($(pvesm status -content rootdir | awk 'NR>1 {print $1}'))
    for i in "${!storage_list[@]}"; do echo " [$((i+1))] ${storage_list[$i]}"; done
    read -p "请选择存储位置 (默认 1): " s_idx; s_idx=${s_idx:-1}
    selected_storage="${storage_list[$((s_idx-1))]}"

    echo -e "\n[进度] 正在为您全自动创建 LXC 容器..."
    # --unprivileged 0 代表创建特权容器，适合某些需要特殊权限的 OpenWrt 插件
    pct create $ctid "$selected_file" --hostname "LXC-$ctid" --storage "$selected_storage" \
        --rootfs "$selected_storage:$dsize" --cores "$cores" --memory "$mem" \
        --net0 name=eth0,bridge=$br,ip=dhcp --unprivileged 0 >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}完成！LXC $ctid 已就绪。${NC}"
    else
        echo -e "${RED}创建失败。请检查镜像是否为正确的 rootfs.tar 格式。${NC}"
    fi
fi

echo -e "\n操作结束，感谢使用。";