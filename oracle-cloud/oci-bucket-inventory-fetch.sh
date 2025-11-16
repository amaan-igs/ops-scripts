#!/bin/bash

set -euo pipefail

###############################################################################
# OCI Object Storage Bucket Inventory Export Script
# Author: Amaan Ul Haq Siddiqui - DevOps Engineer
# Description: Exports comprehensive inventory of OCI object storage buckets
#              including storage tier, visibility, auto-tiering status,
#              object count, size, and compartment information.
###############################################################################

# Configuration: Target region and output settings
REGION="me-jeddah-1"
DATE=$(date +%Y%m%d)
OUTPUT_DIR="oci_bucket_inventory_${REGION}_${DATE}"
LOG_FILE="${OUTPUT_DIR}/bucket_inventory.log"
JSON_OUTPUT="${OUTPUT_DIR}/bucket_details.json"
CSV_OUTPUT="${OUTPUT_DIR}/bucket_inventory.csv"
TEMP_DIR="${OUTPUT_DIR}/temp"

# Exclusion lists
EXCLUDE_COMPARTMENTS=(
    "ocid1.compartment.oc1..aaaaaaaauyqz5y3w5cbl5i6hgxtvwbztmrmepqa6wxjqlvnva7jlmgbrccia"
    "ocid1.compartment.oc1..aaaaaaaa6julkn5rvic63xs6nsua3sltgs5ykrejlopqy6zsjbl46ajdepzq" 	
)

EXCLUDE_BUCKETS=(
    "Backend-Storage"
    "AWS-Archive"
)

# Initialize output directory structure
mkdir -p "$OUTPUT_DIR" "$TEMP_DIR"

echo "-----------------------------------------------------------"
echo "OCI Object Storage Bucket Inventory Export"
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

echo "Retrieving Object Storage namespace..."
# Get the Object Storage namespace for the tenancy
NAMESPACE=$(oci os ns get --query 'data' --raw-output 2>>"$LOG_FILE")

if [[ -z "$NAMESPACE" ]]; then
    echo "ERROR: Unable to retrieve Object Storage namespace" | tee -a "$LOG_FILE"
    exit 1
fi

echo "Object Storage namespace: $NAMESPACE"

echo "Collecting bucket data across all compartments..."
# Begin JSON array output
echo "[" > "$JSON_OUTPUT"
first=1

TOTAL_BUCKETS=0

