#!/bin/bash
# Jamaica Full Coastline - BATCHED OlmoEarth Pipeline
# Processes windows in batches to avoid disk overflow
# Uploads to GCS after each batch and cleans up local files

set -e

# Configuration
MAIN_DATASET_PATH=./jamaica_full_dataset
TIME_RANGE_START="2025-01-01T00:00:00+00:00"
TIME_RANGE_END="2025-03-31T00:00:00+00:00"
RESOLUTION=10
AOI_FILE="./jamaica_seagrass_aoi.geojson"
GCS_DEST="gs://chris-seagrass/features/olmo_earth"
BATCH_SIZE=20
PROGRESS_FILE="./batch_progress.txt"

echo "========================================="
echo "Jamaica Coastline - BATCHED Pipeline"
echo "========================================="
echo "Batch size: $BATCH_SIZE windows"
echo "GCS destination: $GCS_DEST"
echo ""

# Initialize progress file if it doesn't exist
touch "$PROGRESS_FILE"

# Step 1: Create dataset and windows (only if not already done)
if [ ! -d "$MAIN_DATASET_PATH/windows/default" ]; then
    echo "Step 1: Creating dataset structure..."
    mkdir -p $MAIN_DATASET_PATH
    cp dataset_config.json $MAIN_DATASET_PATH/config.json
    
    rslearn dataset add_windows \
      --root $MAIN_DATASET_PATH \
      --group default \
      --name default \
      --utm \
      --resolution $RESOLUTION \
      --src_crs EPSG:4326 \
      --fname $AOI_FILE \
      --start $TIME_RANGE_START \
      --end $TIME_RANGE_END \
      --grid_size 1024
    echo "✅ Windows created"
    
    echo ""
    echo "Step 1b: Filtering windows to AOI overlap..."
    python filter_windows_by_aoi.py "$MAIN_DATASET_PATH" "$AOI_FILE" 0.1
    echo "✅ Windows filtered"
else
    echo "Step 1: Dataset already exists, skipping creation"
fi

# Get list of all windows
ALL_WINDOWS=($(ls -d $MAIN_DATASET_PATH/windows/default/*/ 2>/dev/null | xargs -n1 basename))
TOTAL_WINDOWS=${#ALL_WINDOWS[@]}
echo "Total windows: $TOTAL_WINDOWS"
echo ""

# Filter out already-completed windows
PENDING_WINDOWS=()
for w in "${ALL_WINDOWS[@]}"; do
    if ! grep -q "^$w$" "$PROGRESS_FILE" 2>/dev/null; then
        PENDING_WINDOWS+=("$w")
    fi
done

COMPLETED=$(($TOTAL_WINDOWS - ${#PENDING_WINDOWS[@]}))
echo "Already completed: $COMPLETED"
echo "Pending: ${#PENDING_WINDOWS[@]}"
echo ""

if [ ${#PENDING_WINDOWS[@]} -eq 0 ]; then
    echo "✅ All windows already processed!"
    exit 0
fi

# Process in batches
BATCH_NUM=1
TOTAL_BATCHES=$(( (${#PENDING_WINDOWS[@]} + BATCH_SIZE - 1) / BATCH_SIZE ))

for ((i=0; i<${#PENDING_WINDOWS[@]}; i+=BATCH_SIZE)); do
    BATCH=("${PENDING_WINDOWS[@]:i:BATCH_SIZE}")
    BATCH_COUNT=${#BATCH[@]}
    
    echo "========================================="
    echo "BATCH $BATCH_NUM / $TOTAL_BATCHES ($BATCH_COUNT windows)"
    echo "========================================="
    echo "Windows: ${BATCH[0]} ... ${BATCH[$((BATCH_COUNT-1))]}"
    echo ""
    
    # Create temporary batch dataset by symlinking only batch windows
    BATCH_DATASET="./batch_temp_dataset"
    rm -rf "$BATCH_DATASET"
    mkdir -p "$BATCH_DATASET/windows/default"
    cp "$MAIN_DATASET_PATH/config.json" "$BATCH_DATASET/config.json"
    
    for w in "${BATCH[@]}"; do
        ln -s "$(realpath $MAIN_DATASET_PATH/windows/default/$w)" "$BATCH_DATASET/windows/default/$w"
    done
    
    echo "Step 2: Preparing batch (querying imagery)..."
    rslearn dataset prepare \
      --root "$BATCH_DATASET" \
      --workers 8 \
      --retry-max-attempts 5 \
      --retry-backoff-seconds 5
    
    echo ""
    echo "Step 3: Materializing batch (downloading imagery)..."
    rslearn dataset materialize \
      --root "$BATCH_DATASET" \
      --workers 8 \
      --no-use-initial-job \
      --retry-max-attempts 5 \
      --retry-backoff-seconds 5
    
    echo ""
    echo "Step 4: Computing embeddings for batch..."
    export DATASET_PATH="$BATCH_DATASET"
    rslearn model predict --config model_config.yaml
    
    echo ""
    echo "Step 5: Uploading batch to GCS..."
    BATCH_UPLOADED=0
    for w in "${BATCH[@]}"; do
        window_dir="$BATCH_DATASET/windows/default/$w"
        
        # Find the embedding file
        tif_file=$(find "$window_dir/layers/embeddings" -name 'geotiff.tif' 2>/dev/null | head -1)
        
        if [ -n "$tif_file" ] && [ -f "$tif_file" ]; then
            dest_path="$GCS_DEST/${w}.tif"
            echo "  Uploading $w.tif..."
            if gsutil -q cp "$tif_file" "$dest_path"; then
                echo "$w" >> "$PROGRESS_FILE"
                BATCH_UPLOADED=$((BATCH_UPLOADED + 1))
                echo "    ✅ Uploaded"
            else
                echo "    ❌ Upload failed"
            fi
        else
            echo "  ⚠️  No embedding found for $w"
        fi
    done
    
    echo ""
    echo "Step 6: Cleaning up batch local files..."
    # Remove symlinks and actual data from source
    for w in "${BATCH[@]}"; do
        # Remove layers from the REAL dataset path (not symlink)
        rm -rf "$MAIN_DATASET_PATH/windows/default/$w/layers/sentinel2_l2a"*
        rm -rf "$MAIN_DATASET_PATH/windows/default/$w/layers/embeddings"
    done
    rm -rf "$BATCH_DATASET"
    
    COMPLETED=$(wc -l < "$PROGRESS_FILE")
    DISK_FREE=$(df -BG / | tail -1 | awk '{print $4}')
    
    echo ""
    echo "✅ Batch $BATCH_NUM complete: $BATCH_UPLOADED uploaded"
    echo "   Total progress: $COMPLETED / $TOTAL_WINDOWS"
    echo "   Disk free: $DISK_FREE"
    echo ""
    
    BATCH_NUM=$((BATCH_NUM + 1))
done

echo "========================================="
echo "✅ ALL BATCHES COMPLETE!"
echo "========================================="
echo "Total windows processed: $(wc -l < $PROGRESS_FILE)"
echo "Embeddings at: $GCS_DEST"
echo ""
echo "To list: gsutil ls $GCS_DEST/*.tif"
echo "To download: gsutil -m cp $GCS_DEST/*.tif ./"

