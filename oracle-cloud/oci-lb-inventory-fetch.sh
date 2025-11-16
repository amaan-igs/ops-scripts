#!/bin/bash

set -euo pipefail

###############################################################################
# OCI Load Balancer Inventory Export Script
# Author: Amaan Ul Haq Siddiqui - DevOps Engineer
# Description: Exports comprehensive inventory of OCI load balancers
#              including compartment names, IP addresses, listeners,
#              backend sets, backend server names, and health status.
###############################################################################

# Configuration: Target region and output settings
REGION="me-jeddah-1"
DATE=$(date +%Y%m%d)
OUTPUT_DIR="oci_lb_inventory_${REGION}_${DATE}"
LOG_FILE="${OUTPUT_DIR}/lb_inventory.log"
JSON_OUTPUT="${OUTPUT_DIR}/lb_details.json"
CSV_OUTPUT="${OUTPUT_DIR}/lb_inventory.csv"
TEMP_DIR="${OUTPUT_DIR}/temp"

# Initialize output directory structure
mkdir -p "$OUTPUT_DIR" "$TEMP_DIR"

echo "-----------------------------------------------------------"
echo "OCI Load Balancer Inventory Export"
echo "Region: $REGION | Date: $DATE"
echo "-----------------------------------------------------------"

echo "Retrieving tenancy configuration..."
# Extract tenancy OCID from OCI CLI configuration file
TENANCY_OCID=$(grep '^tenancy' ~/.oci/config | awk -F'=' '{print $2}' | tr -d ' ')

# Validate tenancy OCID is present
if [[ -z "$TENANCY_OCID" ]]; then
    echo "ERROR: Unable to determine tenancy OCID from ~/.oci/config" | tee -a "$LOG_FILE"
    exit 1
fi

echo "Tenancy OCID: $TENANCY_OCID"

echo "Retrieving compartment hierarchy..."
# Query OCI for all compartments in the tenancy
COMPARTMENTS_JSON=$(oci iam compartment list \
    --compartment-id "$TENANCY_OCID" \
    --compartment-id-in-subtree true \
    --all \
    --output json 2>>"$LOG_FILE")

# Build compartment ID to name mapping
echo "$COMPARTMENTS_JSON" | jq -r '.data[] | select(."lifecycle-state"=="ACTIVE") | [.id, .name] | @tsv' > "${TEMP_DIR}/compartment_map.tsv"

# Include root tenancy in compartment mapping
TENANCY_NAME=$(oci iam tenancy get --tenancy-id "$TENANCY_OCID" --query 'data.name' --raw-output 2>>"$LOG_FILE")
echo -e "${TENANCY_OCID}\t${TENANCY_NAME}" >> "${TEMP_DIR}/compartment_map.tsv"

# Extract list of active compartment OCIDs
COMPARTMENT_IDS=$(echo "$COMPARTMENTS_JSON" | jq -r '.data[] | select(."lifecycle-state"=="ACTIVE") | .id')
COMPARTMENT_IDS="$COMPARTMENT_IDS"$'\n'"$TENANCY_OCID"

# Validate compartments were found
if [[ -z "$COMPARTMENT_IDS" ]]; then
    echo "ERROR: No active compartments found" | tee -a "$LOG_FILE"
    exit 1
fi

COMPARTMENT_COUNT=$(echo "$COMPARTMENT_IDS" | wc -l)
echo "Discovered $COMPARTMENT_COUNT active compartments"

echo "Building instance name mapping..."
# Create a mapping of instance IPs to instance names
> "${TEMP_DIR}/instance_map.tsv"