# Iterate through each compartment to collect buckets
for COMP_ID in $COMPARTMENT_IDS; do
    # Check if compartment is in exclusion list
    SKIP_COMPARTMENT=false
    for EXCLUDED_COMP in "${EXCLUDE_COMPARTMENTS[@]}"; do
        if [[ "$COMP_ID" == "$EXCLUDED_COMP" ]]; then
            echo "Skipping excluded compartment: $COMP_ID"
            SKIP_COMPARTMENT=true
            break
        fi
    done
    
    if [[ "$SKIP_COMPARTMENT" == true ]]; then
        continue
    fi
    
    echo "Scanning compartment: $COMP_ID"
    
    # List buckets in the compartment
    BUCKETS_JSON=$(oci os bucket list \
        --compartment-id "$COMP_ID" \
        --namespace-name "$NAMESPACE" \
        --all \
        --output json 2>>"$LOG_FILE" || echo '{"data":[]}')
    
    BUCKET_NAMES=$(echo "$BUCKETS_JSON" | jq -r '.data[]?.name // empty')
    
    if [[ -z "$BUCKET_NAMES" ]]; then
        continue
    fi
    
    # Process each bucket to get detailed information
    while IFS= read -r BUCKET_NAME; do
        if [[ -z "$BUCKET_NAME" ]]; then
            continue
        fi
        
        # Check if bucket is in exclusion list
        SKIP_BUCKET=false
        for EXCLUDED_BUCKET in "${EXCLUDE_BUCKETS[@]}"; do
            if [[ "$BUCKET_NAME" == "$EXCLUDED_BUCKET" ]]; then
                echo "Skipping excluded bucket: $BUCKET_NAME"
                SKIP_BUCKET=true
                break
            fi
        done
        
        if [[ "$SKIP_BUCKET" == true ]]; then
            continue
        fi
        
        echo "Processing bucket: $BUCKET_NAME"
        TOTAL_BUCKETS=$((TOTAL_BUCKETS + 1))
        
        # Get detailed bucket information
        BUCKET_DETAIL=$(oci os bucket get \
            --bucket-name "$BUCKET_NAME" \
            --namespace-name "$NAMESPACE" \
            --output json 2>>"$LOG_FILE" || echo '{"data":{}}')
        
        BUCKET_DATA=$(echo "$BUCKET_DETAIL" | jq -r '.data')
        
        # Get bucket statistics (object count and size)
        BUCKET_STATS=$(oci os object list \
            --bucket-name "$BUCKET_NAME" \
            --namespace-name "$NAMESPACE" \
            --fields name,size \
            --all \
            --output json 2>>"$LOG_FILE" || echo '{"data":[]}')
        
        # Calculate actual object count and total size (handle null/empty data)
        APPROXIMATE_COUNT=$(echo "$BUCKET_STATS" | jq '[.data[]?] | length // 0')
        APPROXIMATE_SIZE=$(echo "$BUCKET_STATS" | jq '[.data[]? | .size // 0] | add // 0')
        
        # Extract bucket properties
        STORAGE_TIER=$(echo "$BUCKET_DATA" | jq -r '.["storage-tier"] // "Unknown"')
        PUBLIC_ACCESS=$(echo "$BUCKET_DATA" | jq -r '.["public-access-type"] // "NoPublicAccess"')
        TIME_CREATED=$(echo "$BUCKET_DATA" | jq -r '.["time-created"] // "Unknown"')
        AUTO_TIERING=$(echo "$BUCKET_DATA" | jq -r '.["auto-tiering"] // "Disabled"')
        
        # Convert visibility to human-readable format
        case "$PUBLIC_ACCESS" in
            "NoPublicAccess")
                VISIBILITY="Private"
                ;;
            "ObjectRead")
                VISIBILITY="Public (Read)"
                ;;
            "ObjectReadWithoutList")
                VISIBILITY="Public (Read without List)"
                ;;
            *)
                VISIBILITY="Unknown"
                ;;
        esac
        
        # Convert auto-tiering to human-readable format
        case "$AUTO_TIERING" in
            "Disabled"|"disabled")
                AUTO_TIER_STATUS="Disabled"
                ;;
            "InfrequentAccess"|"infrequent_access")
                AUTO_TIER_STATUS="Enabled"
                ;;
            *)
                AUTO_TIER_STATUS="$AUTO_TIERING"
                ;;
        esac
        
        # Convert size from bytes to human-readable format
        SIZE_BYTES=$APPROXIMATE_SIZE
        if [[ "$SIZE_BYTES" =~ ^[0-9]+$ ]]; then
            if [[ $SIZE_BYTES -ge 1099511627776 ]]; then
                SIZE_TB=$(awk "BEGIN {printf \"%.2f\", $SIZE_BYTES / 1099511627776}")
                SIZE_DISPLAY="${SIZE_TB} TB"
            elif [[ $SIZE_BYTES -ge 1073741824 ]]; then
                SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $SIZE_BYTES / 1073741824}")
                SIZE_DISPLAY="${SIZE_GB} GB"
            elif [[ $SIZE_BYTES -ge 1048576 ]]; then
                SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $SIZE_BYTES / 1048576}")
                SIZE_DISPLAY="${SIZE_MB} MB"
            elif [[ $SIZE_BYTES -ge 1024 ]]; then
                SIZE_KB=$(awk "BEGIN {printf \"%.2f\", $SIZE_BYTES / 1024}")
                SIZE_DISPLAY="${SIZE_KB} KB"
            else
                SIZE_DISPLAY="${SIZE_BYTES} Bytes"
            fi
        else
            SIZE_DISPLAY="0 Bytes"
        fi
        
        # Create enhanced bucket data object
        ENHANCED_BUCKET=$(echo "$BUCKET_DATA" | jq -c \
            --arg name "$BUCKET_NAME" \
            --arg comp "$COMP_ID" \
            --arg tier "$STORAGE_TIER" \
            --arg visibility "$VISIBILITY" \
            --arg created "$TIME_CREATED" \
            --arg auto_tier "$AUTO_TIER_STATUS" \
            --arg obj_count "$APPROXIMATE_COUNT" \
            --arg size "$SIZE_DISPLAY" \
            --arg size_bytes "$SIZE_BYTES" \
            '{
                "bucket-name": $name,
                "compartment-id": $comp,
                "storage-tier": $tier,
                "visibility": $visibility,
                "time-created": $created,
                "auto-tiering": $auto_tier,
                "object-count": $obj_count,
                "approximate-size": $size,
                "size-bytes": $size_bytes,
                "namespace": .namespace
            }')
        
        # Write to JSON with proper comma separation
        if [[ $first -eq 0 ]]; then
            echo "," >> "$JSON_OUTPUT"
        fi
        echo "$ENHANCED_BUCKET" >> "$JSON_OUTPUT"
        first=0
        
    done <<< "$BUCKET_NAMES"
