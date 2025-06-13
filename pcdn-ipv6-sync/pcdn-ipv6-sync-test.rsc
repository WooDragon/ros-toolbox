# RouterOS IPv4/IPv6 防火墙地址列表同步脚本 - 测试版本
# 功能：同步 PCDN-P1 和 PCDN-P2 列表中的 IPv4 地址到对应的 IPv6 列表
# 版本：1.1-test
# 适用：RouterOS v7

:local logPrefix "[PCDN-Sync-Test] "
:log info "$logPrefix Test script started"

# 检查 IPv4 地址列表是否存在
:local p1Count [:len [/ip firewall address-list find list="PCDN-P1"]]
:local p2Count [:len [/ip firewall address-list find list="PCDN-P2"]]
:log info "$logPrefix Found $p1Count IPv4 addresses in PCDN-P1"
:log info "$logPrefix Found $p2Count IPv4 addresses in PCDN-P2"

# 检查 IPv6 地址列表是否存在
:local p1v6Count [:len [/ipv6 firewall address-list find list="PCDN-P1"]]
:local p2v6Count [:len [/ipv6 firewall address-list find list="PCDN-P2"]]
:log info "$logPrefix Found $p1v6Count IPv6 addresses in PCDN-P1"
:log info "$logPrefix Found $p2v6Count IPv6 addresses in PCDN-P2"

# 检查 ARP 表
:local arpCount [:len [/ip arp find dynamic=yes !invalid]]
:log info "$logPrefix Found $arpCount dynamic ARP entries"

# 检查 IPv6 Neighbor 表
:local neighborCount [:len [/ipv6 neighbor find]]
:log info "$logPrefix Found $neighborCount IPv6 neighbor entries"

# 测试处理第一个 IPv4 地址（如果存在）
:if ($p1Count > 0) do={
    :local firstIPv4Entry [/ip firewall address-list find list="PCDN-P1"]
    :local firstIPv4Address [/ip firewall address-list get [:pick $firstIPv4Entry 0] address]
    :log info "$logPrefix Testing with first IPv4 address: $firstIPv4Address"
    
    # 查找对应的 MAC 地址
    :local arpEntries [/ip arp find address=$firstIPv4Address dynamic=yes !invalid]
    :if ([:len $arpEntries] > 0) do={
        :local macAddress [/ip arp get [:pick $arpEntries 0] mac-address]
        :log info "$logPrefix Found MAC: $macAddress for IPv4: $firstIPv4Address"
        
        # 查找对应的 IPv6 地址
        :local neighborEntries [/ipv6 neighbor find mac-address=$macAddress]
        :if ([:len $neighborEntries] > 0) do={
            :foreach neighborEntry in=$neighborEntries do={
                :local neighborIPv6Address [/ipv6 neighbor get $neighborEntry address]
                :local isGUA true
                :if ([:pick $neighborIPv6Address 0 4] = "fe80") do={
                    :set isGUA false
                    :log info "$logPrefix Found Link-Local IPv6: $neighborIPv6Address (skipped)"
                } else={
                    :log info "$logPrefix Found GUA IPv6: $neighborIPv6Address"
                }
            }
        } else={
            :log warning "$logPrefix No IPv6 neighbor found for MAC: $macAddress"
        }
    } else={
        :log warning "$logPrefix No ARP entry found for IPv4: $firstIPv4Address"
    }
}

:log info "$logPrefix Test script finished"