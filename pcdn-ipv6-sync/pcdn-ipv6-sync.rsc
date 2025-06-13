# RouterOS IPv4/IPv6 防火墙地址列表同步脚本
# 功能：同步 PCDN-P1 和 PCDN-P2 列表中的 IPv4 地址到对应的 IPv6 列表
# 同步逻辑：IPv4 -> ARP (MAC) -> IPv6 Neighbor (GUA) -> IPv6 防火墙列表
# 版本：1.2 - 修复清理逻辑，利用comment字段判断记录有效性
# 适用：RouterOS v7

# 脚本初始化与配置
:local targetListNames {"PCDN-P1";"PCDN-P2"}
:local logPrefix "[PCDN-Sync] "

# 记录脚本启动
:log info "$logPrefix Script started"


# 核心同步逻辑 (对每个目标列表进行迭代)
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
                    
                    # 添加到 IPv6 防火墙列表 (如果不存在)
                    # 检查多种可能的地址格式
                    :local existingIPv6Entry1 [/ipv6 firewall address-list find list=$currentListName address=$neighborIPv6Address]
                    :local existingIPv6Entry2 [/ipv6 firewall address-list find list=$currentListName address="$neighborIPv6Address/128"]
                    :local addressExists ([:len $existingIPv6Entry1] > 0 or [:len $existingIPv6Entry2] > 0)
                    
                    :if (!$addressExists) do={
                        :do {
                            /ipv6 firewall address-list add list=$currentListName address=$neighborIPv6Address comment="AUTO-SYNC:$ipv4Address:$macAddress"
                            :log info "$logPrefix Added $neighborIPv6Address to $currentListName (from $ipv4Address, MAC $macAddress)"
                        } on-error={
                            :log warning "$logPrefix Failed to add $neighborIPv6Address to $currentListName - entry may already exist with different format"
                        }
                    } else={
                        # 更新现有条目的comment以确保信息是最新的
                        :if ([:len $existingIPv6Entry1] > 0) do={
                            /ipv6 firewall address-list set [:pick $existingIPv6Entry1 0] comment="AUTO-SYNC:$ipv4Address:$macAddress"
                        } else={
                            /ipv6 firewall address-list set [:pick $existingIPv6Entry2 0] comment="AUTO-SYNC:$ipv4Address:$macAddress"
                        }
                        :log debug "$logPrefix Updated comment for existing IPv6 address $neighborIPv6Address in $currentListName"
                    }
                }
            }
            
            :if (!$foundGUA) do={
                :log warning "$logPrefix No GUA IPv6 neighbor found for MAC $macAddress (from IPv4 $ipv4Address in list $currentListName)"
            }
        }
    }
}

# 清理 IPv6 地址列表 - 基于comment字段的智能清理
:log info "$logPrefix Starting cleanup phase"

# 构建当前IPv4地址集合，用于验证comment中的IPv4地址是否仍然有效
:local currentIPv4Set ""
:foreach currentListName in=$targetListNames do={
    :foreach ipv4Entry in=[/ip firewall address-list find list=$currentListName] do={
        :local ipv4Address [/ip firewall address-list get $ipv4Entry address]
        :if ($currentIPv4Set = "") do={
            :set currentIPv4Set "$currentListName:$ipv4Address"
        } else={
            :set currentIPv4Set "$currentIPv4Set,$currentListName:$ipv4Address"
        }
    }
}

# 清理所有目标列表的IPv6条目
:foreach currentListName in=$targetListNames do={
    :local removedCount 0
    :local keptCount 0
    
    # 遍历当前列表中的所有IPv6条目
    :foreach ipv6Entry in=[/ipv6 firewall address-list find list=$currentListName] do={
        :local ipv6Address [/ipv6 firewall address-list get $ipv6Entry address]
        :local comment [/ipv6 firewall address-list get $ipv6Entry comment]
        :local shouldKeep false
        
        # 检查comment格式是否为自动同步格式
        :if ([:find $comment "AUTO-SYNC:"] = 0) do={
            # 解析comment中的IPv4地址 (格式: AUTO-SYNC:IPv4:MAC)
            :local commentParts [:toarray $comment]
            :if ([:len $commentParts] >= 1) do={
                :local commentContent [:pick $comment 10 [:len $comment]]
                :local colonPos [:find $commentContent ":"]
                :if ($colonPos >= 0) do={
                    :local ipv4FromComment [:pick $commentContent 0 $colonPos]
                    
                    # 检查这个IPv4地址是否仍在当前列表中
                    :local searchPattern "$currentListName:$ipv4FromComment"
                    :if ([:find $currentIPv4Set $searchPattern] >= 0) do={
                        :set shouldKeep true
                        :log debug "$logPrefix Keeping IPv6 $ipv6Address (IPv4 $ipv4FromComment still in $currentListName)"
                    } else={
                        :log debug "$logPrefix IPv6 $ipv6Address should be removed (IPv4 $ipv4FromComment no longer in $currentListName)"
                    }
                } else={
                    # comment格式异常，保守处理 - 保留
                    :set shouldKeep true
                    :log warning "$logPrefix Keeping IPv6 $ipv6Address due to malformed comment: $comment"
                }
            } else={
                # comment格式异常，保守处理 - 保留
                :set shouldKeep true
                :log warning "$logPrefix Keeping IPv6 $ipv6Address due to malformed comment: $comment"
            }
        } else={
            # 非自动同步的条目（手动添加或其他脚本添加），保留
            :set shouldKeep true
            :log debug "$logPrefix Keeping IPv6 $ipv6Address (not auto-synced, comment: $comment)"
        }
        
        # 执行删除或保留
        :if ($shouldKeep) do={
            :set keptCount ($keptCount + 1)
        } else={
            /ipv6 firewall address-list remove $ipv6Entry
            :set removedCount ($removedCount + 1)
            :log info "$logPrefix Removed stale address $ipv6Address from $currentListName"
        }
    }
    
    :log info "$logPrefix Cleanup completed for $currentListName: removed $removedCount stale addresses, kept $keptCount valid addresses"
}

# 脚本结束 - 统计当前IPv6地址总数
:local totalIPv6Count 0
:foreach currentListName in=$targetListNames do={
    :local listCount [:len [/ipv6 firewall address-list find list=$currentListName]]
    :set totalIPv6Count ($totalIPv6Count + $listCount)
}
:log info "$logPrefix Script finished. Total IPv6 addresses in target lists: $totalIPv6Count"