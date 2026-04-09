#!/bin/bash
# ============================================
# 服务器性能监控探针 v2.7 (修复 TOP IP)
# ============================================

export TERM=${TERM:-xterm-256color}

# 颜色定义（略，保持原样）
if command -v tput &>/dev/null; then
    BOLD=$(tput bold 2>/dev/null)
    RED=$(tput setaf 1 2>/dev/null)
    GREEN=$(tput setaf 2 2>/dev/null)
    YELLOW=$(tput setaf 3 2>/dev/null)
    BLUE=$(tput setaf 4 2>/dev/null)
    MAGENTA=$(tput setaf 5 2>/dev/null)
    CYAN=$(tput setaf 6 2>/dev/null)
    WHITE=$(tput setaf 7 2>/dev/null)
    NC=$(tput sgr0 2>/dev/null)
else
    BOLD='\033[1m'; RED='\033[0;31m'; GREEN='\033[0;32m'
    YELLOW='\033[1;33m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
fi

# ---------- 工具函数 ----------
get_network_interface() {
    local iface=$(ip route | grep default | awk '{print $5}' | head -1)
    [ -z "$iface" ] && iface=$(ls /sys/class/net/ | grep -v lo | head -1)
    echo "$iface"
}

# CPU
get_cpu_usage() { top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1; }
get_cpu_cores() { nproc; }
get_cpu_load() { uptime | awk -F'load average:' '{print $2}'; }

# 内存
get_memory_info() {
    local total=$(free -b | awk '/^Mem:/{print $2}')
    local used=$(free -b | awk '/^Mem:/{print $3}')
    local avail=$(free -b | awk '/^Mem:/{print $7}')
    local percent=$(awk "BEGIN {printf \"%.1f\", ($used/$total)*100}")
    local total_hr=$(numfmt --to=iec-i --suffix=B $total 2>/dev/null || echo "${total} B")
    local used_hr=$(numfmt --to=iec-i --suffix=B $used 2>/dev/null || echo "${used} B")
    local avail_hr=$(numfmt --to=iec-i --suffix=B $avail 2>/dev/null || echo "${avail} B")
    echo "$percent|$total_hr|$used_hr|$avail_hr"
}

get_swap_info() {
    local total=$(free -b | awk '/^Swap:/{print $2}')
    if [ -z "$total" ] || [ "$total" -eq 0 ]; then
        echo "0|未配置|0"
        return
    fi
    local used=$(free -b | awk '/^Swap:/{print $3}')
    local percent=$(awk "BEGIN {printf \"%.1f\", ($used/$total)*100}")
    local total_hr=$(numfmt --to=iec-i --suffix=B $total 2>/dev/null)
    local used_hr=$(numfmt --to=iec-i --suffix=B $used 2>/dev/null)
    echo "$percent|$total_hr|$used_hr"
}

# TCP/UDP 连接数
get_tcp_connections() {
    local estab=$(ss -t state established 2>/dev/null | tail -n +2 | wc -l)
    local listen=$(ss -t state listening 2>/dev/null | tail -n +2 | wc -l)
    local tw=$(ss -t state time-wait 2>/dev/null | tail -n +2 | wc -l)
    local cw=$(ss -t state close-wait 2>/dev/null | tail -n +2 | wc -l)
    local syn_sent=$(ss -t state syn-sent 2>/dev/null | tail -n +2 | wc -l)
    local syn_recv=$(ss -t state syn-recv 2>/dev/null | tail -n +2 | wc -l)
    echo "$estab|$listen|$tw|$cw|$syn_sent|$syn_recv"
}

get_udp_connections() {
    local total=$(ss -u 2>/dev/null | tail -n +2 | wc -l)
    local estab=$(ss -u state established 2>/dev/null | tail -n +2 | wc -l)
    local unconn=$(ss -u state unconn 2>/dev/null | tail -n +2 | wc -l)
    echo "$total|$estab|$unconn"
}

get_total_connections() { ss -tun 2>/dev/null | tail -n +2 | wc -l; }

