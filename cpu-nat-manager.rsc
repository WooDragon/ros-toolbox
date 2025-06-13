# Script Name: cpu-nat-manager
# Description: Manages endpoint-independent-nat rules and cleans UDP connections
# when CPU load exceeds threshold based on average value over 1 minute.

# --- Configuration ---
:local cpuHighThreshold 75
:local cpuSafeThreshold 65
:local samplesNeeded 6
:local maxRetries 3
:local minCooldownMinutes 1
:local maxCooldownMinutes 20

# Global variables
:global cpuSampleValues
:global cpuSampleCount
:global natRulesDisabled
:global inCooldownMode
:global cooldownStartSecs
:global lastStatusLogTime

# Initialize globals if needed
:if ([:typeof $cpuSampleValues] != "array") do={
    :set cpuSampleValues ({})
    :log info "Script initialized: CPU sample values array created"
}

:if ([:typeof $cpuSampleCount] != "num") do={
    :set cpuSampleCount 0
    :log info "Script initialized: CPU sample count set to 0"
}

:if ([:typeof $natRulesDisabled] != "bool") do={
    :set natRulesDisabled false
    :log info "Script initialized: NAT status flag set to false"
}

:if ([:typeof $inCooldownMode] != "bool") do={
    :set inCooldownMode false
    :log info "Script initialized: cooldown mode set to false"
}

:if ([:typeof $cooldownStartSecs] != "num") do={
    :set cooldownStartSecs 0
    :log info "Script initialized: cooldown timer set to 0"
}

:if ([:typeof $lastStatusLogTime] != "num") do={
    :set lastStatusLogTime 0
    :log info "Script initialized: status log timer set to 0"
}

# Get current uptime and convert to seconds
:local uptimeStr [/system resource get uptime]
:local currentSecs 0

# Parse uptime string - handle both formats: "HH:MM:SS" and "WdHH:MM:SS"
:if ([:find $uptimeStr "d"] > 0) do={
    # Format with days: "5d04:42:36"
    :local days [:tonum [:pick $uptimeStr 0 [:find $uptimeStr "d"]]]
    :local timepart [:pick $uptimeStr ([:find $uptimeStr "d"]+1) [:len $uptimeStr]]
    :local hours [:tonum [:pick $timepart 0 [:find $timepart ":"]]]
    :local mins [:tonum [:pick $timepart ([:find $timepart ":"]+1) [:find $timepart ":" ([:find $timepart ":"]+1)]]]
    :local secs [:tonum [:pick $timepart ([:find $timepart ":" ([:find $timepart ":"]+1)]+1) [:len $timepart]]]
    :set currentSecs (($days * 86400) + ($hours * 3600) + ($mins * 60) + $secs)
} else={
    # Format without days: "00:07:56"
    :local hours [:tonum [:pick $uptimeStr 0 [:find $uptimeStr ":"]]]
    :local mins [:tonum [:pick $uptimeStr ([:find $uptimeStr ":"]+1) [:find $uptimeStr ":" ([:find $uptimeStr ":"]+1)]]]
    :local secs [:tonum [:pick $uptimeStr ([:find $uptimeStr ":" ([:find $uptimeStr ":"]+1)]+1) [:len $uptimeStr]]]
    :set currentSecs (($hours * 3600) + ($mins * 60) + $secs)
}

# Get current CPU load
:local currentCpuLoad [/system resource get cpu-load]

# Manage CPU samples - fixed window of last minute (6 samples)
# If we already have 6 samples, remove the oldest one
:if ($cpuSampleCount >= $samplesNeeded) do={
    # Remove oldest sample (shift array)
    :local newArray ({})
    :for i from=1 to=($cpuSampleCount-1) do={
        :set newArray ($newArray, ($cpuSampleValues->$i))
    }
    :set cpuSampleValues $newArray
    :set cpuSampleCount ($cpuSampleCount - 1)
}

# Add new sample at the end
:set cpuSampleValues ($cpuSampleValues, $currentCpuLoad)
:set cpuSampleCount ($cpuSampleCount + 1)

# Calculate average CPU load of all samples
:local totalLoad 0
:for i from=0 to=($cpuSampleCount-1) do={
    :set totalLoad ($totalLoad + ($cpuSampleValues->$i))
}
:local avgCpuLoad ($totalLoad / $cpuSampleCount)

# Determine if we have enough samples for accurate average
:local haveEnoughSamples ($cpuSampleCount >= $samplesNeeded)

# First check for rule state consistency
:local einatExists false
:local einatCount [/ip firewall nat print count-only where action=endpoint-independent-nat]
:if ($einatCount > 0) do={
    :set einatExists true
}

# Check if NAT rules are actually disabled
:local actualNatDisabled false
:if ($einatExists) do={
    :local enabledRules [/ip firewall nat print count-only where action=endpoint-independent-nat disabled=no]
    :if ($enabledRules = 0) do={
        :set actualNatDisabled true
    }
}