for COMP_ID in $COMPARTMENT_IDS; do
    INSTANCES=$(oci compute instance list \
        --compartment-id "$COMP_ID" \
        --all \
        --region "$REGION" \
        --output json 2>>"$LOG_FILE" || echo '{"data":[]}')
    
    INSTANCE_IDS=$(echo "$INSTANCES" | jq -r '.data[].id')
    
    for INSTANCE_ID in $INSTANCE_IDS; do
        INSTANCE_NAME=$(echo "$INSTANCES" | jq -r --arg id "$INSTANCE_ID" '.data[] | select(.id == $id) | .["display-name"]')
        INSTANCE_COMP=$(echo "$INSTANCES" | jq -r --arg id "$INSTANCE_ID" '.data[] | select(.id == $id) | .["compartment-id"]')
        
        # Get VNIC attachments to retrieve IP addresses
        VNIC_ATTACHMENTS=$(oci compute vnic-attachment list \
            --compartment-id "$INSTANCE_COMP" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --output json 2>>"$LOG_FILE" || echo '{"data":[]}')
        
        VNIC_IDS=$(echo "$VNIC_ATTACHMENTS" | jq -r '.data[] | select(."lifecycle-state"=="ATTACHED") | ."vnic-id"')
        
        for VNIC_ID in $VNIC_IDS; do
            VNIC_INFO=$(oci network vnic get \
                --vnic-id "$VNIC_ID" \
                --region "$REGION" \
                --output json 2>>"$LOG_FILE" || echo '{"data":{}}')
            
            PRIVATE_IP=$(echo "$VNIC_INFO" | jq -r '.data."private-ip" // ""')
            
            if [[ -n "$PRIVATE_IP" ]]; then
                echo -e "${PRIVATE_IP}\t${INSTANCE_NAME}" >> "${TEMP_DIR}/instance_map.tsv"
            fi
        done
    done
done

echo "Collecting load balancer data..."
# Initialize array to store load balancer data
LB_DATA=()

# Iterate through each compartment to collect load balancers
for COMP_ID in $COMPARTMENT_IDS; do
    LB_JSON=$(oci lb load-balancer list \
        --compartment-id "$COMP_ID" \
        --all \
        --region "$REGION" \
        --output json 2>>"$LOG_FILE" || true)

    # Append non-empty results to array
    if [[ -n "$LB_JSON" && "$LB_JSON" != "[]" && "$LB_JSON" != '{"data":[]}' ]]; then
        LB_DATA+=("$LB_JSON")
    fi
done