# ========== 修复：获取 TOP3 远程 IP ==========
get_top_ips() {
    # 获取本机所有 IPv4 地址（排除回环）
    local local_ips=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | tr '\n' '|' | sed 's/|$//')
    [ -z "$local_ips" ] && local_ips="127.0.0.1"

    if command -v conntrack &>/dev/null; then
        # 提取所有 src= 和 dst= 的 IP，排除本机，统计前3
        conntrack -L 2>/dev/null | grep -E 'ESTABLISHED|ASSURED' | \
        grep -oP 'src=\K[0-9.]+|dst=\K[0-9.]+' | \
        grep -vE "^($local_ips)$" | \
        sort | uniq -c | sort -rn | head -3 | \
        awk '{printf "    %-15s 连接数: %s\n", $2, $1}'
    else
        # 降级使用 ss
        ss -tn state established 2>/dev/null | tail -n +2 | awk '{print $4}' | \
        sed -E 's/:[0-9]+$//' | grep -vE "^($local_ips)$" | \
        sort | uniq -c | sort -rn | head -3 | \
        awk '{printf "    %-15s 连接数: %s\n", $2, $1}'
    fi
}

# ---------- 网络流量 ----------
RX_BYTES=""; TX_BYTES=""; LAST_TIME=""

init_network_stats() {
    local iface=$1
    if [ -f "/sys/class/net/$iface/statistics/rx_bytes" ]; then
        RX_BYTES=$(cat /sys/class/net/$iface/statistics/rx_bytes)
        TX_BYTES=$(cat /sys/class/net/$iface/statistics/tx_bytes)
        LAST_TIME=$(date +%s%N)
    fi
}

get_network_speed() {
    local iface=$1
    local cur_rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null)
    local cur_tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null)
    local cur_time=$(date +%s%N)
    if [ -z "$cur_rx" ] || [ -z "$RX_BYTES" ]; then
        echo "0|0"
        return
    fi
    local diff=$(echo "scale=3; ($cur_time - $LAST_TIME) / 1000000000" | bc)
    local rx_speed=0; local tx_speed=0
    if [ "$(echo "$diff > 0" | bc)" -eq 1 ]; then
        rx_speed=$(echo "scale=0; ($cur_rx - $RX_BYTES) / $diff" | bc)
        tx_speed=$(echo "scale=0; ($cur_tx - $TX_BYTES) / $diff" | bc)
        [ "$rx_speed" -lt 0 ] && rx_speed=0
        [ "$tx_speed" -lt 0 ] && tx_speed=0
    fi
    RX_BYTES=$cur_rx; TX_BYTES=$cur_tx; LAST_TIME=$cur_time
    echo "$rx_speed|$tx_speed"
}

get_total_traffic() {
    local iface=$1
    local rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null)
    local tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null)
    local rx_hr=$(numfmt --to=iec-i --suffix=B $rx 2>/dev/null || echo "0 B")
    local tx_hr=$(numfmt --to=iec-i --suffix=B $tx 2>/dev/null || echo "0 B")
    echo "$rx_hr|$tx_hr"
}

format_speed() {
    local s=$1
    if [ -z "$s" ] || [ "$s" -lt 0 ]; then echo "0 B/s"; return; fi
    if [ "$s" -ge 1073741824 ]; then echo "$(echo "scale=1; $s/1073741824" | bc) GB/s"
    elif [ "$s" -ge 1048576 ]; then echo "$(echo "scale=1; $s/1048576" | bc) MB/s"
    elif [ "$s" -ge 1024 ]; then echo "$(echo "scale=0; $s/1024" | bc) KB/s"
    else echo "${s} B/s"; fi
}

get_uptime() {
    local sec=$(cat /proc/uptime | awk '{print $1}' | cut -d. -f1)
    local d=$((sec/86400)); local h=$(((sec%86400)/3600)); local m=$(((sec%3600)/60))
    if [ $d -gt 0 ]; then echo "${d}d ${h}h ${m}m"
    elif [ $h -gt 0 ]; then echo "${h}h ${m}m"
    else echo "${m}m"; fi
}

get_system_info() {
    local hn=$(hostname)
    local os=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 | cut -d' ' -f1-2)
    local kr=$(uname -r)
    echo "$hn|$os|$kr"
}

