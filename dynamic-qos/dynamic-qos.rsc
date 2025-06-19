# RouterOS Dynamic QoS Script for PCDN Traffic Shaping
# Version 1.0
#
# This script dynamically adjusts queue tree limits for PCDN traffic
# based on time of day and randomized patterns to avoid ISP detection.

# ---------------------------
# --- CONFIGURATION START ---
# ---------------------------

# --- General Settings ---
# Log script actions for debugging.
# true = detailed logs, false = basic logs only (essential information)
:local enableLogging false
# Name for log entries
:local scriptName "DynamicQoS"

# Basic logging function (always outputs essential information)
:local logBasic do={
    :log info ("[DynamicQoS] " . $1)
}

# Detailed logging function (only when enableLogging is true)
:local logDetail do={
    :local message $1
    :local enabled $2
    :if ($enabled = true) do={
        :log info ("[DynamicQoS] DEBUG: " . $message)
    }
}

# --- Time Periods ---
# Peak hours (full speed)
:local timePeakStart 18:00:00
:local timePeakEnd 23:59:59
# Midnight hours (heavy suppression) - includes early morning
:local timeMidnightStart 00:00:00
:local timeMidnightEnd 09:30:00
# Work hours (moderate suppression)
:local timeWorkStart 09:30:00
:local timeWorkEnd 18:00:00

# --- PCDN Queue Packet Marks ---
:local pcdnP1Mark "qos-up-pcdn-p1"
:local pcdnP2Mark "qos-up-pcdn-p2"

# --- Rate Ratios (as percentage of parent queue max-limit) ---
# Peak Hours
:local p2PeakRatio 66 ; # P2 queue is 66% of parent's max-limit

# Midnight Hours
:local midnightTotalRatio 25 ; # P1+P2 total limit is 25% of parent's
:local midnightP1MinRatio 10
:local midnightP1MaxRatio 20
:local midnightP2MinRatio 10
:local midnightP2MaxRatio 13

# Work Hours
:local workTotalRatio 50 ; # P1+P2 total limit is 50% of parent's
:local workP1MinRatio 20
:local workP1MaxRatio 30
:local workP2MinRatio 15
:local workP2MaxRatio 20

# --- Randomization & Smoothing ---
# How much the rate can change in one run (percentage of parent max-limit). Prevents drastic jumps.
:local maxChangeRatio 10
# Burst settings relative to the new max-limit
:local burstMultiplier 150  ; # 150% as integer (will divide by 100 later)
:local burstThresholdRatio 75
:local burstTime "30s"

# -------------------------
# --- CONFIGURATION END ---
# -------------------------


# --- SCRIPT LOGIC ---

# Function to convert bandwidth string (e.g., 100M) to bps
:local toBps do={
    :local rate $1
    :if ([:typeof $rate] = "num") do={ :return $rate }
    :local rateStr [:tostr $rate]
    :local num [:tonum [:pick $rateStr 0 ([:len $rateStr] - 1)]]
    :local unit [:pick $rateStr ([:len $rateStr] - 1) [:len $rateStr]]
    :if ($unit = "k" || $unit = "K") do={ :return ($num * 1000) }
    :if ($unit = "m" || $unit = "M") do={ :return ($num * 1000000) }
    :if ($unit = "g" || $unit = "G") do={ :return ($num * 1000000000) }
    :return $num
}

# Function to convert bps to a RouterOS-friendly string (e.g., 100M)
:local fromBps do={
    :local rate $1
    :if ($rate >= 1000000000) do={ :return ([:tostr ($rate / 1000000000)] . "G") }
    :if ($rate >= 1000000) do={
        # Always prefer M unit for values >= 1M
        :local wholePart ($rate / 1000000)
        :local remainder ($rate % 1000000)
        
        # For clean integer M values
        :if ($remainder = 0) do={
            :return ([:tostr $wholePart] . "M")
        }
        
        # For fractional M values, construct the decimal string manually
        # Check for common decimal fractions
        :if ($remainder = 500000) do={
            :return ([:tostr $wholePart] . ".5M")
        }
        :if ($remainder = 250000) do={
            :return ([:tostr $wholePart] . ".25M")
        }
        :if ($remainder = 750000) do={
            :return ([:tostr $wholePart] . ".75M")
        }
        
        # For other fractions, try to represent as decimal
        # Convert remainder to decimal representation
        :local decimalPart ""
        :if ($remainder >= 100000) do={
            :local hundreds ($remainder / 100000)
            :set decimalPart ([:tostr $hundreds])
            :local remaining ($remainder % 100000)
            :if ($remaining >= 10000) do={
                :local tens ($remaining / 10000)
                :set decimalPart ($decimalPart . [:tostr $tens])
                :local remaining2 ($remaining % 10000)
                :if ($remaining2 >= 1000) do={
                    :local ones ($remaining2 / 1000)
                    :set decimalPart ($decimalPart . [:tostr $ones])
                }
            }
            :return ([:tostr $wholePart] . "." . $decimalPart . "M")
        }
        
        # Fallback: use integer M (rounded down) to avoid k units
        :return ([:tostr $wholePart] . "M")
    }
    :if ($rate >= 1000) do={ :return ([:tostr ($rate / 1000)] . "k") }
    :return [:tostr $rate]
}

