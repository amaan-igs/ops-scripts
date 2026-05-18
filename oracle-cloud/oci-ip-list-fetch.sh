#!/opt/homebrew/bin/bash

set -euo pipefail

###############################################################################
# OCI Public IP Inventory Export Script
# Author: Amaan Ul Haq Siddiqui - DevOps Engineer
# Description: Exports all public IPs with their assigned resources
###############################################################################

REGION="me-jeddah-1"
DATE=$(date +%Y%m%d)
OUTPUT_FILE="oci_public_ips_${REGION}_${DATE}.csv"

echo "-----------------------------------------------------------"
echo "OCI Public IP Inventory Export"
echo "Region: $REGION | Date: $DATE"
echo "-----------------------------------------------------------"

# Get tenancy OCID from OCI config
TENANCY_OCID=$(rg '^tenancy' ~/.oci/config | awk -F'=' '{print $2}' | tr -d ' ')

echo "Retrieving compartments..."
COMPARTMENTS=$(oci iam compartment list \
    --compartment-id "$TENANCY_OCID" \
    --compartment-id-in-subtree true \
    --all \
    --output json 2>/dev/null)


# Build array of compartment IDs (including root tenancy)
readarray -t COMPARTMENT_IDS < <(echo "$COMPARTMENTS" | jq -r '.data[] | select(."lifecycle-state"=="ACTIVE") | .id')
COMPARTMENT_IDS+=("$TENANCY_OCID")

# Build compartment mapping
declare -A COMP_MAP
while IFS=$'\t' read -r id name; do
    COMP_MAP["$id"]="$name"
done < <(echo "$COMPARTMENTS" | jq -r '.data[] | select(."lifecycle-state"=="ACTIVE") | [.id, .name] | @tsv')

TENANCY_NAME=$(oci iam tenancy get --tenancy-id "$TENANCY_OCID" --query 'data.name' --raw-output 2>/dev/null)
COMP_MAP["$TENANCY_OCID"]="$TENANCY_NAME"

echo "Building resource name mappings..."
# Build mappings for instances, load balancers, and NAT gateways
declare -A INSTANCE_MAP LB_MAP NAT_MAP

for COMP_ID in "${COMPARTMENT_IDS[@]}"; do
    # Instance mapping
    while IFS=$'\t' read -r id name; do
        INSTANCE_MAP["$id"]="$name"
    done < <(oci compute instance list --compartment-id "$COMP_ID" --region "$REGION" --all --output json 2>/dev/null | jq -r '.data[]? | [.id, .["display-name"]] | @tsv')
    
    # Load Balancer mapping
    while IFS=$'\t' read -r id name; do
        LB_MAP["$id"]="$name"
    done < <(oci lb load-balancer list --compartment-id "$COMP_ID" --region "$REGION" --all --output json 2>/dev/null | jq -r '.data[]? | [.id, .["display-name"]] | @tsv')
    
    # NAT Gateway mapping
    while IFS=$'\t' read -r id name; do
        NAT_MAP["$id"]="$name"
    done < <(oci network nat-gateway list --compartment-id "$COMP_ID" --region "$REGION" --all --output json 2>/dev/null | jq -r '.data[]? | [.id, .["display-name"]] | @tsv')
done

# Write CSV header
echo "Public IP,Assigned To (Type),Resource Name,Compartment,State,Scope,Created Date,Lifetime" > "$OUTPUT_FILE"

echo "Collecting public IP data..."
echo "Compartment IDs to process:"
for cid in "${COMPARTMENT_IDS[@]}"; do
    echo "  $cid"
done
TOTAL_IPS=0