if [[ ${#LB_DATA[@]} -eq 0 ]]; then
    echo "WARNING: No load balancers found in any compartment" | tee -a "$LOG_FILE"
    echo "[]" > "$JSON_OUTPUT"
    echo "LB Name,LB OCID,Compartment Name,LB Shape,LB IP Address(es),Listener Port(s),Backend Set Name(s),Backend Server Names,Backends Attached,LB Health Status,Backend Health Status" > "$CSV_OUTPUT"
    exit 0
fi

echo "Retrieving detailed configuration for each load balancer..."
# Begin JSON array output
echo "[" > "$JSON_OUTPUT"
first=1

# Process each load balancer to extract detailed information
for LB_JSON in "${LB_DATA[@]}"; do
    LB_IDS=$(echo "$LB_JSON" | jq -r '.data[].id')

    for LB_ID in $LB_IDS; do
        echo "Processing load balancer: $LB_ID"
        
        # Get detailed load balancer information
        LB_DETAIL=$(oci lb load-balancer get \
            --load-balancer-id "$LB_ID" \
            --region "$REGION" \
            --output json 2>>"$LOG_FILE" || echo '{"data":{}}')

        LB_DATA_ITEM=$(echo "$LB_DETAIL" | jq -r '.data')
        
        # Extract basic information
        LB_NAME=$(echo "$LB_DATA_ITEM" | jq -r '.["display-name"] // "Unknown"')
        COMP_ID=$(echo "$LB_DATA_ITEM" | jq -r '.["compartment-id"]')
        LB_SHAPE=$(echo "$LB_DATA_ITEM" | jq -r '.["shape-name"] // "Unknown"')
        
        # Extract IP addresses
        IP_ADDRESSES=$(echo "$LB_DATA_ITEM" | jq -r '.["ip-addresses"][] | .["ip-address"]' | paste -sd ";" -)
        
        # Extract listener ports
        LISTENER_PORTS=$(echo "$LB_DATA_ITEM" | jq -r '.listeners | to_entries[] | "\(.key):\(.value.port)"' | paste -sd ";" -)
        
        # Extract backend set names
        BACKEND_SETS=$(echo "$LB_DATA_ITEM" | jq -r '.["backend-sets"] | keys[]' | paste -sd ";" -)
        
        # Extract backend server details (IPs and names)
        BACKEND_SERVER_INFO=""
        BACKEND_SET_NAMES=$(echo "$LB_DATA_ITEM" | jq -r '.["backend-sets"] | keys[]')
        
        BACKENDS_ATTACHED="No"
        OVERALL_BACKEND_HEALTH="OK"
        
        for BS_NAME in $BACKEND_SET_NAMES; do
            BACKENDS=$(echo "$LB_DATA_ITEM" | jq -r --arg bs "$BS_NAME" '.["backend-sets"][$bs].backends[]? | "\(.["ip-address"]):\(.port)"')
            
            if [[ -n "$BACKENDS" ]]; then
                BACKENDS_ATTACHED="Yes"
                
                while IFS= read -r backend; do
                    BACKEND_IP=$(echo "$backend" | cut -d':' -f1)
                    BACKEND_PORT=$(echo "$backend" | cut -d':' -f2)
                    
                    # Look up instance name from IP mapping
                    INSTANCE_NAME=$(grep "^${BACKEND_IP}" "${TEMP_DIR}/instance_map.tsv" 2>/dev/null | cut -f2 || echo "Unknown")
                    
                    if [[ -z "$INSTANCE_NAME" ]]; then
                        INSTANCE_NAME="${BACKEND_IP}"
                    fi
                    
                    if [[ -z "$BACKEND_SERVER_INFO" ]]; then
                        BACKEND_SERVER_INFO="${INSTANCE_NAME}:${BACKEND_PORT}"
                    else
                        BACKEND_SERVER_INFO="${BACKEND_SERVER_INFO}; ${INSTANCE_NAME}:${BACKEND_PORT}"
                    fi
                done <<< "$BACKENDS"
            fi
        done
        
        # Get backend health status
        LB_HEALTH=$(oci lb load-balancer-health get \
            --load-balancer-id "$LB_ID" \
            --region "$REGION" \
            --output json 2>>"$LOG_FILE" || echo '{"data":{}}')
        
        LB_OVERALL_STATUS=$(echo "$LB_HEALTH" | jq -r '.data.status // "UNKNOWN"')
        
        # Map OCI health status to simplified status
        case "$LB_OVERALL_STATUS" in
            "OK")
                LB_HEALTH_STATUS="OK"
                ;;
            "WARNING")
                LB_HEALTH_STATUS="Warning"
                ;;
            "CRITICAL")
                LB_HEALTH_STATUS="Critical"
                ;;
            "UNKNOWN")
                LB_HEALTH_STATUS="Incomplete"
                ;;
            *)
                LB_HEALTH_STATUS="Incomplete"
                ;;
        esac
        
        # Check backend health status
        BACKEND_HEALTH_STATUS="OK"
        HAS_CRITICAL=false
        HAS_WARNING=false
        HAS_UNKNOWN=false
        
        for BS_NAME in $BACKEND_SET_NAMES; do
            BS_HEALTH=$(echo "$LB_HEALTH" | jq -r --arg bs "$BS_NAME" '.data["backend-sets"][]? | select(.name == $bs) | .status // "UNKNOWN"')
            
            case "$BS_HEALTH" in
                "CRITICAL")
                    HAS_CRITICAL=true
                    ;;
                "WARNING")
                    HAS_WARNING=true
                    ;;
                "UNKNOWN")
                    HAS_UNKNOWN=true
                    ;;
            esac
        done
        
        if [[ "$HAS_CRITICAL" == true ]]; then
            BACKEND_HEALTH_STATUS="Critical"
        elif [[ "$HAS_WARNING" == true ]]; then
            BACKEND_HEALTH_STATUS="Warning"
        elif [[ "$HAS_UNKNOWN" == true ]]; then
            BACKEND_HEALTH_STATUS="Incomplete"
        fi
        
        # Handle empty values
        if [[ -z "$LISTENER_PORTS" ]]; then
            LISTENER_PORTS="None"
        fi
        
        if [[ -z "$BACKEND_SETS" ]]; then
            BACKEND_SETS="None"
        fi
        
        if [[ -z "$IP_ADDRESSES" ]]; then
            IP_ADDRESSES="None"
        fi
        
        if [[ -z "$BACKEND_SERVER_INFO" ]]; then
            BACKEND_SERVER_INFO="None"
        fi

        # Create enhanced data object with all extracted information
        ENHANCED_LB=$(echo "$LB_DATA_ITEM" | jq -c \
            --arg name "$LB_NAME" \
            --arg comp "$COMP_ID" \
            --arg shape "$LB_SHAPE" \
            --arg ips "$IP_ADDRESSES" \
            --arg ports "$LISTENER_PORTS" \
            --arg backends "$BACKEND_SETS" \
            --arg servers "$BACKEND_SERVER_INFO" \
            --arg attached "$BACKENDS_ATTACHED" \
            --arg lb_health "$LB_HEALTH_STATUS" \
            --arg backend_health "$BACKEND_HEALTH_STATUS" \
            '{
                "lb-name": $name,
                "lb-id": .id,
                "compartment-id": $comp,
                "lb-shape": $shape,
                "ip-addresses": $ips,
                "listener-ports": $ports,
                "backend-sets": $backends,
                "backend-servers": $servers,
                "backends-attached": $attached,
                "lb-health-status": $lb_health,
                "backend-health-status": $backend_health,
                "lifecycle-state": .["lifecycle-state"]
            }')

        # Write to JSON with proper comma separation
        if [[ $first -eq 0 ]]; then
            echo "," >> "$JSON_OUTPUT"
        fi
        echo "$ENHANCED_LB" >> "$JSON_OUTPUT"
        first=0
    done
