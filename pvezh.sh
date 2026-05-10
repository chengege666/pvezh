#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

tmp_mnt=""
loop_dev=""
raw_img=""
temp_img=""

cleanup() {
    [ -d "$tmp_mnt" ] && umount "$tmp_mnt" 2>/dev/null
    [ -n "$loop_dev" ] && losetup -d "$loop_dev" 2>/dev/null
    [ -d "$tmp_mnt" ] && rm -rf "$tmp_mnt"
    [ -f "$raw_img" ] && rm -f "$raw_img"
    [ -f "$temp_img" ] && rm -f "$temp_img"
}
trap cleanup EXIT

clear
echo "====================================================="
echo -e "${BLUE}          PVE 镜像转换工具  ${NC}"
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
if ! [[ "$file_idx" =~ ^[0-9]+$ ]] || [ "$file_idx" -lt 1 ] || [ "$file_idx" -gt ${#merged_files[@]} ]; then
    echo -e "${RED}[错误] 无效的镜像编号: $file_idx${NC}"
    exit 1
fi
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

suggest_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

if [ "$mode" == "1" ]; then
    echo -e ">> 进入 ${BLUE}[VM 虚拟机]${NC} 模式"
    echo " [1] 全自动创建新虚拟机"
    echo " [2] 注入现有虚拟机 (空壳)"
    read -p "请选择操作类型 (默认 1): " vm_op
    vm_op=${vm_op:-1}

    if [ "$vm_op" == "1" ]; then
        read -p "[配置] 请输入新虚拟机 ID: " vmid; vmid=${vmid:-$suggest_id}
        echo "  [1] OpenWrt-VM (默认)"
        echo "  [2] ImmortalWrt-VM"
        echo "  [3] 自定义名称"
        read -p "[配置] 虚拟机名称选择 (默认 1): " vname_idx; vname_idx=${vname_idx:-1}
        if [ "$vname_idx" == "2" ]; then
            vname="ImmortalWrt-VM"
        elif [ "$vname_idx" == "3" ]; then
            read -p "[配置] 请输入自定义虚拟机名称: " vname
        else
            vname="OpenWrt-VM"
        fi
        read -p "[配置] CPU 核心数 (默认 1): " vcores; vcores=${vcores:-1}
        echo "  [1] host (物理机直通)"
        echo "  [2] kvm64 (标准兼容)"
        read -p "  请选择 CPU 模式 (默认 1): " cpu_idx; cpu_idx=${cpu_idx:-1}
        [[ "$cpu_idx" == "2" ]] && vcpu="kvm64" || vcpu="host"
        read -p "[配置] 内存大小 MB (默认 512): " vmem; vmem=${vmem:-512}
        
        echo "  [1] i440fx (默认/兼容性好)"
        echo "  [2] q35 (现代/支持 PCIe 直通)"
        read -p "  请选择机型 (默认 1): " mach_idx; mach_idx=${mach_idx:-1}
        [[ "$mach_idx" == "2" ]] && vmachine="q35" || vmachine="pc"
        [[ "$mach_idx" == "2" ]] && vmachine_label="q35" || vmachine_label="i440fx (pc)"

        read -p "[配置] 引导模式 [1] SeaBIOS [2] OVMF(UEFI) (默认 1): " v_bios; v_bios=${v_bios:-1}
        [[ "$v_bios" == "2" ]] && bios_label="OVMF (UEFI)" || bios_label="SeaBIOS"
        read -p "[高级] 是否开启 SSD 仿真与 Discard 优化? (y/n, 默认 y): " v_ssd; v_ssd=${v_ssd:-y}
        [[ "$v_ssd" == "y" ]] && ssd_label="开启" || ssd_label="关闭"
        read -p "[高级] 是否需要配置双网口 (WAN+LAN)? (y/n, 默认 n): " v_dual; v_dual=${v_dual:-n}
        [[ "$v_dual" == "y" ]] && dual_label="开启" || dual_label="关闭"
        read -p "  -> 网口 1 (eth0) 桥接至 (默认 vmbr0): " vbr0; vbr0=${vbr0:-vmbr0}
        if [ "$v_dual" == "y" ]; then
            read -p "  -> 网口 2 (eth1) 桥接至 (默认 vmbr1): " vbr1; vbr1=${vbr1:-vmbr1}
        fi

        storage_list=($(pvesm status -content images | awk 'NR>1 {print $1}'))
        echo -e "\n[系统] 可用存储:"
        for i in "${!storage_list[@]}"; do echo "  $(($i+1))) ${storage_list[$i]}"; done
        read -p "请选择存储位置 (默认 1): " st_idx; st_idx=${st_idx:-1}
        vst=${storage_list[$(($st_idx-1))]}

        echo -e "\n====================================================="
        echo -e "确认创建配置"
        echo -e "====================================================="
        echo -e " 虚拟机 ID   : $vmid"
        echo -e " 虚拟机名称  : $vname"
        echo -e " CPU         : $vcores 核 ($vcpu)"
        echo -e " 内存        : $vmem MB"
        echo -e " 机型        : $vmachine_label"
        echo -e " 引导模式    : $bios_label"
        echo -e " SSD 优化    : $ssd_label"
        echo -e " 双网口      : $dual_label"
        echo -e " 网口 1      : $vbr0"
        if [ "$v_dual" == "y" ]; then
            echo -e " 网口 2      : $vbr1"
        fi
        echo -e " 存储位置    : $vst"
        echo -e "====================================================="
        read -p "确认继续? (y/n, 默认 y): " confirm; [[ "${confirm:-y}" != "y" ]] && exit 0

        echo -ne "[进度] 正在创建虚拟机并配置网口... "
        bios_opt=""
        [[ "$v_bios" == "2" ]] && bios_opt="--bios ovmf"
        qm create "$vmid" --name "$vname" --net0 virtio,bridge="$vbr0" --cores "$vcores" --memory "$vmem" --cpu "$vcpu" --machine "$vmachine" --ostype l26 $bios_opt >/dev/null 2>&1
        [ "$v_dual" == "y" ] && qm set "$vmid" --net1 virtio,bridge="$vbr1" >/dev/null 2>&1
        [[ "$v_bios" == "2" ]] && qm set "$vmid" --efidisk0 "$vst:0" >/dev/null 2>&1
        echo -e "${GREEN}完成${NC}"
    else
        qm list
        read -p "请输入目标 VM ID: " vmid
        storage_list=($(pvesm status -content images | awk 'NR>1 {print $1}'))
        if [ ${#storage_list[@]} -eq 0 ]; then
            echo -e "${RED}[错误] 未找到可用存储。${NC}"
            exit 1
        fi
        vst=${storage_list[0]}
        read -p "[高级] 是否开启 SSD 仿真与 Discard 优化? (y/n, 默认 y): " v_ssd; v_ssd=${v_ssd:-y}
    fi

    # 【关键修改】使用 /var/tmp 替代 /tmp
    temp_img="/var/tmp/imp_$vmid.img"
    echo -ne "[进度] 正在解压并处理磁盘镜像... "
    if [[ "$file_name" == *.gz ]]; then
        if ! zcat "$selected_file" > "$temp_img" 2>&1; then
            echo -e "${RED}失败！原因：磁盘空间不足或文件损坏。${NC}"
            cleanup
            exit 1
        fi
    else
        if ! cp "$selected_file" "$temp_img" 2>&1; then
            echo -e "${RED}失败！原因：磁盘空间不足或文件损坏。${NC}"
            cleanup
            exit 1
        fi
    fi
    echo -e "${GREEN}完成${NC}"

    echo -ne "[进度] 正在注入磁盘并应用特性... "
    import_output=$(qm importdisk "$vmid" "$temp_img" "$vst" 2>&1)
    if echo "$import_output" | grep -q "Successfully imported"; then
        disk_id=$(echo "$import_output" | grep -oP "as\s+'\K[^']+")
        [ "$v_ssd" == "y" ] && disk_id="$disk_id,discard=on,ssd=1"
        qm set "$vmid" --scsihw virtio-scsi-pci --scsi0 "$disk_id" --boot order=scsi0 >/dev/null 2>&1
        echo -e "${GREEN}完成${NC}"
    else
        echo -e "${RED}失败！$(echo "$import_output" | head -1)${NC}"
        exit 1
    fi
    
    rm -f "$temp_img"
    echo -e ">> 操作成功：VM $vmid 已就绪。"

elif [ "$mode" == "2" ]; then
    echo -e ">> 进入 ${BLUE}[LXC 容器]${NC} 模式"
    read -p "[配置] 容器 ID: " ctid; ctid=${ctid:-$suggest_id}
    echo " [1] OpenWrt-LXC (默认)"
    echo " [2] ImmortalWrt-LXC"
    echo " [3] 自定义名称"
    read -p "[配置] 容器名称选择 (默认 1): " cname_idx; cname_idx=${cname_idx:-1}
    if [ "$cname_idx" == "2" ]; then
        cname="ImmortalWrt-LXC"
    elif [ "$cname_idx" == "3" ]; then
        read -p "[配置] 请输入自定义容器名称: " cname
    else
        cname="OpenWrt-LXC"
    fi
    
    echo " [1] 非特权 (更安全, 默认)"
    echo " [2] 特权 (支持拨号/硬件直接访问)"
    read -p "权限 模式选择 (默认 1): " priv_idx; priv_idx=${priv_idx:-1}
    [[ "$priv_idx" == "2" ]] && unpriv=0 || unpriv=1
    [[ "$priv_idx" == "2" ]] && priv_label="特权" || priv_label="非特权"

    read -p "[配置] CPU 核心 (默认 1): " cores; cores=${cores:-1}
    read -p "[配置] 内存 MB (默认 512): " mem; mem=${mem:-512}
    read -p "[配置] 虚拟内存 Swap MB (默认 512): " swap_val; swap_val=${swap_val:-512}
    read -p "[配置] 磁盘大小 (G, 默认 4): " dsize; dsize=${dsize:-4}
    read -p "[配置] 网络桥接 (默认 vmbr0): " br; br=${br:-vmbr0}
    
    echo -e "--- 高级选项 ---"
    read -p "[配置] 开启 Nesting 虚拟化 (y/n, 默认 y): " nesting; nesting=${nesting:-y}
    [[ "$nesting" == "y" ]] && nesting_label="开启" || nesting_label="关闭"
    read -p "[配置] 激活 /etc/rc.local 执行权限? (y/n, 默认 y): " opt_rc; opt_rc=${opt_rc:-y}
    [[ "$opt_rc" == "y" ]] && rc_label="开启" || rc_label="关闭"
    read -p "[配置] 自定义 DNS (留空使用宿主机): " dns_server
    [ -n "$dns_server" ] && dns_label="$dns_server" || dns_label="(使用宿主机)"

    storage_list=($(pvesm status -content rootdir | awk 'NR>1 {print $1}'))
    if [ ${#storage_list[@]} -eq 0 ]; then
        echo -e "${RED}[错误] 未找到可用存储。${NC}"
        exit 1
    fi
    selected_storage=${storage_list[0]}

    final_tar="$selected_file"
    if [[ "$file_name" == *.img || "$file_name" == *.img.gz ]]; then
        echo -e "${YELLOW}[第一阶段] 正在将 .img 转换为 LXC 模版...${NC}"
        # 【关键修改】使用 /var/tmp 替代 /tmp
        raw_img="/var/tmp/lxc_raw_$ctid.img"
        tmp_mnt="/var/tmp/lxc_mnt_$ctid"
        mkdir -p "$tmp_mnt"
        
        if [[ "$file_name" == *.gz ]]; then
            if ! zcat "$selected_file" > "$raw_img" 2>&1; then
                echo -e "${RED}转换失败：磁盘空间不足。${NC}"
                cleanup
                exit 1
            fi
        else
            if ! cp "$selected_file" "$raw_img" 2>&1; then
                echo -e "${RED}转换失败：磁盘空间不足。${NC}"
                cleanup
                exit 1
            fi
        fi
        
        loop_dev=$(losetup -fP --show "$raw_img" 2>/dev/null || true)
        if [ -z "$loop_dev" ]; then
            echo -e "${RED}转换失败：无法创建 loop 设备。${NC}"
            cleanup
            exit 1
        fi
        if ! mount "${loop_dev}p2" "$tmp_mnt" >/dev/null 2>&1; then
            if ! mount "${loop_dev}p1" "$tmp_mnt" >/dev/null 2>&1; then
                if ! mount "$loop_dev" "$tmp_mnt" >/dev/null 2>&1; then
                    echo -e "${RED}转换失败：无法挂载镜像分区。${NC}"
                    cleanup
                    exit 1
                fi
            fi
        fi

        # 处理 rc.local 权限
        if [ "$opt_rc" == "y" ] && [ -f "$tmp_mnt/etc/rc.local" ]; then
            chmod +x "$tmp_mnt/etc/rc.local"
            echo -e "  -> 已激活 /etc/rc.local"
        fi

        final_tar="/var/lib/vz/template/cache/lxc_auto_$ctid.tar.gz"
        if ! (cd "$tmp_mnt" && tar -czf "$final_tar" .); then
            echo -e "${RED}转换失败：tar 打包出错。${NC}"
            cleanup
            exit 1
        fi
        umount "$tmp_mnt" && losetup -d "$loop_dev" && rm -rf "$tmp_mnt" && rm -f "$raw_img"
        loop_dev=""
        echo -e "${GREEN}  -> 转换完成！${NC}"
    fi

    echo -e "\n====================================================="
    echo -e "确认创建配置"
    echo -e "====================================================="
    echo -e " 容器 ID     : $ctid"
    echo -e " 容器名称    : $cname"
    echo -e " 权限模式    : $priv_label"
    echo -e " CPU         : $cores 核"
    echo -e " 内存        : $mem MB"
    echo -e " Swap        : $swap_val MB"
    echo -e " 磁盘大小    : $dsize G"
    echo -e " 网络桥接    : $br"
    echo -e " Nesting     : $nesting_label"
    echo -e " rc.local    : $rc_label"
    echo -e " 自定义 DNS  : $dns_label"
    echo -e " 存储位置    : $selected_storage"
    echo -e "====================================================="
    read -p "确认继续? (y/n, 默认 y): " confirm; [[ "${confirm:-y}" != "y" ]] && exit 0

    echo -ne "[进度] 正在创建容器... "
    
    # 构建 LXC 额外参数
    extra_opts=""
    [ "$nesting" == "y" ] && extra_opts="--features nesting=1"
    [ -n "$dns_server" ] && extra_opts="$extra_opts --nameserver $dns_server"

    if pct create "$ctid" "$final_tar" --arch amd64 --hostname "$cname" --rootfs "$selected_storage:$dsize" \
      --memory "$mem" --swap "$swap_val" --cores "$cores" --ostype unmanaged --unprivileged "$unpriv" \
      --net0 name=eth0,bridge="$br",ip=manual $extra_opts >/dev/null 2>&1; then
        echo -e "${GREEN}完成${NC}"
        echo -e "\n>> 操作成功：LXC 容器 $ctid 已就绪。"
    else
        echo -e "${RED}失败！请检查容器配置或模版是否完整。${NC}"
    fi
fi