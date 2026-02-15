#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
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
echo -e "${YELLOW}--- VM 镜像 (需提前创建 VM 空壳) ---${NC}"
for f in "${vm_files[@]}"; do
    echo " [$count] $(basename "$f")"
    merged_files+=("$f")
    ((count++))
done

echo ""
echo -e "${YELLOW}--- LXC 镜像 (支持全自动创建) ---${NC}"
for f in "${lxc_files[@]}"; do
    echo " [$count] $(basename "$f")"
    merged_files+=("$f")
    ((count++))
done
echo "====================================================="

read -p "请选择镜像编号 (默认 1): " file_idx
file_idx=${file_idx:-1}
selected_file="${merged_files[$(($file_idx-1))]}"
file_name=$(basename "$selected_file")
echo -e ">> 已选择: ${GREEN}$file_name${NC}\n"

# --- 2. 选择模式 ---
suggest_mode=1
[[ "$file_name" == *.tar* ]] && suggest_mode=2
echo "请选择安装模式:"
echo -e " [1] 虚拟机 (VM)"
echo -e " [2] 容器 (LXC)"
read -p "您的选择 (默认 $suggest_mode): " mode
mode=${mode:-$suggest_mode}

# ==================== 模式 1: VM 模式 (原样) ====================
if [ "$mode" == "1" ]; then
    # ... (VM 逻辑保持不变，为节省篇幅略，代码逻辑同前)
    read -p "请输入目标 VM ID: " vmid
    storage_list=($(pvesm status -content images | awk 'NR>1 {print $1}'))
    selected_storage=${storage_list[0]}
    temp_img="/tmp/temp_$vmid.img"
    [[ "$file_name" == *.gz ]] && zcat "$selected_file" > "$temp_img" || temp_img="$selected_file"
    qm importdisk $vmid "$temp_img" "$selected_storage" >/dev/null
    qm set $vmid --scsi0 "$selected_storage:vm-$vmid-disk-0" --boot order=scsi0 >/dev/null
    echo -e "${GREEN}VM 导入完成。${NC}"

# ==================== 模式 2: LXC 模式 (增加自动转换) ====================
elif [ "$mode" == "2" ]; then
    echo -e ">> 进入 ${BLUE}[LXC 容器]${NC} 自动创建模式"
    
    # 资源配置输入
    suggest_id=$(pvesh get /cluster/nextid)
    read -p "[配置] 容器 ID (建议 $suggest_id): " ctid; ctid=${ctid:-$suggest_id}
    read -p "[配置] CPU 核心 (默认 1): " cores; cores=${cores:-1}
    read -p "[配置] 内存 MB (默认 512): " mem; mem=${mem:-512}
    read -p "[配置] 磁盘 GB (默认 2): " dsize; dsize=${dsize:-2}
    read -p "[配置] 网络桥接 (默认 vmbr0): " br; br=${br:-vmbr0}

    # 存储选择
    storage_list=($(pvesm status -content rootdir | awk 'NR>1 {print $1}'))
    selected_storage=${storage_list[0]}

    echo -e "\n[进度] 正在检查镜像格式..."
    final_lxc_tar="$selected_file"

    # --- 核心：如果是 .img，执行转换逻辑 ---
    if [[ "$file_name" == *.img || "$file_name" == *.img.gz ]]; then
        echo -e "${YELLOW}[转换] 检测到您选择了 .img，正在将其转为 LXC 专用的 rootfs.tar...${NC}"
        
        tmp_dir="/tmp/lxc_conv_$ctid"
        raw_img="/tmp/raw_$ctid.img"
        mkdir -p "$tmp_dir"

        # 1. 解压 gz (如果有)
        if [[ "$file_name" == *.gz ]]; then
            echo "  -> 正在解压镜像..."
            zcat "$selected_file" > "$raw_img"
        else
            raw_img="$selected_file"
        fi

        # 2. 挂载镜像提取内容 (寻找根分区)
        echo "  -> 正在提取文件系统内容..."
        # 尝试寻找分区偏移量 (针对 OpenWrt 常见的第2分区)
        offset=$(fdisk -l "$raw_img" | grep 'img2' | awk '{print $2 * 512}')
        if [ -z "$offset" ]; then
            # 如果没分区表，尝试直接挂载
            mount -o loop "$raw_img" "$tmp_dir" >/dev/null 2>&1
        else
            mount -o loop,offset=$offset "$raw_img" "$tmp_dir" >/dev/null 2>&1
        fi

        # 3. 封装为 tar
        final_lxc_tar="/tmp/lxc_rootfs_$ctid.tar.gz"
        echo "  -> 正在打包 rootfs.tar.gz..."
        tar -C "$tmp_dir" -zcf "$final_lxc_tar" .
        
        # 4. 卸载并清理
        umount "$tmp_dir"
        rm -rf "$tmp_dir"
        [[ "$file_name" == *.gz ]] && rm -f "$raw_img"
        echo -e "${GREEN}  -> 转换成功！${NC}"
    fi

    # --- 开始创建 LXC ---
    echo -ne "[进度] 正在创建并初始化容器... "
    pct create $ctid "$final_lxc_tar" --hostname "LXC-$ctid" --storage "$selected_storage" \
        --rootfs "$selected_storage:$dsize" --cores "$cores" --memory "$mem" \
        --net0 name=eth0,bridge=$br,ip=dhcp --unprivileged 0 >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}完成！${NC}"
        # 清理生成的临时 tar
        [[ "$final_lxc_tar" == /tmp/* ]] && rm -f "$final_lxc_tar"
    else
        echo -e "${RED}失败！请检查系统是否安装了 fdisk 或镜像是否损坏。${NC}"
    fi
fi