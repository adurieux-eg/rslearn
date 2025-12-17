#!/bin/bash
# Full AOI script for 10m resolution embeddings
# Processes ALL windows in batches to avoid disk space issues

set -e

# Configuration
MAIN_DATASET_PATH=./jamaica_full_10m
TIME_RANGE_START="2025-01-01T00:00:00+00:00"
TIME_RANGE_END="2025-03-31T00:00:00+00:00"
RESOLUTION=10
AOI_FILE="./jamaica_seagrass_aoi.geojson"
GCS_DEST="gs://chris-seagrass/features/olmo_earth_10m"
BATCH_SIZE=10  # Windows per batch (upload after each batch)
RESUME_FROM_BATCH=${1:-1}  # Resume from batch N (default: 1, start fresh)

echo "========================================="
echo "10m Resolution FULL RUN"
echo "========================================="
echo "Output: $GCS_DEST"
echo "Batch size: $BATCH_SIZE windows"
if [ "$RESUME_FROM_BATCH" -gt 1 ]; then
    echo "RESUMING from batch $RESUME_FROM_BATCH"
fi
echo ""

# Step 1: Create dataset and windows
echo "Step 1: Creating dataset and windows..."
rm -rf $MAIN_DATASET_PATH
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
  --grid_size 512

INITIAL_COUNT=$(ls -d $MAIN_DATASET_PATH/windows/default/*/ 2>/dev/null | wc -l)
echo "✅ Windows created: $INITIAL_COUNT"

# Step 2: Filter windows to those overlapping with AOI
echo ""
echo "Step 2: Filtering windows to AOI overlap..."
python3 filter_windows_by_aoi.py "$MAIN_DATASET_PATH" "$AOI_FILE" 5.0

FILTERED_COUNT=$(ls -d $MAIN_DATASET_PATH/windows/default/*/ 2>/dev/null | wc -l)
echo "✅ Windows after AOI filter: $FILTERED_COUNT"

# Get all windows to process
ALL_WINDOWS=($(ls -d $MAIN_DATASET_PATH/windows/default/*/ | xargs -n1 basename | sort))
TOTAL_WINDOWS=${#ALL_WINDOWS[@]}
TOTAL_BATCHES=$(( (TOTAL_WINDOWS + BATCH_SIZE - 1) / BATCH_SIZE ))

echo ""
echo "========================================="
echo "Processing $TOTAL_WINDOWS windows in $TOTAL_BATCHES batches"
echo "========================================="

# Disable parallel composite upload to avoid download issues
gcloud config set storage/parallel_composite_upload_enabled False 2>/dev/null

# Upload config files first
echo ""
echo "Uploading config files..."
gcloud storage cp model_config.yaml "$GCS_DEST/model_config.yaml" --quiet
gcloud storage cp dataset_config.json "$GCS_DEST/dataset_config.json" --quiet
gcloud storage cp run_full_10m.sh "$GCS_DEST/run_full_10m.sh" --quiet
echo "✅ Config files uploaded"

# Process in batches
BATCH_NUM=0
WINDOWS_PROCESSED=0
START_TIME=$(date +%s)

for ((i=0; i<TOTAL_WINDOWS; i+=BATCH_SIZE)); do
    BATCH_NUM=$((BATCH_NUM + 1))
    
    # Skip batches before resume point
    if [ "$BATCH_NUM" -lt "$RESUME_FROM_BATCH" ]; then
        WINDOWS_PROCESSED=$((WINDOWS_PROCESSED + BATCH_SIZE))
        echo "Skipping batch $BATCH_NUM (resuming from $RESUME_FROM_BATCH)"
        continue
    fi
    
    # Get windows for this batch
    BATCH_WINDOWS=("${ALL_WINDOWS[@]:i:BATCH_SIZE}")
    BATCH_COUNT=${#BATCH_WINDOWS[@]}
    
    echo ""
    echo "========================================="
    echo "BATCH $BATCH_NUM / $TOTAL_BATCHES ($BATCH_COUNT windows)"
    echo "========================================="
    echo "Windows: ${BATCH_WINDOWS[*]}"
    
    # Create temp dataset with only batch windows
    BATCH_PATH="./batch_temp"
    rm -rf $BATCH_PATH
    mkdir -p $BATCH_PATH/windows/default
    cp $MAIN_DATASET_PATH/config.json $BATCH_PATH/config.json
    
    # Copy batch windows to temp dataset
    for w in "${BATCH_WINDOWS[@]}"; do
        cp -r "$MAIN_DATASET_PATH/windows/default/$w" "$BATCH_PATH/windows/default/"
    done
    
    # Step 3: Prepare batch
    echo ""
    echo "  Preparing batch..."
    rslearn dataset prepare \
      --root "$BATCH_PATH" \
      --workers 4 \
      --retry-max-attempts 5 \
      --retry-backoff-seconds 5
    
    # Step 4: Materialize batch
    echo ""
    echo "  Materializing batch..."
    rslearn dataset materialize \
      --root "$BATCH_PATH" \
      --workers 4 \
      --no-use-initial-job \
      --retry-max-attempts 5 \
      --retry-backoff-seconds 5
    
    # Step 5: Predict batch
    echo ""
    echo "  Computing embeddings..."
    export DATASET_PATH="$BATCH_PATH"
    rslearn model predict --config model_config.yaml
    
    # Step 6: Upload batch to GCS
    echo ""
    echo "  Uploading to GCS..."
    UPLOADED=0
    for w in "${BATCH_WINDOWS[@]}"; do
        tif=$(find "$BATCH_PATH/windows/default/$w/layers/embeddings" -name 'geotiff.tif' 2>/dev/null | head -1)
        if [ -n "$tif" ]; then
            gcloud storage cp "$tif" "$GCS_DEST/${w}.tif" --quiet
            UPLOADED=$((UPLOADED + 1))
        fi
    done
    echo "  ✅ Uploaded $UPLOADED files"
    
    # Step 7: Cleanup batch
    echo "  Cleaning up..."
    rm -rf $BATCH_PATH
    
    WINDOWS_PROCESSED=$((WINDOWS_PROCESSED + BATCH_COUNT))
    
    # Progress update
    ELAPSED=$(($(date +%s) - START_TIME))
    if [ $WINDOWS_PROCESSED -gt 0 ]; then
        AVG_TIME=$((ELAPSED / WINDOWS_PROCESSED))
        REMAINING=$(( (TOTAL_WINDOWS - WINDOWS_PROCESSED) * AVG_TIME ))
        REMAINING_MIN=$((REMAINING / 60))
    else
        REMAINING_MIN="?"
    fi
    
    echo ""
    echo "  ✅ BATCH $BATCH_NUM COMPLETE"
    echo "  Progress: $WINDOWS_PROCESSED / $TOTAL_WINDOWS windows"
    echo "  Elapsed: $((ELAPSED / 60)) min | Remaining: ~${REMAINING_MIN} min"
    
    # Show disk usage
    echo "  Disk: $(df -h /home/alicedurieux | tail -1 | awk '{print $4}') free"
done

# Final cleanup
rm -rf $MAIN_DATASET_PATH

echo ""
echo "========================================="
echo "✅ FULL RUN COMPLETE!"
echo "========================================="
echo "Total windows: $TOTAL_WINDOWS"
echo "Total time: $(($(date +%s) - START_TIME)) seconds"
echo ""
echo "Embeddings at: $GCS_DEST"
echo ""
echo "To download:"
echo "  gsutil -m cp '$GCS_DEST/*.tif' ./"