draw_bar() {
    local p=$1
    if ! [[ "$p" =~ ^[0-9]+\.?[0-9]*$ ]]; then p=0; fi
    local w=20
    local filled=$(echo "scale=0; $p * $w / 100" | bc 2>/dev/null || echo 0)
    local empty=$((w - filled))
    printf "["
    for ((i=0; i<filled; i++)); do printf "█"; done
    for ((i=0; i<empty; i++)); do printf "░"; done
    printf "] %5.1f%%" "$p"
}

get_color_by_usage() {
    local u=$1
    if ! [[ "$u" =~ ^[0-9]+\.?[0-9]*$ ]]; then echo "$GREEN"; return; fi
    if (( $(echo "$u >= 90" | bc -l 2>/dev/null || echo 0) )); then echo "$RED"
    elif (( $(echo "$u >= 70" | bc -l 2>/dev/null || echo 0) )); then echo "$YELLOW"
    else echo "$GREEN"; fi
}

# 卡片绘制
print_card_top() {
    echo "${CYAN}┌──────────────────────────────────────────────────┐${NC}"
    echo "${CYAN}│${BOLD} $(printf "%-48s" "$1")${NC}${CYAN}│${NC}"
    echo "${CYAN}├──────────────────────────────────────────────────┤${NC}"
}
print_card_bottom() { echo "${CYAN}└──────────────────────────────────────────────────┘${NC}"; }
print_card_line() { echo "${CYAN}│${NC} $(printf "%-50s" "$1")${CYAN}│${NC}"; }

clear_screen() { printf "\033[2J\033[H"; }

# 主显示
display_stats() {
    local iface=$1
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    
    local cpu_usage=$(get_cpu_usage)
    local cpu_cores=$(get_cpu_cores)
    local cpu_load=$(get_cpu_load)
    local mem_info=$(get_memory_info)
    local swap_info=$(get_swap_info)
    local tcp_info=$(get_tcp_connections)
    local udp_info=$(get_udp_connections)
    local total_conn=$(get_total_connections)
    local speed_info=$(get_network_speed "$iface")
    local traffic_info=$(get_total_traffic "$iface")
    local sys_info=$(get_system_info)
    local uptime=$(get_uptime)
    local top_ips=$(get_top_ips)
    
    IFS='|' read -r mem_percent mem_total mem_used mem_avail <<< "$mem_info"
    IFS='|' read -r swap_percent swap_total swap_used <<< "$swap_info"
    IFS='|' read -r tcp_estab tcp_listen tcp_tw tcp_cw tcp_syn_sent tcp_syn_recv <<< "$tcp_info"
    IFS='|' read -r udp_total udp_estab udp_unconn <<< "$udp_info"
    IFS='|' read -r rx_speed tx_speed <<< "$speed_info"
    IFS='|' read -r total_rx total_tx <<< "$traffic_info"
    IFS='|' read -r hostname os kernel <<< "$sys_info"
    
    local cpu_color=$(get_color_by_usage "$cpu_usage")
    local mem_color=$(get_color_by_usage "$mem_percent")
    local rx_speed_hr=$(format_speed "$rx_speed")
    local tx_speed_hr=$(format_speed "$tx_speed")
    
    clear_screen
    
    echo "${BOLD}${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    echo "${BOLD}${CYAN}║           🔍 服务器性能监控探针 v2.7                 ║${NC}"
    echo "${BOLD}${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    echo
    
    print_card_top "🖥️  系统信息"
    print_card_line "  主机名: ${WHITE}$hostname${NC}"
    print_card_line "  系统:   ${WHITE}$os${NC}"
    print_card_line "  内核:   ${WHITE}$kernel${NC}"
    print_card_line "  运行:   ${WHITE}$uptime${NC}"
    print_card_line "  时间:   ${WHITE}$ts${NC}"
    print_card_bottom; echo
    
    print_card_top "💻 CPU 状态"
    print_card_line "  核心数: ${WHITE}$cpu_cores${NC} 核"
    echo "${CYAN}│${NC}  使用率: ${cpu_color}$(draw_bar "$cpu_usage")${NC}${CYAN}│${NC}"
    print_card_line "  负载:   ${WHITE}$cpu_load${NC} (1/5/15分钟)"
    print_card_bottom; echo
    
    print_card_top "🧠 内存状态"
    print_card_line "  总量:   ${WHITE}$mem_total${NC}"
    echo "${CYAN}│${NC}  已用:   ${WHITE}$mem_used${NC} (${mem_color}$(draw_bar "$mem_percent")${NC})${CYAN}│${NC}"
    print_card_line "  可用:   ${WHITE}$mem_avail${NC}"
    if [ "$swap_total" != "未配置" ] && [ -n "$swap_total" ] && [ "$swap_total" != "0" ]; then
        echo "${CYAN}│${NC}  Swap:   ${WHITE}$swap_used / $swap_total${NC} ($(draw_bar "$swap_percent"))${CYAN}│${NC}"
    fi
    print_card_bottom; echo
    
    print_card_top "🌐 网络连接"
    print_card_line "  TCP 连接:"
    print_card_line "    ├─ ESTABLISHED: ${GREEN}$tcp_estab${NC}  |  LISTENING: ${BLUE}$tcp_listen${NC}"
    print_card_line "    ├─ TIME_WAIT:   ${YELLOW}$tcp_tw${NC}  |  CLOSE_WAIT: ${YELLOW}$tcp_cw${NC}"
    print_card_line "    └─ SYN_SENT:    ${MAGENTA}$tcp_syn_sent${NC}  |  SYN_RECV:  ${MAGENTA}$tcp_syn_recv${NC}"
    print_card_line "  UDP 连接:"
    print_card_line "    └─ 总数: ${GREEN}$udp_total${NC}  (已建立: $udp_estab | 未连接: $udp_unconn)"
    print_card_line "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_card_line "  ${BOLD}总连接数: ${WHITE}$total_conn${NC} (TCP+UDP)"
    print_card_line "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_card_line "  ${BOLD}📡 连接数 TOP3 远程 IP${NC}"
    if [ -n "$top_ips" ]; then
        echo "$top_ips" | while IFS= read -r line; do
            print_card_line "  $line"
        done
    else
        print_card_line "    暂无连接数据（请检查 conntrack 是否安装并运行）"
    fi
    print_card_bottom; echo
    
    print_card_top "📡 网络流量 ($iface)"
    print_card_line "  下载速度: ${GREEN}⬇️  $rx_speed_hr${NC}"
    print_card_line "  上传速度: ${RED}⬆️  $tx_speed_hr${NC}"
    print_card_line "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_card_line "  总下载:   ${WHITE}$total_rx${NC}"
    print_card_line "  总上传:   ${WHITE}$total_tx${NC}"
    print_card_bottom; echo
    
    echo "${YELLOW}💡 提示: 按 Ctrl+C 退出监控${NC}"
    echo "${BLUE}📊 刷新间隔: 1 秒${NC}"
}