# Working random function using system clock
:local random do={
    :local min $1
    :local max $2
    :if ($min >= $max) do={ :return $max }
    
    # Get current time and extract seconds
    :local currentTime [/system clock get time]
    :local timeStr [:tostr $currentTime]
    
    # Extract last two characters (seconds)
    :local timeLen [:len $timeStr]
    :local lastChar [:pick $timeStr ($timeLen - 1) $timeLen]
    :local secondLastChar [:pick $timeStr ($timeLen - 2) ($timeLen - 1)]
    
    # Convert to numbers
    :local lastNum 0
    :local secondLastNum 0
    
    :if ($lastChar = "0") do={ :set lastNum 0 }
    :if ($lastChar = "1") do={ :set lastNum 1 }
    :if ($lastChar = "2") do={ :set lastNum 2 }
    :if ($lastChar = "3") do={ :set lastNum 3 }
    :if ($lastChar = "4") do={ :set lastNum 4 }
    :if ($lastChar = "5") do={ :set lastNum 5 }
    :if ($lastChar = "6") do={ :set lastNum 6 }
    :if ($lastChar = "7") do={ :set lastNum 7 }
    :if ($lastChar = "8") do={ :set lastNum 8 }
    :if ($lastChar = "9") do={ :set lastNum 9 }
    
    :if ($secondLastChar = "0") do={ :set secondLastNum 0 }
    :if ($secondLastChar = "1") do={ :set secondLastNum 1 }
    :if ($secondLastChar = "2") do={ :set secondLastNum 2 }
    :if ($secondLastChar = "3") do={ :set secondLastNum 3 }
    :if ($secondLastChar = "4") do={ :set secondLastNum 4 }
    :if ($secondLastChar = "5") do={ :set secondLastNum 5 }
    
    # Create seed from seconds
    :local seed ($secondLastNum * 10 + $lastNum)
    :local range ($max - $min)
    :local randomVal ($seed % $range)
    :return ($min + $randomVal)
}

:local currentTime [/system clock get time]

# Add initial startup log to confirm script is running
$logBasic ("Script started at " . $currentTime)

# Convert time to comparable format (total seconds since midnight)
:local timeToSeconds do={
    :local timeStr [:tostr $1]
    :local parts [:toarray ""]
    :local temp $timeStr
    :while ([:find $temp ":"] >= 0) do={
        :local pos [:find $temp ":"]
        :set parts ($parts, [:pick $temp 0 $pos])
        :set temp [:pick $temp ($pos + 1) [:len $temp]]
    }
    :set parts ($parts, $temp)
    :if ([:len $parts] >= 3) do={
        :local hours [:tonum ($parts->0)]
        :local minutes [:tonum ($parts->1)]
        :local seconds [:tonum ($parts->2)]
        :return (($hours * 3600) + ($minutes * 60) + $seconds)
    }
    :return 0
}

:local currentSeconds ($timeToSeconds $currentTime)
:local peakStartSeconds ($timeToSeconds $timePeakStart)
:local peakEndSeconds ($timeToSeconds $timePeakEnd)
:local midnightStartSeconds ($timeToSeconds $timeMidnightStart)
:local midnightEndSeconds ($timeToSeconds $timeMidnightEnd)
:local workStartSeconds ($timeToSeconds $timeWorkStart)
:local workEndSeconds ($timeToSeconds $timeWorkEnd)

# Determine current period
:local currentPeriod "unknown"