done

# Close JSON array
echo "]" >> "$JSON_OUTPUT"

echo "Generating CSV report..."

# Prepare AWK associative arrays from mapping files
COMP_MAP_AWK=$(awk -F'\t' '{printf "comp[\"%s\"]=\"%s\"; ", $1, $2}' "${TEMP_DIR}/compartment_map.tsv")

# Convert JSON to CSV with column headers
jq -r '
    (["LB Name","LB OCID","Compartment Name","Compartment OCID","LB Shape","LB IP Address(es)","Listener Port(s)","Backend Set Name(s)","Backend Server Names","Backends Attached","LB Health Status","Backend Health Status","State"]),
    (.[] | [
        (.["lb-name"] // "Unknown"),
        (.["lb-id"] // ""),
        (.["compartment-id"] // ""),
        (.["compartment-id"] // ""),
        (.["lb-shape"] // "Unknown"),
        (.["ip-addresses"] // "None"),
        (.["listener-ports"] // "None"),
        (.["backend-sets"] // "None"),
        (.["backend-servers"] // "None"),
        (.["backends-attached"] // "No"),
        (.["lb-health-status"] // "Incomplete"),
        (.["backend-health-status"] // "Incomplete"),
        (.["lifecycle-state"] // "Unknown")
    ]) | @csv' "$JSON_OUTPUT" > "${TEMP_DIR}/lb_temp.csv"

# Replace compartment OCIDs with human-readable names
awk -F',' -v OFS=',' '
    BEGIN {
        '"$COMP_MAP_AWK"'
    }
    NR==1 {print; next}
    {
        comp_ocid = $4
        gsub(/"/, "", comp_ocid)

        if (comp_ocid in comp) {
            $3 = "\"" comp[comp_ocid] "\""
        }

        print
    }
' "${TEMP_DIR}/lb_temp.csv" > "$CSV_OUTPUT"

# Clean up temporary files
rm -rf "$TEMP_DIR"

# Calculate summary statistics
TOTAL_LBS=$(jq 'length' "$JSON_OUTPUT")
TOTAL_WITH_BACKENDS=$(jq '[.[] | select(.["backends-attached"] == "Yes")] | length' "$JSON_OUTPUT")
TOTAL_HEALTHY=$(jq '[.[] | select(.["lb-health-status"] == "OK")] | length' "$JSON_OUTPUT")
TOTAL_CRITICAL=$(jq '[.[] | select(.["lb-health-status"] == "Critical")] | length' "$JSON_OUTPUT")

echo "-----------------------------------------------------------"
echo "Load Balancer inventory export completed successfully"
echo "-----------------------------------------------------------"
echo "Total load balancers discovered: $TOTAL_LBS"
echo "Load balancers with backends attached: $TOTAL_WITH_BACKENDS"
echo "Healthy load balancers: $TOTAL_HEALTHY"
echo "Critical load balancers: $TOTAL_CRITICAL"
echo "JSON output: $JSON_OUTPUT"
echo "CSV output: $CSV_OUTPUT"
echo "Log file: $LOG_FILE"
echo "-----------------------------------------------------------"