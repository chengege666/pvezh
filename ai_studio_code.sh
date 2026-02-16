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
echo -e "${YELLOW}--- VM 镜像 ---${NC}"
for f in "${vm_files[@]}"; do echo " [$count] $(basename "$f")"; merged_files+=("$f"); ((count++)); done
echo -e "\n${YELLOW}--- LXC 镜像 ---${NC}"
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

suggest_id=$(pvesh get /cluster/nextid)

if [ "$mode" == "1" ]; then
    echo -e ">> 进入 ${BLUE}[VM 虚拟机]${NC} 模式"
    echo " [1] 全自动创建新虚拟机"
    echo " [2] 注入现有虚拟机 (空壳)"
    read -p "请选择操作类型 (默认 1): " vm_op
    vm_op=${vm_op:-1}

    if [ "$vm_op" == "1" ]; then
        read -p "[配置] 请输入新虚拟机 ID: " vmid; vmid=${vmid:-$suggest_id}
        read -p "[配置] 虚拟机名称 (默认 OpenWrt-VM): " vname; vname=${vname:-OpenWrt-VM}
        read -p "[配置] CPU 核心数 (默认 1): " vcores; vcores=${vcores:-1}
        echo "  [1] host (物理机直通)"
        echo "  [2] kvm64 (标准兼容)"
        read -p "  请选择 CPU 模式 (默认 1): " cpu_idx; cpu_idx=${cpu_idx:-1}
        [[ "$cpu_idx" == "2" ]] && vcpu="kvm64" || vcpu="host"
        read -p "[配置] 内存大小 MB (默认 512): " vmem; vmem=${vmem:-512}
        read -p "[配置] 网络桥接 (默认 vmbr0): " vbr; vbr=${vbr:-vmbr0}
        read -p "[配置] 引导模式 [1] SeaBIOS [2] OVMF(UEFI) (默认 1): " v_bios; v_bios=${v_bios:-1}
        
        storage_list=($(pvesm status -content images | awk 'NR>1 {print $1}'))
        echo -e "\n[系统] 可用存储:"
        for i in "${!storage_list[@]}"; do echo "  $(($i+1))) ${storage_list[$i]}"; done
        read -p "请选择存储位置 (默认 1): " st_idx; st_idx=${st_idx:-1}
        vst=${storage_list[$(($st_idx-1))]}

        echo -e "\n确认创建: VM $vmid ($vname), $vcores 核($vcpu), $vmem MB, 存储 $vst"
        read -p "确认继续? (y/n, 默认 y): " confirm; [[ "${confirm:-y}" != "y" ]] && exit 0

        echo -ne "[进度] 正在创建虚拟机... "
        bios_opt=""
        [[ "$v_bios" == "2" ]] && bios_opt="--bios ovmf"
        qm create $vmid --name "$vname" --net0 virtio,bridge=$vbr --cores $vcores --memory $vmem --cpu $vcpu --ostype l26 $bios_opt >/dev/null 2>&1
        [[ "$v_bios" == "2" ]] && qm set $vmid --efidisk0 $vst:0 >/dev/null 2>&1
        echo -e "${GREEN}完成${NC}"
    else
        qm list
        read -p "请输入目标 VM ID: " vmid
        storage_list=($(pvesm status -content images | awk 'NR>1 {print $1}'))
        vst=${storage_list[0]}
    fi

    temp_img="/tmp/imp_$vmid.img"
    echo -ne "[进度] 正在处理磁盘并注入... "
    [[ "$file_name" == *.gz ]] && zcat "$selected_file" > "$temp_img" || cp "$selected_file" "$temp_img"
    qm importdisk $vmid "$temp_img" "$vst" >/dev/null 2>&1
    qm set $vmid --scsihw virtio-scsi-pci --scsi0 "$vst:vm-$vmid-disk-0" --boot order=scsi0 >/dev/null 2>&1
    echo -e "${GREEN}完成${NC}"
    rm -f "$temp_img"
    echo -e ">> 操作成功：VM $vmid 已就绪。"

elif [ "$mode" == "2" ]; then
    echo -e ">> 进入 ${BLUE}[LXC 容器]${NC} 模式"
    read -p "[配置] 容器 ID: " ctid; ctid=${ctid:-$suggest_id}
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
        [[ "$file_name" == *.gz ]] && zcat "$selected_file" > "$raw_img" || cp "$selected_file" "$raw_img"
        loop_dev=$(losetup -fP --show "$raw_img")
        mount "${loop_dev}p2" "$tmp_mnt" >/dev/null 2>&1 || mount "$loop_dev" "$tmp_mnt" >/dev/null 2>&1
        final_tar="/var/lib/vz/template/cache/lxc_auto_$ctid.tar.gz"
        (cd "$tmp_mnt" && tar -czf "$final_tar" .)
        umount "$tmp_mnt" && losetup -d "$loop_dev" && rm -rf "$tmp_mnt" && rm -f "$raw_img"
        echo -e "${GREEN}  -> 转换完成！${NC}"
    fi

    echo -ne "[进度] 正在创建容器... "
    if pct create $ctid "$final_tar" --arch amd64 --hostname "$cname" --rootfs "$selected_storage:$dsize" \
      --memory "$mem" --cores "$cores" --ostype unmanaged --unprivileged 1 --net0 name=eth0,bridge=$br,ip=manual >/dev/null 2>&1; then
        echo -e "${GREEN}完成！${NC}"
    else
        echo -e "${RED}失败！${NC}"
    fi
fi