# Debug: Log time conversion results
$logDetail ("Debug: Current seconds: " . $currentSeconds . ", Peak: " . $peakStartSeconds . "-" . $peakEndSeconds . ", Midnight: " . $midnightStartSeconds . "-" . $midnightEndSeconds . ", Work: " . $workStartSeconds . "-" . $workEndSeconds) $enableLogging
$logDetail ("Debug: Time strings - Current: " . $currentTime . ", Peak: " . $timePeakStart . "-" . $timePeakEnd . ", Midnight: " . $timeMidnightStart . "-" . $timeMidnightEnd . ", Work: " . $timeWorkStart . "-" . $timeWorkEnd) $enableLogging

:if ($currentSeconds >= $peakStartSeconds and $currentSeconds <= $peakEndSeconds) do={
    :set currentPeriod "peak"
} else={
    :if ($currentSeconds >= $midnightStartSeconds and $currentSeconds <= $midnightEndSeconds) do={
        :set currentPeriod "midnight"
    } else={
        :if ($currentSeconds >= $workStartSeconds and $currentSeconds <= $workEndSeconds) do={
            :set currentPeriod "work"
        }
    }
}

$logBasic ("Run started: " . $currentTime . " | Period: " . $currentPeriod . " | Found " . [:len [/queue tree find packet-mark~"$pcdnP1Mark"]] . " P1/" . [:len [/queue tree find packet-mark~"$pcdnP2Mark"]] . " P2 queues")

# Test inline random logic
:local currentTime [/system clock get time]
:local timeStr [:tostr $currentTime]
:local timeLen [:len $timeStr]
:local lastChar [:pick $timeStr ($timeLen - 1) $timeLen]
:local testRandom1 (10 + ([:tonum $lastChar] % 10))
:delay 1s
:local currentTime2 [/system clock get time]
:local timeStr2 [:tostr $currentTime2]
:local timeLen2 [:len $timeStr2]
:local lastChar2 [:pick $timeStr2 ($timeLen2 - 1) $timeLen2]
:local testRandom2 (10 + ([:tonum $lastChar2] % 10))
$logDetail ("Random test: " . $testRandom1 . ", " . $testRandom2)

