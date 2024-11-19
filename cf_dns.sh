#!/bin/bash

# 颜色定义 - 与Python rich库颜色保持一致
RED='\033[0;31m'      # 错误信息
GREEN='\033[0;32m'    # 成功信息
YELLOW='\033[0;33m'   # 提示/警告
BLUE='\033[0;34m'     # TTL
MAGENTA='\033[0;35m'  # 名称
CYAN='\033[0;36m'     # 序号
NC='\033[0m'          # 无颜色

# 从配置文件加载认证信息
CONFIG_FILE="config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}错误：找不到config.env文件${NC}"
    exit 1
fi

# 加载配置
source "$CONFIG_FILE"

# 检查必要的配置是否存在
if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_ZONE_IDS" ]; then
    echo -e "${RED}错误：配置文件中缺少必要的配置项${NC}"
    exit 1
fi

# 获取区域信息
get_zone_info() {
    local zone_id=$1
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json"
}

# 选择区域
select_zone() {
    # 先获取所有域名信息
    echo -e "\n${CYAN}正在获取域名信息...${NC}"
    
    # 创建数组存储域名和ID的对应系
    local zone_names=()
    local valid_zone_ids=()
    local i=0
    
    # 先获取所有域名信息并存储
    for zone_id in "${CF_ZONE_IDS[@]}"; do
        local zone_info=$(get_zone_info "$zone_id")
        if [ "$(echo "$zone_info" | jq '.success')" = "true" ]; then
            local zone_name=$(echo "$zone_info" | jq -r '.result.name')
            zone_names[$i]="$zone_name"
            valid_zone_ids[$i]="$zone_id"
            ((i++))
        else
            echo -e "${RED}获取域名信息失败: $zone_id${NC}"
        fi
    done

    # 如果只有一个域名，直接使用
    if [ ${#zone_names[@]} -eq 1 ]; then
        echo -e "${GREEN}使用域名: ${YELLOW}${zone_names[0]}${NC}"
        echo "${valid_zone_ids[0]}"
        return
    fi

    # 显示所有可用域名
    echo -e "\n${CYAN}可用的域名：${NC}"
    for ((i=0; i<${#zone_names[@]}; i++)); do
        echo -e "$((i+1)). ${YELLOW}${zone_names[$i]}${NC}"
    done

    # 让用户选择
    while true; do
        read -p $'\n请选择域名序号 (1-'${#zone_names[@]}'): ' choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#zone_names[@]} ]; then
            local selected_index=$((choice-1))
            echo -e "${GREEN}已选择域名: ${YELLOW}${zone_names[$selected_index]}${NC}"
            echo "${valid_zone_ids[$selected_index]}"
            break
        else
            echo -e "${RED}无效的选择，请重试${NC}"
        fi
    done
}

# 获取所有DNS记录
get_records() {
    curl -s -X GET "$BASE_URL" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json"
}

# 显示DNS记录
display_records() {
    local records=$1
    
    # 检查是否成功获取记录
    if [ "$(echo "$records" | jq '.success')" != "true" ]; then
        echo -e "${RED}获取DNS记录失败：$(echo "$records" | jq -r '.errors[].message')${NC}"
        return
    fi
    
    # 获取记录总数
    local count=$(echo "$records" | jq '.result | length')
    if [ "$count" -eq 0 ]; then
        echo -e "\n${YELLOW}当前没有DNS记录${NC}"
        return
    fi
    
    echo -e "\n${CYAN}当前DNS记录：${NC}"
    printf "${CYAN}%-4s${NC} | ${MAGENTA}%-30s${NC} | ${GREEN}%-6s${NC} | ${YELLOW}%-30s${NC} | ${BLUE}%-5s${NC}\n" \
        "序号" "名称" "类型" "内容" "TTL"
    printf "%.s-" {1..80}
    echo
    
    while read -r line; do
        IFS='|' read -r num name type content ttl <<< "$line"
        printf "${CYAN}%-4s${NC} | ${MAGENTA}%-30s${NC} | ${GREEN}%-6s${NC} | ${YELLOW}%-30s${NC} | ${BLUE}%-5s${NC}\n" \
            "$num" "$name" "$type" "$content" "$ttl"
    done < <(echo "$records" | jq -r '.result | to_entries | .[] | "\(.key+1) | \(.value.name) | \(.value.type) | \(.value.content) | \(.value.ttl)"')
}

# 添加新记录
add_record() {
    echo -e "${YELLOW}请输入新DNS记录的信息：${NC}"
    read -p "名称: " name
    read -p "类型 (A/AAAA/CNAME/TXT): " type
    read -p "内容: " content
    read -p "TTL (按回车使用自动): " ttl

    [ -z "$ttl" ] && ttl=1
    
    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$SELECTED_ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"name\": \"$name\",
            \"type\": \"${type^^}\",
            \"content\": \"$content\",
            \"ttl\": $ttl
        }")

    if [ "$(echo "$response" | jq '.success')" = "true" ]; then
        echo -e "${GREEN}DNS记录添加成功！${NC}"
    else
        echo -e "${RED}添加DNS记录失败：$(echo "$response" | jq -r '.errors[].message')${NC}"
    fi
}

# 更新记录
update_record() {
    local records=$1
    display_records "$records"
    
    echo -e "\n${YELLOW}请选择要修改的记录序号：${NC}"
    read -p "序号: " idx
    
    # 检查输入是否有效
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$(echo "$records" | jq '.result | length')" ]; then
        echo -e "${RED}无效的选择${NC}"
        return
    fi

    # 获取选中的记录
    local record_id=$(echo "$records" | jq -r ".result[$(($idx-1))].id")
    local record_name=$(echo "$records" | jq -r ".result[$(($idx-1))].name")
    local record_type=$(echo "$records" | jq -r ".result[$(($idx-1))].type")
    local record_content=$(echo "$records" | jq -r ".result[$(($idx-1))].content")
    local record_ttl=$(echo "$records" | jq -r ".result[$(($idx-1))].ttl")

    echo -e "${YELLOW}正在修改记录 $record_name ($record_type)${NC}"
    read -p "新的内容 (直接回车保持不变): " new_content
    read -p "新的TTL (直接回车保持不变): " new_ttl

    [ -z "$new_content" ] && new_content="$record_content"
    [ -z "$new_ttl" ] && new_ttl="$record_ttl"

    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$SELECTED_ZONE_ID/dns_records/$record_id" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"name\": \"$record_name\",
            \"type\": \"$record_type\",
            \"content\": \"$new_content\",
            \"ttl\": $new_ttl
        }")

    if [ "$(echo "$response" | jq '.success')" = "true" ]; then
        echo -e "${GREEN}DNS记录更新成功！${NC}"
    else
        echo -e "${RED}更新DNS记录失败：$(echo "$response" | jq -r '.errors[].message')${NC}"
    fi
}

# 主程序修改
main() {
    # 先获取所有域名信息
    echo -e "${CYAN}正在获取所有域名信息...${NC}"
    
    # 使用普通数组存储域名和ID
    local zone_names=()
    local valid_zone_ids=()
    local i=0
    
    # 获取所有域名信息
    for zone_id in "${CF_ZONE_IDS[@]}"; do
        local zone_info=$(get_zone_info "$zone_id")
        if [ "$(echo "$zone_info" | jq '.success')" = "true" ]; then
            local zone_name=$(echo "$zone_info" | jq -r '.result.name')
            zone_names[$i]="$zone_name"
            valid_zone_ids[$i]="$zone_id"
            ((i++))
        else
            echo -e "${RED}获取域名信息失败: $zone_id${NC}"
            exit 1
        fi
    done

    # 显示所有可用域名
    echo -e "\n${CYAN}可用的域名：${NC}"
    for ((i=0; i<${#zone_names[@]}; i++)); do
        echo -e "$((i+1)). ${YELLOW}${zone_names[$i]}${NC}"
    done

    # 如果只有一个域名，直接使用
    if [ ${#zone_names[@]} -eq 1 ]; then
        SELECTED_ZONE_ID="${valid_zone_ids[0]}"
        echo -e "\n${GREEN}使用域名: ${YELLOW}${zone_names[0]}${NC}"
    else
        # 让用户选择
        while true; do
            read -p $'\n请选择域名序号 (1-'${#zone_names[@]}'): ' choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#zone_names[@]} ]; then
                local selected_index=$((choice-1))
                SELECTED_ZONE_ID="${valid_zone_ids[$selected_index]}"
                echo -e "\n${GREEN}当前操作域名: ${YELLOW}${zone_names[$selected_index]}${NC}"
                break
            else
                echo -e "${RED}无效的选择，请重试${NC}"
            fi
        done
    fi

    BASE_URL="https://api.cloudflare.com/client/v4/zones/$SELECTED_ZONE_ID/dns_records"

    while true; do
        echo -e "\n${CYAN}请选择操作：${NC}"
        echo "1. 查看所有DNS记录"
        echo "2. 添加新DNS记录"
        echo "3. 修改已有DNS记录"
        echo "4. 切换域名"
        echo "5. 退出"
        
        read -p $'\n你的选择: ' choice
        
        case $choice in
            1)
                records=$(get_records)
                display_records "$records"
                ;;
            2)
                add_record
                ;;
            3)
                records=$(get_records)
                update_record "$records"
                ;;
            4)
                # 显示所有可用域名
                echo -e "\n${CYAN}可用的域名：${NC}"
                for ((i=0; i<${#zone_names[@]}; i++)); do
                    echo -e "$((i+1)). ${YELLOW}${zone_names[$i]}${NC}"
                done
                
                # 让用户选择
                while true; do
                    read -p $'\n请选择域名序号 (1-'${#zone_names[@]}'): ' choice
                    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#zone_names[@]} ]; then
                        local selected_index=$((choice-1))
                        SELECTED_ZONE_ID="${valid_zone_ids[$selected_index]}"
                        BASE_URL="https://api.cloudflare.com/client/v4/zones/$SELECTED_ZONE_ID/dns_records"
                        echo -e "\n${GREEN}当前操作域名: ${YELLOW}${zone_names[$selected_index]}${NC}"
                        break
                    else
                        echo -e "${RED}无效的选择，请重试${NC}"
                    fi
                done
                ;;
            5)
                echo -e "${YELLOW}再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择，请重试${NC}"
                ;;
        esac
    done
}

# 检查依赖
for cmd in curl jq; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}错误：需要安装 $cmd${NC}"
        exit 1
    fi
done

# 运行主程序
main 