for COMP_ID in "${COMPARTMENT_IDS[@]}"; do
    # Ensure COMP_NAME is defined within the loop scope
    COMP_NAME="${COMP_MAP[$COMP_ID]:-UNKNOWN}"
    echo "--- Processing compartment: $COMP_ID ($COMP_NAME) ---"
    
    # Get all public IPs in this compartment
    PUBLIC_IPS=$(oci network public-ip list \
        --compartment-id "$COMP_ID" \
        --scope REGION \
        --region "$REGION" \
        --all \
        --output json 2>/dev/null || echo '{"data":[]}')

    IP_COUNT=$(echo "$PUBLIC_IPS" | jq -r '.data | length')

    if [[ "$IP_COUNT" -eq 0 ]]; then
        continue
    fi

    echo "Processing $IP_COUNT public IPs in compartment: $COMP_NAME"

    mapfile -t IP_ARRAY < <(echo "$PUBLIC_IPS" | jq -c '.data[]')
    for ip_data in "${IP_ARRAY[@]}"; do
            echo "  Found public IP: $(echo "$ip_data" | jq -r '."ip-address"')"
        IP_ADDRESS=$(echo "$ip_data" | jq -r '."ip-address"')
        STATE=$(echo "$ip_data" | jq -r '."lifecycle-state"')
        SCOPE=$(echo "$ip_data" | jq -r '.scope')
        CREATED_DATE=$(echo "$ip_data" | jq -r '."time-created"' | cut -d'T' -f1)
        LIFETIME=$(echo "$ip_data" | jq -r '.lifetime')
        ASSIGNED_ENTITY_ID=$(echo "$ip_data" | jq -r '."assigned-entity-id" // "Unassigned"')
        ASSIGNED_ENTITY_TYPE=$(echo "$ip_data" | jq -r '."assigned-entity-type" // "None"')
        DISPLAY_NAME=$(echo "$ip_data" | jq -r '."display-name" // ""')

        # Determine resource name and type
        RESOURCE_NAME="Unassigned"
        RESOURCE_TYPE="Unassigned"

        if [[ "$ASSIGNED_ENTITY_ID" != "Unassigned" && "$ASSIGNED_ENTITY_ID" != "null" ]]; then
            case "$ASSIGNED_ENTITY_TYPE" in
                "PRIVATE_IP")
                    # Get VNIC and then instance
                    PRIVATE_IP_DATA=$(oci network private-ip get \
                        --private-ip-id "$ASSIGNED_ENTITY_ID" \
                        --output json 2>/dev/null || echo '{"data":{}}')

                    VNIC_ID=$(echo "$PRIVATE_IP_DATA" | jq -r '.data."vnic-id" // ""')

                    if [[ -n "$VNIC_ID" && "$VNIC_ID" != "null" ]]; then
                        VNIC_DATA=$(oci network vnic get \
                            --vnic-id "$VNIC_ID" \
                            --output json 2>/dev/null || echo '{"data":{}}')

                        # Try to get instance from VNIC attachments
                        ATTACHMENTS_JSON=$(oci compute vnic-attachment list \
                            --vnic-id "$VNIC_ID" \
                            --region "$REGION" \
                            --all \
                            --output json 2>/dev/null || echo '{"data":[]}')
                        INSTANCE_ID=$(echo "$ATTACHMENTS_JSON" | jq -r '.data[0]."instance-id" // ""')

                        if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "null" ]]; then
                            RESOURCE_NAME="${INSTANCE_MAP[$INSTANCE_ID]:-$INSTANCE_ID}"
                            RESOURCE_TYPE="Compute Instance"
                        else
                            if [[ -n "$DISPLAY_NAME" ]]; then
                                RESOURCE_NAME="$DISPLAY_NAME"
                                # Infer Load Balancer type from display name if possible
                                if [[ "$DISPLAY_NAME" == *"LB"* || "$DISPLAY_NAME" == *"VIP"* ]]; then
                                    RESOURCE_TYPE="Load Balancer"
                                fi
                            else
                                RESOURCE_NAME="Private IP: $(echo "$PRIVATE_IP_DATA" | jq -r '.data."ip-address" // "Unknown"')"
                            fi
                            RESOURCE_TYPE="Private IP"
                        fi
                    else
                        if [[ -n "$DISPLAY_NAME" ]]; then
                            RESOURCE_NAME="$DISPLAY_NAME"
                        else
                            RESOURCE_NAME="Private IP: $(echo "$PRIVATE_IP_DATA" | jq -r '.data."ip-address" // "Unknown"')"
                        fi
                        RESOURCE_TYPE="Private IP"
                    fi
                    ;;

                "LOAD_BALANCER")
                    RESOURCE_NAME="${LB_MAP[$ASSIGNED_ENTITY_ID]:-$ASSIGNED_ENTITY_ID}"
                    RESOURCE_TYPE="Load Balancer"
                    ;;

                "NAT_GATEWAY")
                    # Prefer NAT_MAP, fallback to display-name or ID
                    if [[ -n "${NAT_MAP[$ASSIGNED_ENTITY_ID]:-}" ]]; then
                        RESOURCE_NAME="${NAT_MAP[$ASSIGNED_ENTITY_ID]}"
                    elif [[ -n "$DISPLAY_NAME" ]]; then
                        RESOURCE_NAME="$DISPLAY_NAME"
                    else
                        RESOURCE_NAME="$ASSIGNED_ENTITY_ID"
                    fi
                    RESOURCE_TYPE="NAT Gateway"
                    ;;

                *)
                    RESOURCE_NAME="$ASSIGNED_ENTITY_TYPE"
                    RESOURCE_TYPE="$ASSIGNED_ENTITY_TYPE"
                    ;;
            esac
        else
            # If not assigned, use display-name if available
            if [[ -n "$DISPLAY_NAME" && "$RESOURCE_NAME" == "Unassigned" ]]; then
                RESOURCE_NAME="$DISPLAY_NAME"
            fi
        fi

        # Write to CSV
        echo "\"$IP_ADDRESS\",\"$RESOURCE_TYPE\",\"$RESOURCE_NAME\",\"$COMP_NAME\",\"$STATE\",\"$SCOPE\",\"$CREATED_DATE\",\"$LIFETIME\"" >> "$OUTPUT_FILE"

        TOTAL_IPS=$((TOTAL_IPS + 1))
    done
done

echo "Export completed successfully"
echo ""
echo "Total Public IPs found: $TOTAL_IPS"
echo "Output file: $OUTPUT_FILE"

# Sample CSV Output Format:
# Public IP,      Assigned To (Type),  Resource Name,    Compartment,    State,    Scope,    Created Date,  Lifetime
# "<PUBLIC_IP>","<ASSIGNED_TO_TYPE>","<RESOURCE_NAME>","<COMPARTMENT>","<STATE>","<SCOPE>","<YYYY-MM-DD>","<LIFETIME>"
# "<PUBLIC_IP>","<ASSIGNED_TO_TYPE>","<RESOURCE_NAME>","<COMPARTMENT>","<STATE>","<SCOPE>","<YYYY-MM-DD>","<LIFETIME>"