done

# Close JSON array
echo "]" >> "$JSON_OUTPUT"

echo "Generating CSV report..."

# Prepare AWK associative arrays from mapping files
COMP_MAP_AWK=$(awk -F'\t' '{printf "comp[\"%s\"]=\"%s\"; ", $1, $2}' "${TEMP_DIR}/compartment_map.tsv")

# Convert JSON to CSV with column headers
jq -r '
    (["Bucket Name","Compartment Name","Compartment OCID","Default Storage Tier","Visibility","Time Created","Auto-Tiering","Approximate Object Count","Approximate Size","Namespace"]),
    (.[] | [
        (.["bucket-name"] // "Unknown"),
        (.["compartment-id"] // ""),
        (.["compartment-id"] // ""),
        (.["storage-tier"] // "Unknown"),
        (.["visibility"] // "Private"),
        (.["time-created"] // "Unknown"),
        (.["auto-tiering"] // "Disabled"),
        (.["object-count"] // "0"),
        (.["approximate-size"] // "0 Bytes"),
        (.namespace // "")
    ]) | @csv' "$JSON_OUTPUT" > "${TEMP_DIR}/bucket_temp.csv"

# Replace compartment OCIDs with human-readable names
awk -F',' -v OFS=',' '
    BEGIN {
        '"$COMP_MAP_AWK"'
    }
    NR==1 {print; next}
    {
        comp_ocid = $3
        gsub(/"/, "", comp_ocid)

        if (comp_ocid in comp) {
            $2 = "\"" comp[comp_ocid] "\""
        }

        print
    }
' "${TEMP_DIR}/bucket_temp.csv" > "$CSV_OUTPUT"

# Clean up temporary files
rm -rf "$TEMP_DIR"

# Calculate summary statistics
TOTAL_OBJECTS=$(jq '[.[] | (.["object-count"] | tonumber)] | add' "$JSON_OUTPUT")
TOTAL_SIZE_BYTES=$(jq '[.[] | (.["size-bytes"] | tonumber)] | add' "$JSON_OUTPUT")

# Convert total size to human-readable format
if [[ "$TOTAL_SIZE_BYTES" =~ ^[0-9]+$ ]]; then
    if [[ $TOTAL_SIZE_BYTES -ge 1099511627776 ]]; then
        TOTAL_SIZE_TB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_SIZE_BYTES / 1099511627776}")
        TOTAL_SIZE_DISPLAY="${TOTAL_SIZE_TB} TB"
    elif [[ $TOTAL_SIZE_BYTES -ge 1073741824 ]]; then
        TOTAL_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_SIZE_BYTES / 1073741824}")
        TOTAL_SIZE_DISPLAY="${TOTAL_SIZE_GB} GB"
    elif [[ $TOTAL_SIZE_BYTES -ge 1048576 ]]; then
        TOTAL_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_SIZE_BYTES / 1048576}")
        TOTAL_SIZE_DISPLAY="${TOTAL_SIZE_MB} MB"
    else
        TOTAL_SIZE_DISPLAY="${TOTAL_SIZE_BYTES} Bytes"
    fi
else
    TOTAL_SIZE_DISPLAY="0 Bytes"
fi

BUCKETS_WITH_AUTO_TIER=$(jq '[.[] | select(.["auto-tiering"] == "Enabled")] | length' "$JSON_OUTPUT")
PUBLIC_BUCKETS=$(jq '[.[] | select(.visibility != "Private")] | length' "$JSON_OUTPUT")

echo "-----------------------------------------------------------"
echo "Object Storage Bucket inventory export completed successfully"
echo "-----------------------------------------------------------"
echo "Total buckets discovered: $TOTAL_BUCKETS"
echo "Total objects across all buckets: $TOTAL_OBJECTS"
echo "Total storage used: $TOTAL_SIZE_DISPLAY"
echo "Buckets with auto-tiering enabled: $BUCKETS_WITH_AUTO_TIER"
echo "Public buckets: $PUBLIC_BUCKETS"
echo "JSON output: $JSON_OUTPUT"
echo "CSV output: $CSV_OUTPUT"
echo "Log file: $LOG_FILE"
echo "-----------------------------------------------------------"
