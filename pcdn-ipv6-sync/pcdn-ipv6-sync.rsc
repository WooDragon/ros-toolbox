# RouterOS IPv4/IPv6 防火墙地址列表同步脚本
# 功能：同步 PCDN-P1 和 PCDN-P2 列表中的 IPv4 地址到对应的 IPv6 列表
# 同步逻辑：IPv4 -> ARP (MAC) -> IPv6 Neighbor (GUA) -> IPv6 防火墙列表
# 版本：1.1
# 适用：RouterOS v7

# 脚本初始化与配置
:local targetListNames {"PCDN-P1";"PCDN-P2"}
:local logPrefix "[PCDN-Sync] "

# 记录脚本启动
:log info "$logPrefix Script started"

# 预存当前 IPv6 列表状态 (为清理做准备)
:local initialIPv6MembersP1 ""
:local initialIPv6MembersP2 ""

# 预存 PCDN-P1 的 IPv6 地址
:foreach ipv6Entry in=[/ipv6 firewall address-list find list="PCDN-P1"] do={
    :local ipv6Addr [/ipv6 firewall address-list get $ipv6Entry address]
    :if ($initialIPv6MembersP1 = "") do={
        :set initialIPv6MembersP1 $ipv6Addr
    } else={
        :set initialIPv6MembersP1 "$initialIPv6MembersP1,$ipv6Addr"
    }
}

# 预存 PCDN-P2 的 IPv6 地址
:foreach ipv6Entry in=[/ipv6 firewall address-list find list="PCDN-P2"] do={
    :local ipv6Addr [/ipv6 firewall address-list get $ipv6Entry address]
    :if ($initialIPv6MembersP2 = "") do={
        :set initialIPv6MembersP2 $ipv6Addr
    } else={
        :set initialIPv6MembersP2 "$initialIPv6MembersP2,$ipv6Addr"
    }
}

:log info "$logPrefix Pre-stored IPv6 addresses from PCDN-P1: $initialIPv6MembersP1"
:log info "$logPrefix Pre-stored IPv6 addresses from PCDN-P2: $initialIPv6MembersP2"

# 全局活动 IPv6 集合
:local activeGlobalIPv6sThisRun ""

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
                    
                    # 添加到 IPv6 防火墙列表 (如果不存在)
                    # 检查多种可能的地址格式
                    :local existingIPv6Entry1 [/ipv6 firewall address-list find list=$currentListName address=$neighborIPv6Address]
                    :local existingIPv6Entry2 [/ipv6 firewall address-list find list=$currentListName address="$neighborIPv6Address/128"]
                    :local addressExists ([:len $existingIPv6Entry1] > 0 or [:len $existingIPv6Entry2] > 0)
                    
                    :if (!$addressExists) do={
                        :do {
                            /ipv6 firewall address-list add list=$currentListName address=$neighborIPv6Address comment="Synced from $ipv4Address ($macAddress)"
                            :log info "$logPrefix Added $neighborIPv6Address to $currentListName (from $ipv4Address, MAC $macAddress)"
                        } on-error={
                            :log warning "$logPrefix Failed to add $neighborIPv6Address to $currentListName - entry may already exist with different format"
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

# 清理 IPv6 地址列表
:log info "$logPrefix Starting cleanup phase"

# 清理 PCDN-P1
:if ($initialIPv6MembersP1 != "") do={
    :local removedCount 0
    :foreach oldIPv6Address in=[:toarray $initialIPv6MembersP1] do={
        # 检查保留状态
        :local shouldBeKept false
        :if ($activeGlobalIPv6sThisRun != "") do={
            :if ([:find $activeGlobalIPv6sThisRun $oldIPv6Address] >= 0) do={
                :set shouldBeKept true
            }
        }
        
        # 执行移除
        :if (!$shouldBeKept) do={
            :local entryToRemove [/ipv6 firewall address-list find list="PCDN-P1" address=$oldIPv6Address]
            :if ([:len $entryToRemove] > 0) do={
                /ipv6 firewall address-list remove $entryToRemove
                :set removedCount ($removedCount + 1)
                :log info "$logPrefix Removed stale address $oldIPv6Address from PCDN-P1"
            }
        }
    }
    :log info "$logPrefix Cleanup completed for PCDN-P1: removed $removedCount stale addresses"
}

# 清理 PCDN-P2
:if ($initialIPv6MembersP2 != "") do={
    :local removedCount 0
    :foreach oldIPv6Address in=[:toarray $initialIPv6MembersP2] do={
        # 检查保留状态
        :local shouldBeKept false
        :if ($activeGlobalIPv6sThisRun != "") do={
            :if ([:find $activeGlobalIPv6sThisRun $oldIPv6Address] >= 0) do={
                :set shouldBeKept true
            }
        }
        
        # 执行移除
        :if (!$shouldBeKept) do={
            :local entryToRemove [/ipv6 firewall address-list find list="PCDN-P2" address=$oldIPv6Address]
            :if ([:len $entryToRemove] > 0) do={
                /ipv6 firewall address-list remove $entryToRemove
                :set removedCount ($removedCount + 1)
                :log info "$logPrefix Removed stale address $oldIPv6Address from PCDN-P2"
            }
        }
    }
    :log info "$logPrefix Cleanup completed for PCDN-P2: removed $removedCount stale addresses"
}

# 脚本结束
:local totalActiveCount 0
:if ($activeGlobalIPv6sThisRun != "") do={
    :set totalActiveCount [:len [:toarray $activeGlobalIPv6sThisRun]]
}
:log info "$logPrefix Script finished. Total active GUA IPv6 addresses: $totalActiveCount"