# 依赖检查
check_dependencies() {
    local missing=()
    command -v bc &>/dev/null || missing+=("bc")
    command -v numfmt &>/dev/null || missing+=("coreutils")
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}缺少依赖: ${missing[*]}${NC}"
        echo -e "${BLUE}正在安装...${NC}"
        if command -v apt &>/dev/null; then
            apt update -y && apt install -y bc coreutils procps
        elif command -v yum &>/dev/null; then
            yum install -y bc coreutils procps-ng
        else
            echo -e "${RED}请手动安装: ${missing[*]}${NC}"
            exit 1
        fi
    fi
    # 注意：conntrack 不是必须，但为了显示转发 IP，建议安装
    if ! command -v conntrack &>/dev/null; then
        echo -e "${YELLOW}提示：未安装 conntrack，将无法显示转发连接的 IP。建议安装: apt install conntrack${NC}"
        sleep 2
    fi
}

cleanup() { echo -e "\n${GREEN}监控已停止${NC}"; exit 0; }
trap cleanup SIGINT SIGTERM

main() {
    check_dependencies
    INTERFACE=$(get_network_interface)
    if [ -z "$INTERFACE" ]; then
        echo -e "${RED}无法检测到网络接口${NC}"
        exit 1
    fi
    init_network_stats "$INTERFACE"
    echo -e "${GREEN}开始监控，网络接口: $INTERFACE${NC}"
    sleep 1
    while true; do
        display_stats "$INTERFACE"
        sleep 1
    done
}

main