:if ($currentPeriod != "unknown") do={
    # Find all PCDN P1 queues
    :foreach qId in=[/queue tree find packet-mark~"$pcdnP1Mark"] do={
        :local qName [/queue tree get $qId name]
        :local parentName [/queue tree get $qId parent]
        :local parentId [/queue tree find name=$parentName]
        
        :if ([:len $parentId] > 0) do={
            :local parentMaxLimitBps ($toBps [/queue tree get $parentId max-limit])
            
            # Find the corresponding P2 queue
            :local p2qId [/queue tree find parent=$parentName packet-mark~"$pcdnP2Mark"]
            
            :if ([:len $p2qId] > 0) do={
                :local p1qId $qId
                :local p1CurrentLimitBps ($toBps [/queue tree get $p1qId max-limit])
                :local p2CurrentLimitBps ($toBps [/queue tree get $p2qId max-limit])
                
                :local p1NewLimitBps 0
                :local p2NewLimitBps 0

                # --- Calculate new limits based on period ---
                :if ($currentPeriod = "peak") do={
                    :set p1NewLimitBps $parentMaxLimitBps
                    :set p2NewLimitBps (($parentMaxLimitBps * $p2PeakRatio) / 100)
                    $logBasic ($parentName . " [Peak]: P1=" . ($p1NewLimitBps / 1000000) . "M P2=" . ($p2NewLimitBps / 1000000) . "M")
                }

                :if ($currentPeriod = "midnight" || $currentPeriod = "work") do={
                    :local totalRatio $workTotalRatio
                    :local p1Min $workP1MinRatio
                    :local p1Max $workP1MaxRatio
                    :local p2Min $workP2MinRatio
                    :local p2Max $workP2MaxRatio

                    :if ($currentPeriod = "midnight") do={
                        :set totalRatio $midnightTotalRatio
                        :set p1Min $midnightP1MinRatio
                        :set p1Max $midnightP1MaxRatio
                        :set p2Min $midnightP2MinRatio
                        :set p2Max $midnightP2MaxRatio
                    }
                    
                    # NEW LOGIC: "先定总盘，再切蛋糕" approach
                    # Step 1: Calculate total available bandwidth for this period
                    :local totalAvailableBps (($parentMaxLimitBps * $totalRatio) / 100)
                    
                    # Step 2: Calculate P2 minimum guarantee bandwidth
                    :local p2MinGuaranteeBps (($parentMaxLimitBps * $p2Min) / 100)
                    
                    # Step 3: Calculate maximum bandwidth P1 can use (total - P2 minimum)
                    :local p1MaxAvailableBps ($totalAvailableBps - $p2MinGuaranteeBps)
                    
                    # Step 4: Calculate P1 minimum and maximum within available bandwidth
                    :local p1MinBps (($parentMaxLimitBps * $p1Min) / 100)
                    :local p1MaxBps (($parentMaxLimitBps * $p1Max) / 100)
                    
                    $logDetail ("Debug: Initial P1 range: " . ($p1MinBps / 1000000) . "M to " . ($p1MaxBps / 1000000) . "M")
                    $logDetail ("Debug: P1 max available after P2 min: " . ($p1MaxAvailableBps / 1000000) . "M")
                    
                    # Ensure P1 max doesn't exceed what's available after P2 minimum
                    :if ($p1MaxBps > $p1MaxAvailableBps) do={
                        :set p1MaxBps $p1MaxAvailableBps
                        $logDetail ("Debug: P1 max limited to: " . ($p1MaxBps / 1000000) . "M")
                    }
                    
                    # Ensure P1 min doesn't exceed P1 max
                    :if ($p1MinBps > $p1MaxBps) do={
                        :set p1MinBps $p1MaxBps
                        $logDetail ("Debug: P1 min adjusted to: " . ($p1MinBps / 1000000) . "M")
                    }
                    
                    $logDetail ("Debug: Final P1 range: " . ($p1MinBps / 1000000) . "M to " . ($p1MaxBps / 1000000) . "M")
                    
                    # Step 5: Randomly assign P1 bandwidth within its valid range using inline logic
                    $logDetail ("Debug: P1 random range: " . ($p1MinBps / 1000000) . "M to " . ($p1MaxBps / 1000000) . "M")
                    
                    # Convert to M units for clean calculation
                    :local p1MinM ($p1MinBps / 1000000)
                    :local p1MaxM ($p1MaxBps / 1000000)
                    
                    # Inline random calculation for M units
                    :local currentTime [/system clock get time]
                    :local timeStr [:tostr $currentTime]
                    :local timeLen [:len $timeStr]
                    :local lastChar [:pick $timeStr ($timeLen - 1) $timeLen]
                    :local secondLastChar [:pick $timeStr ($timeLen - 2) ($timeLen - 1)]
                    
                    # Convert to numbers and create seed
                    :local lastNum 0
                    :local secondLastNum 0
                    :if ($lastChar = "0") do={ :set lastNum 0 }
                    :if ($lastChar = "1") do={ :set lastNum 1 }
                    :if ($lastChar = "2") do={ :set lastNum 2 }
                    :if ($lastChar = "3") do={ :set lastNum 3 }
                    :if ($lastChar = "4") do={ :set lastNum 4 }
                    :if ($lastChar = "5") do={ :set lastNum 5 }
                    :if ($lastChar = "6") do={ :set lastNum 6 }
                    :if ($lastChar = "7") do={ :set lastNum 7 }
                    :if ($lastChar = "8") do={ :set lastNum 8 }
                    :if ($lastChar = "9") do={ :set lastNum 9 }
                    
                    :if ($secondLastChar = "0") do={ :set secondLastNum 0 }
                    :if ($secondLastChar = "1") do={ :set secondLastNum 1 }
                    :if ($secondLastChar = "2") do={ :set secondLastNum 2 }
                    :if ($secondLastChar = "3") do={ :set secondLastNum 3 }
                    :if ($secondLastChar = "4") do={ :set secondLastNum 4 }
                    :if ($secondLastChar = "5") do={ :set secondLastNum 5 }
                    
                    # Create seed and calculate random M value
                    :local seed ($secondLastNum * 10 + $lastNum)
                    :local rangeM ($p1MaxM - $p1MinM)
                    :local randomValM ($seed % $rangeM)
                    :local p1RandM ($p1MinM + $randomValM)
                    
                    # Convert back to bps with clean M units
                    :local p1RandBps ($p1RandM * 1000000)
                    
                    $logDetail ("Debug: P1 random result: " . $p1RandM . "M (" . $p1RandBps . " bps)")
                    :set p1NewLimitBps $p1RandBps
                    
                    # Step 6: Assign remaining bandwidth to P2
                    :set p2NewLimitBps ($totalAvailableBps - $p1NewLimitBps)
                    
                    # Step 7: Ensure P2 gets at least its minimum guarantee
                    :if ($p2NewLimitBps < $p2MinGuaranteeBps) do={
                        :set p2NewLimitBps $p2MinGuaranteeBps
                        :set p1NewLimitBps ($totalAvailableBps - $p2NewLimitBps)
                    }
                    
                    $logBasic ($parentName . " [Suppress]: Total=" . ($totalAvailableBps / 1000000) . "M P1=" . ($p1NewLimitBps / 1000000) . "M P2=" . ($p2NewLimitBps / 1000000) . "M")
                }

                # --- Smoothing Logic with Total Bandwidth Constraint ---
                :local maxChangeBps (($parentMaxLimitBps * $maxChangeRatio) / 100)
                
                # Store target values before smoothing
                :local p1TargetBps $p1NewLimitBps
                :local p2TargetBps $p2NewLimitBps
                
                $logDetail ("Debug: Smoothing - P1 current=" . ($p1CurrentLimitBps / 1000000) . "M, target=" . ($p1TargetBps / 1000000) . "M, maxChange=" . ($maxChangeBps / 1000000) . "M")
                $logDetail ("Debug: Smoothing - P2 current=" . ($p2CurrentLimitBps / 1000000) . "M, target=" . ($p2TargetBps / 1000000) . "M")
                
                # Apply smoothing to P1
                :if ( ($p1TargetBps - $p1CurrentLimitBps) > $maxChangeBps ) do={
                    :set p1NewLimitBps ($p1CurrentLimitBps + $maxChangeBps)
                    $logDetail ("Debug: P1 increase limited to " . ($p1NewLimitBps / 1000000) . "M")
                }
                :if ( ($p1CurrentLimitBps - $p1TargetBps) > $maxChangeBps ) do={
                    :set p1NewLimitBps ($p1CurrentLimitBps - $maxChangeBps)
                    $logDetail ("Debug: P1 decrease limited to " . ($p1NewLimitBps / 1000000) . "M")
                }
                
                # Apply smoothing to P2
                :if ( ($p2TargetBps - $p2CurrentLimitBps) > $maxChangeBps ) do={
                    :set p2NewLimitBps ($p2CurrentLimitBps + $maxChangeBps)
                    $logDetail ("Debug: P2 increase limited to " . ($p2NewLimitBps / 1000000) . "M")
                }
                :if ( ($p2CurrentLimitBps - $p2TargetBps) > $maxChangeBps ) do={
                    :set p2NewLimitBps ($p2CurrentLimitBps - $maxChangeBps)
                    $logDetail ("Debug: P2 decrease limited to " . ($p2NewLimitBps / 1000000) . "M")
                }
                
                # CRITICAL: Ensure smoothed values don't exceed total bandwidth constraint
                :if ($currentPeriod = "midnight" || $currentPeriod = "work") do={
                     :local totalAfterSmoothing ($p1NewLimitBps + $p2NewLimitBps)
                     
                     # Recalculate total limit based on current period
                     :local currentTotalRatio $workTotalRatio
                     :if ($currentPeriod = "midnight") do={
                         :set currentTotalRatio $midnightTotalRatio
                     }
                     :local totalLimit (($parentMaxLimitBps * $currentTotalRatio) / 100)
                     
                     $logDetail ("Smoothing check for " . $parentName . ": Total after smoothing=" . ($totalAfterSmoothing / 1000000) . "M, Limit=" . ($totalLimit / 1000000) . "M")
                     $logDetail ("Debug: Before scaling - P1=" . ($p1NewLimitBps / 1000000) . "M, P2=" . ($p2NewLimitBps / 1000000) . "M")
                     
                     :if ($totalAfterSmoothing > $totalLimit) do={
                         # Scale down proportionally to fit within total limit
                         :local oldP1 $p1NewLimitBps
                         :local oldP2 $p2NewLimitBps
                         :set p1NewLimitBps (($p1NewLimitBps * $totalLimit) / $totalAfterSmoothing)
                         :set p2NewLimitBps (($p2NewLimitBps * $totalLimit) / $totalAfterSmoothing)
                         $logBasic ("Smoothing exceeded total limit, scaled down: P1=" . ($oldP1 / 1000000) . "M->" . ($p1NewLimitBps / 1000000) . "M, P2=" . ($oldP2 / 1000000) . "M->" . ($p2NewLimitBps / 1000000) . "M")
                     }
                     
                     $logDetail ("Debug: Final values after smoothing - P1=" . ($p1NewLimitBps / 1000000) . "M, P2=" . ($p2NewLimitBps / 1000000) . "M, Total=" . (($p1NewLimitBps + $p2NewLimitBps) / 1000000) . "M")
                 }

                # --- Apply new settings ---
                # Convert to M units for direct calculation to avoid decimal issues
                :local p1NewLimitM ($p1NewLimitBps / 1000000)
                :local p2NewLimitM ($p2NewLimitBps / 1000000)
                :local parentMaxLimitM ($parentMaxLimitBps / 1000000)
                
                # Generate M unit strings directly
                :local p1NewLimitStr ([:tostr $p1NewLimitM] . "M")
                :local p2NewLimitStr ([:tostr $p2NewLimitM] . "M")
                
                # Calculate burst values in M units
                :local p1BurstLimitM (($p1NewLimitM * $burstMultiplier) / 100)
                :local p2BurstLimitM (($p2NewLimitM * $burstMultiplier) / 100)
                
                # Ensure burst-limit doesn't exceed parent queue max-limit
                :if ($p1BurstLimitM > $parentMaxLimitM) do={
                    :set p1BurstLimitM $parentMaxLimitM
                    $logDetail ("Debug: P1 burst-limit capped to parent max-limit: " . $p1BurstLimitM . "M")
                }
                :if ($p2BurstLimitM > $parentMaxLimitM) do={
                    :set p2BurstLimitM $parentMaxLimitM
                    $logDetail ("Debug: P2 burst-limit capped to parent max-limit: " . $p2BurstLimitM . "M")
                }
                
                # Generate burst-limit strings in M units
                :local p1BurstLimitStr ([:tostr $p1BurstLimitM] . "M")
                :local p2BurstLimitStr ([:tostr $p2BurstLimitM] . "M")
                
                # Calculate burst-threshold in M units
                :local p1BurstThresholdM (($p1NewLimitM * $burstThresholdRatio) / 100)
                :local p2BurstThresholdM (($p2NewLimitM * $burstThresholdRatio) / 100)
                :local p1BurstThresholdStr ([:tostr $p1BurstThresholdM] . "M")
                :local p2BurstThresholdStr ([:tostr $p2BurstThresholdM] . "M")

                # Apply settings with error handling
                # Debug: Check P1 queue properties before modification
                :local p1QueueName [/queue tree get $p1qId name]
                :local p1CurrentMaxLimit [/queue tree get $p1qId max-limit]
                :local p1CurrentLimitAt [/queue tree get $p1qId limit-at]
                :local p1Disabled [/queue tree get $p1qId disabled]
                :local p1Parent [/queue tree get $p1qId parent]
                :local parentCurrentMaxLimit [/queue tree get $parentId max-limit]
                $logDetail ("Debug: P1 Queue '" . $p1QueueName . "' - Current max-limit: " . $p1CurrentMaxLimit . ", limit-at: " . $p1CurrentLimitAt . ", Disabled: " . $p1Disabled)
                $logDetail ("Debug: Parent Queue '" . $p1Parent . "' - Current max-limit: " . $parentCurrentMaxLimit)
                
                # Check if there are other child queues that might cause constraints
                :local allChildQueues [/queue tree find parent=$parentName]
                :local totalChildMaxLimit 0
                :foreach childId in=$allChildQueues do={
                    :local childMaxLimit ($toBps [/queue tree get $childId max-limit])
                    :set totalChildMaxLimit ($totalChildMaxLimit + $childMaxLimit)
                }
                $logDetail ("Debug: Total current child queues max-limit: " . ($totalChildMaxLimit / 1000000) . "M vs Parent: " . ($parentMaxLimitBps / 1000000) . "M")
                
                # Calculate appropriate limit-at value based on period
                :local p1LimitAtBps 0
                :if ($currentPeriod = "peak") do={
                    # In peak period, set limit-at equal to max-limit for guaranteed bandwidth
                    :set p1LimitAtBps $p1NewLimitBps
                } else={
                    # In suppression periods, set limit-at to 0 to allow flexible max-limit adjustment
                    :set p1LimitAtBps 0
                }
                :local p1LimitAtStr ([:tostr ($p1LimitAtBps / 1000000)] . "M")
                
                $logDetail ("Debug: About to apply P1 settings - limit-at=" . $p1LimitAtStr . ", max-limit=" . $p1NewLimitStr . ", burst-limit=" . $p1BurstLimitStr . ", burst-threshold=" . $p1BurstThresholdStr . ", burst-time=" . $burstTime)
                :do {
                     # Step 1: Clear burst parameters first to remove constraints
                     $logDetail ("Debug: Clearing burst parameters first") $enableLogging
                     /queue tree set $p1qId burst-limit=0 burst-threshold=0 burst-time=0s
                     
                     # Step 2: Set limit-at to 0 to allow max-limit changes
                     $logDetail ("Debug: Setting limit-at to 0") $enableLogging
                     /queue tree set $p1qId limit-at=0
                     
                     # Step 3: Set the new max-limit
                     $logDetail ("Debug: Setting max-limit to " . $p1NewLimitStr)
                     /queue tree set $p1qId max-limit=$p1NewLimitStr
                     
                     # Step 4: Set the correct limit-at value
                     $logDetail ("Debug: Setting limit-at to " . $p1LimitAtStr)
                     /queue tree set $p1qId limit-at=$p1LimitAtStr
                     
                     # Step 5: Configure burst parameters separately
                     $logDetail ("Debug: Configuring burst parameters") $enableLogging
                     /queue tree set $p1qId burst-limit=$p1BurstLimitStr burst-threshold=$p1BurstThresholdStr burst-time=$burstTime
                     
                     $logDetail ("P1 queue updated successfully") $enableLogging
                 } on-error={
                     $logBasic ("Error applying P1 settings to " . $parentName . " - P1 ID: " . $p1qId . ". Trying without burst parameters...")
                     :do {
                         # Fallback: Only set essential parameters without burst
                         /queue tree set $p1qId burst-limit=0 burst-threshold=0 burst-time=0s
                         /queue tree set $p1qId limit-at=0
                         /queue tree set $p1qId max-limit=$p1NewLimitStr
                         /queue tree set $p1qId limit-at=$p1LimitAtStr
                         $logBasic ("P1 settings applied successfully (without burst parameters)")
                     } on-error={
                         $logBasic ("Failed to set P1 queue " . $p1qId . " ('" . $p1QueueName . "') - all attempts failed")
                     }
                 }
                
                $logDetail ("Debug: About to apply P2 settings - max-limit=" . $p2NewLimitStr . ", burst-limit=" . $p2BurstLimitStr . ", burst-threshold=" . $p2BurstThresholdStr . ", burst-time=" . $burstTime)
                :do {
                    # Step 1: Clear burst parameters first to remove constraints
                    $logDetail ("Debug: P2 - Clearing burst parameters first") $enableLogging
                    /queue tree set $p2qId burst-limit=0 burst-threshold=0 burst-time=0s
                    
                    # Step 2: Set the new max-limit
                    $logDetail ("Debug: P2 - Setting max-limit to " . $p2NewLimitStr) $enableLogging
                    /queue tree set $p2qId max-limit=$p2NewLimitStr
                    
                    # Step 3: Configure burst parameters separately
                    $logDetail ("Debug: P2 - Configuring burst parameters") $enableLogging
                    /queue tree set $p2qId burst-limit=$p2BurstLimitStr burst-threshold=$p2BurstThresholdStr burst-time=$burstTime
                    
                    $logDetail ("P2 queue updated successfully") $enableLogging
                } on-error={
                    $logBasic ("Error applying P2 settings to " . $parentName . " - P2 ID: " . $p2qId)
                }
                
                # Remove this basic log as it's redundant with the above calculation log

            } else={
                $logBasic ("Warning: P1 queue '" . $qName . "' found, but corresponding P2 queue not found for parent '" . $parentName . "'.")
            }
        } else={
            $logBasic ("Warning: Could not find parent queue '" . $parentName . "' for queue '" . $qName . "'.")
        }
    }
} else {
    $logBasic ("No active period. No changes made.")
}

# Remove this basic log to keep it minimal

# --- SCHEDULER SETUP ---
#
# To run this script every 5 minutes, create a scheduler entry:
# /system scheduler
# add name="Run DynamicQoS" interval=5m on-event="/import dynamic-qos.rsc" start-date=jan/01/1970 start-time=00:00:00
#