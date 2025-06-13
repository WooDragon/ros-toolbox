# RouterOS IPv4/IPv6 防火墙地址列表同步脚本 - 安全版本
# 功能：同步 PCDN-P1 和 PCDN-P2 列表中的 IPv4 地址到对应的 IPv6 列表
# 同步逻辑：IPv4 -> ARP (MAC) -> IPv6 Neighbor (GUA) -> IPv6 防火墙列表
# 版本：1.2-safe
# 适用：RouterOS v7

# 脚本初始化与配置
:local targetListNames {"PCDN-P1";"PCDN-P2"}
:local logPrefix "[PCDN-Sync-Safe] "

# 记录脚本启动
:log info "$logPrefix Script started"

# 全局活动 IPv6 集合
:local activeGlobalIPv6sThisRun ""

# 核心同步逻辑 (对每个目标列表进行迭代) - 只添加，不删除
:foreach currentListName in=$targetListNames do={
    :log info "$logPrefix Processing list: $currentListName (for both IPv4 and IPv6 sync)"
    
    # 遍历 IPv4 地址
    :foreach ipv4Entry in=[/ip firewall address-list find list=$currentListName] do={
        :local ipv4Address [/ip firewall address-list get $ipv4Entry address]
        :log debug "$logPrefix Processing IPv4 address: $ipv4Address"
        
        # 查找 MAC 地址
        :local macAddress ""
        :local arpEntries [/ip arp find address=$ipv4Address dynamic=yes !invalid]
        
        :if ([:len $arpEntries] > 0) do={
            # 取第一个有效的 ARP 条目
            :set macAddress [/ip arp get [:pick $arpEntries 0] mac-address]
            :log debug "$logPrefix Found MAC $macAddress for IPv4 $ipv4Address"
        } else={
            :log warning "$logPrefix MAC not found for IPv4 $ipv4Address in list $currentListName"
        }
        
        # 查找并处理 IPv6 地址 (GUA)
        :if ($macAddress != "") do={
            :local foundGUA false
            :local neighborEntries [/ipv6 neighbor find mac-address=$macAddress]
            
            :foreach neighborEntry in=$neighborEntries do={
                :local neighborIPv6Address [/ipv6 neighbor get $neighborEntry address]
                
                # 筛选 GUA (排除 Link-Local fe80::/10)
                :local isGUA true
                :if ([:pick $neighborIPv6Address 0 4] = "fe80") do={
                    :set isGUA false
                }
                
                :if ($isGUA) do={
                    :set foundGUA true
                    :log debug "$logPrefix Found GUA IPv6 $neighborIPv6Address for MAC $macAddress"
                    
                    # 添加到全局活动集合 (确保唯一性)
                    :local existsInActiveSet false
                    :if ($activeGlobalIPv6sThisRun != "") do={
                        :if ([:find $activeGlobalIPv6sThisRun $neighborIPv6Address] >= 0) do={
                            :set existsInActiveSet true
                        }
                    }
                    :if (!$existsInActiveSet) do={
                        :if ($activeGlobalIPv6sThisRun = "") do={
                            :set activeGlobalIPv6sThisRun $neighborIPv6Address
                        } else={
                            :set activeGlobalIPv6sThisRun "$activeGlobalIPv6sThisRun,$neighborIPv6Address"
                        }
                    }
                    
                    # 检查 IPv6 地址是否已存在（多种格式检查）
                    :local addressExists false
                    
                    # 检查不带前缀的地址
                    :local existing1 [/ipv6 firewall address-list find list=$currentListName address=$neighborIPv6Address]
                    :if ([:len $existing1] > 0) do={ :set addressExists true }
                    
                    # 检查带 /128 前缀的地址
                    :if (!$addressExists) do={
                        :local existing2 [/ipv6 firewall address-list find list=$currentListName address="$neighborIPv6Address/128"]
                        :if ([:len $existing2] > 0) do={ :set addressExists true }
                    }
                    
                    # 检查是否地址本身已包含前缀
                    :if (!$addressExists && [:find $neighborIPv6Address "/"] >= 0) do={
                        :local addrWithoutPrefix [:pick $neighborIPv6Address 0 [:find $neighborIPv6Address "/"]]
                        :local existing3 [/ipv6 firewall address-list find list=$currentListName address=$addrWithoutPrefix]
                        :if ([:len $existing3] > 0) do={ :set addressExists true }
                    }
                    
                    # 添加到 IPv6 防火墙列表 (如果不存在)
                    :if (!$addressExists) do={
                        :do {
                            /ipv6 firewall address-list add list=$currentListName address=$neighborIPv6Address comment="Synced from $ipv4Address ($macAddress)"
                            :log info "$logPrefix Added $neighborIPv6Address to $currentListName (from $ipv4Address, MAC $macAddress)"
                        } on-error={
                            :log warning "$logPrefix Failed to add $neighborIPv6Address to $currentListName - may already exist in different format"
                        }
                    } else={
                        :log debug "$logPrefix IPv6 address $neighborIPv6Address already exists in $currentListName"
                    }
                }
            }
            
            :if (!$foundGUA) do={
                :log warning "$logPrefix No GUA IPv6 neighbor found for MAC $macAddress (from IPv4 $ipv4Address in list $currentListName)"
            }
        }
    }
}

# 脚本结束 - 不执行清理操作以避免意外删除
:local totalActiveCount 0
:if ($activeGlobalIPv6sThisRun != "") do={
    :set totalActiveCount [:len [:toarray $activeGlobalIPv6sThisRun]]
}
:log info "$logPrefix Script finished. Total active GUA IPv6 addresses found: $totalActiveCount"
:log info "$logPrefix Note: This safe version only adds IPv6 addresses, does not remove existing ones"