# Sync our global state if it doesn't match actual state
:if ($natRulesDisabled != $actualNatDisabled) do={
    :log warning "State sync needed: Our record ($natRulesDisabled) doesn't match actual NAT rule state ($actualNatDisabled)"
    :set natRulesDisabled $actualNatDisabled
}

# Conditional logging: only log status when in cooldown or when taking action
:local shouldLogStatus false
:if ($inCooldownMode) do={
    # In cooldown mode, log status once per minute
    :if (($currentSecs - $lastStatusLogTime) >= 60) do={
        :set shouldLogStatus true
        :set lastStatusLogTime $currentSecs
    }
} 

:if ($shouldLogStatus) do={
    :log warning "STATUS: Avg CPU: $avgCpuLoad%, Samples: $cpuSampleCount/$samplesNeeded, In cooldown: $inCooldownMode, NAT disabled: $natRulesDisabled"
}

# Main logic flow
:if ($inCooldownMode) do={
    # We're in cooldown mode - check if average CPU is now safe
    :local elapsedSeconds ($currentSecs - $cooldownStartSecs)
    :local elapsedMinutes [:tonum ($elapsedSeconds / 60)]
    
    :if ($shouldLogStatus) do={
        :log warning "In cooldown mode for $elapsedMinutes minutes. Target: Avg CPU below $cpuSafeThreshold%"
    }
    
    # Check if MIN cooldown time has elapsed and CPU is safe, OR if we've waited too long
    :if (($elapsedMinutes >= $minCooldownMinutes && $avgCpuLoad < $cpuSafeThreshold) || $elapsedMinutes > $maxCooldownMinutes) do={
        :if ($elapsedMinutes > $maxCooldownMinutes) do={
            :log warning "Cooldown timeout reached after $maxCooldownMinutes minutes. Forcing re-enable."
        } else={
            :log warning "Minimum cooldown period ($minCooldownMinutes min) satisfied and CPU average ($avgCpuLoad%) below safe threshold ($cpuSafeThreshold%). Re-enabling NAT rules"
        }
        
        :do {
            /ip firewall nat set disabled=no [find action=endpoint-independent-nat]
            :set natRulesDisabled false
            :set inCooldownMode false
            :log warning "NAT rules re-enabled successfully"
        } on-error={
            :log error "Failed to re-enable NAT rules. Manual intervention required!"
        }
    }
} else={
    # Not in cooldown mode - check if average CPU is high and we have enough samples
    :if ($avgCpuLoad > $cpuHighThreshold && $haveEnoughSamples) do={
        # Log status when taking action (regardless of timer)
        :log warning "STATUS: Avg CPU: $avgCpuLoad%, Samples: $cpuSampleCount/$samplesNeeded, In cooldown: $inCooldownMode, NAT disabled: $natRulesDisabled"
        :log warning "High CPU average detected: $avgCpuLoad% > $cpuHighThreshold% over past minute. Taking action..."
        :set lastStatusLogTime $currentSecs
        
        # Step 1: Disable endpoint-independent-nat rules
        :if ($einatExists && !$natRulesDisabled) do={
            :do {
                :log warning "Disabling endpoint-independent-nat rules"
                /ip firewall nat set disabled=yes [find action=endpoint-independent-nat]
                :set natRulesDisabled true
                :log warning "NAT rules disabled successfully"
            } on-error={
                :log error "Failed to disable NAT rules"
            }
        }
        
        # Step 2: Clear UDP connections
        :do {
            :log warning "Removing UDP connections"
            /ip firewall connection print where protocol=udp [remove $".id"]
            :log warning "UDP connections cleared successfully"
            
            # Step 3: Enter cooldown mode IMMEDIATELY after clearing connections
            :set inCooldownMode true
            :set cooldownStartSecs $currentSecs
            :log warning "Entering cooldown mode with minimum duration of $minCooldownMinutes minutes"
        } on-error={
            :log error "Failed to clear UDP connections"
            # Still enter cooldown mode even if clearing connections fails
            :set inCooldownMode true
            :set cooldownStartSecs $currentSecs
            :log warning "Entering cooldown mode despite connection clearing error"
        }
    } else={
        # Check for inconsistent state - only if we're not in cooldown mode but rules are disabled
        :if ($natRulesDisabled && !$inCooldownMode) do={
            # Log status when detecting inconsistency (regardless of timer)
            :log warning "STATUS: Avg CPU: $avgCpuLoad%, Samples: $cpuSampleCount/$samplesNeeded, In cooldown: $inCooldownMode, NAT disabled: $natRulesDisabled"
            :log warning "Inconsistent state detected: NAT rules disabled but not in cooldown. Entering cooldown mode..."
            :set lastStatusLogTime $currentSecs
            
            # Instead of immediately fixing, enter cooldown mode
            :set inCooldownMode true
            :set cooldownStartSecs $currentSecs
            :log warning "Cooldown mode activated. Will wait at least $minCooldownMinutes minutes before checking CPU."
        }
    }
}