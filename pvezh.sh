
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo "====================================================="
echo -e "${BLUE}          PVE 镜像转换工具 (VM & LXC) ${NC}"
echo "====================================================="

scan_dirs=("./" "/var/lib/vz/template/iso/" "/var/lib/vz/template/cache/")
all_found=($(find "${scan_dirs[@]}" -maxdepth 1 -type f \( -name "*.img" -o -name "*.img.gz" -o -name "*.tar.gz" -o -name "*.tar.zst" -o -name "*.tar.xz" \) 2>/dev/null))

if [ ${#all_found[@]} -eq 0 ]; then
    echo -e "${RED}[错误] 未找到任何可用镜像文件。${NC}"
    exit 1
fi

vm_files=(); lxc_files=()
for f in "${all_found[@]}"; do
    [[ "$f" == *.img || "$f" == *.img.gz ]] && vm_files+=("$f") || lxc_files+=("$f")
done

count=1
merged_files=()
echo -e "${YELLOW}--- VM 镜像 (需提前创建 VM 空壳) ---${NC}"
for f in "${vm_files[@]}"; do echo " [$count] $(basename "$f")"; merged_files+=("$f"); ((count++)); done
echo -e "\n${YELLOW}--- LXC 镜像 (支持全自动创建) ---${NC}"
for f in "${lxc_files[@]}"; do echo " [$count] $(basename "$f")"; merged_files+=("$f"); ((count++)); done
echo "====================================================="

read -p "请选择镜像编号 (默认 1): " file_idx
file_idx=${file_idx:-1}
selected_file="${merged_files[$(($file_idx-1))]}"
file_name=$(basename "$selected_file")
echo -e ">> 已选择: ${GREEN}$file_name${NC}\n"

suggest_mode=1
[[ "$file_name" == *.tar* ]] && suggest_mode=2
echo "请选择安装模式:"
echo " [1] 虚拟机 (VM)"
echo " [2] 容器 (LXC)"
read -p "您的选择 (默认 $suggest_mode): " mode
mode=${mode:-$suggest_mode}

if [ "$mode" == "1" ]; then
    echo -e ">> 进入 ${BLUE}[VM 虚拟机]${NC} 注入模式"
    qm list
    read -p "请输入目标 VM ID: " vmid
    storage_list=($(pvesm status -content images | awk 'NR>1 {print $1}'))
    selected_storage=${storage_list[0]}
    temp_img="/tmp/imp_$vmid.img"
    [[ "$file_name" == *.gz ]] && zcat "$selected_file" > "$temp_img" || temp_img="$selected_file"
    echo -ne "[进度] 正在注入磁盘... "
    qm importdisk $vmid "$temp_img" "$selected_storage" >/dev/null && \
    qm set $vmid --scsi0 "$selected_storage:vm-$vmid-disk-0" --boot order=scsi0 >/dev/null
    echo -e "${GREEN}完成${NC}"
    [[ "$file_name" == *.gz ]] && rm -f "$temp_img"

elif [ "$mode" == "2" ]; then
    echo -e ">> 进入 ${BLUE}[LXC 容器]${NC} 模式"
    
    suggest_id=$(pvesh get /cluster/nextid)
    read -p "[配置] 请输入自定义容器 ID (留空则使用未使用的 ID): " ctid; ctid=${ctid:-$suggest_id}
    
    read -p "[配置] 容器名称 (默认 OpenWrt-LXC): " cname; cname=${cname:-OpenWrt-LXC}
    
    read -p "[配置] CPU 核心 (默认 1): " cores; cores=${cores:-1}
    read -p "[配置] 内存 MB (默认 512): " mem; mem=${mem:-512}
    read -p "[配置] 磁盘大小 (G, 默认 4): " dsize; dsize=${dsize:-4}
    read -p "[配置] 网络桥接 (默认 vmbr0): " br; br=${br:-vmbr0}

    storage_list=($(pvesm status -content rootdir | awk 'NR>1 {print $1}'))
    selected_storage=${storage_list[0]}

    final_tar="$selected_file"

    if [[ "$file_name" == *.img || "$file_name" == *.img.gz ]]; then
        echo -e "${YELLOW}[第一阶段] 正在将 .img 转换为 LXC 模版...${NC}"
        raw_img="/tmp/lxc_raw_$ctid.img"
        tmp_mnt="/mnt/lxc_mnt_$ctid"
        mkdir -p "$tmp_mnt"

        if [[ "$file_name" == *.gz ]]; then
            echo "  -> 正在解压镜像..."
            zcat "$selected_file" > "$raw_img"
        else
            raw_img="$selected_file"
        fi

        echo "  -> 正在通过回环设备挂载..."
        loop_dev=$(losetup -fP --show "$raw_img")
        
        echo "  -> 正在尝试挂载分区..."
        if ! mount "${loop_dev}p2" "$tmp_mnt" >/dev/null 2>&1; then
            mount "$loop_dev" "$tmp_mnt" >/dev/null 2>&1
        fi

        final_tar="/var/lib/vz/template/cache/lxc_auto_$ctid.tar.gz"
        echo "  -> 正在打包文件系统到 $final_tar ..."
        cd "$tmp_mnt" || exit
        tar -czf "$final_tar" .
        cd - >/dev/null || exit

        echo "  -> 正在清理转换环境..."
        umount "$tmp_mnt"
        losetup -d "$loop_dev"
        rm -rf "$tmp_mnt"
        [[ "$file_name" == *.gz ]] && rm -f "$raw_img"
        echo -e "${GREEN}  -> 转换转换完成！${NC}"
    fi

    echo -ne "[进度] 正在创建容器 $cname (ID: $ctid)... "
    if pct create $ctid "$final_tar" \
      --arch amd64 \
      --hostname "$cname" \
      --rootfs "$selected_storage:$dsize" \
      --memory "$mem" \
      --cores "$cores" \
      --ostype unmanaged \
      --unprivileged 1 \
      --net0 name=eth0,bridge=$br,ip=manual >/dev/null 2>&1; then
        echo -e "${GREEN}完成！${NC}"
        echo -e "\n操作成功：容器已创建，名称为 ${BLUE}$cname${NC}。"
    else
        echo -e "${RED}失败！${NC}"
    fi
fi
