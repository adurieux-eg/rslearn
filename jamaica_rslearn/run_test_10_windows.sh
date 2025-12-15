#!/bin/bash
# Test run: Process only 10 windows to validate settings
# Run this BEFORE the full pipeline to check results

set -e

export MAIN_DATASET_PATH=./jamaica_test_dataset
TIME_RANGE_START="2025-01-01T00:00:00+00:00"
TIME_RANGE_END="2025-03-31T00:00:00+00:00"
RESOLUTION=10
AOI_FILE="./jamaica_seagrass_aoi.geojson"
GCS_DEST="gs://chris-seagrass/features/olmo_earth_test"
MAX_WINDOWS=10

echo "========================================="
echo "TEST RUN: 10 Windows Only"
echo "========================================="
echo "Settings:"
echo "  - Composite mode with MEDIAN"
echo "  - Cloud filter: <10%"
echo "  - Time: Jan-Mar 2025"
echo "  - overlap_ratio: 0.625, padding: 5"
echo ""

# Step 1: Create dataset and windows
echo "Step 1: Creating test dataset..."
rm -rf "$MAIN_DATASET_PATH"
mkdir -p "$MAIN_DATASET_PATH"
cp dataset_config.json "$MAIN_DATASET_PATH/config.json"

rslearn dataset add_windows \
  --root "$MAIN_DATASET_PATH" \
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

# Step 2: Filter to AOI overlap
echo ""
echo "Step 2: Filtering windows to AOI..."
python filter_windows_by_aoi.py "$MAIN_DATASET_PATH" "$AOI_FILE" 0.1
echo "✅ Windows filtered"

# Step 3: Keep only first 10 windows
echo ""
echo "Step 3: Keeping only $MAX_WINDOWS windows for test..."
ALL_WINDOWS=($(ls -d $MAIN_DATASET_PATH/windows/default/*/ 2>/dev/null | head -$MAX_WINDOWS | xargs -n1 basename))
ALL_DIRS=($(ls -d $MAIN_DATASET_PATH/windows/default/*/))

count=0
for dir in "${ALL_DIRS[@]}"; do
    count=$((count + 1))
    if [ $count -gt $MAX_WINDOWS ]; then
        rm -rf "$dir"
    fi
done

REMAINING=$(ls -d $MAIN_DATASET_PATH/windows/default/*/ 2>/dev/null | wc -l)
echo "✅ Keeping $REMAINING windows"

# Step 4: Prepare
echo ""
echo "Step 4: Preparing (querying imagery)..."
rslearn dataset prepare \
  --root "$MAIN_DATASET_PATH" \
  --workers 8 \
  --retry-max-attempts 5 \
  --retry-backoff-seconds 5

# Step 5: Materialize
echo ""
echo "Step 5: Materializing (downloading + compositing)..."
rslearn dataset materialize \
  --root "$MAIN_DATASET_PATH" \
  --workers 8 \
  --no-use-initial-job \
  --retry-max-attempts 5 \
  --retry-backoff-seconds 5

# Step 6: Compute embeddings
echo ""
echo "Step 6: Computing embeddings..."
export DATASET_PATH="$MAIN_DATASET_PATH"
rslearn model predict --config model_config.yaml

# Step 7: Upload to GCS
echo ""
echo "Step 7: Uploading to GCS..."
for window_dir in $MAIN_DATASET_PATH/windows/default/*/; do
    window_name=$(basename "$window_dir")
    tif_file=$(find "$window_dir/layers/embeddings" -name 'geotiff.tif' 2>/dev/null | head -1)
    
    if [ -n "$tif_file" ] && [ -f "$tif_file" ]; then
        echo "  Uploading ${window_name}.tif..."
        gsutil -q cp "$tif_file" "$GCS_DEST/${window_name}.tif"
    fi
done

echo ""
echo "========================================="
echo "✅ TEST COMPLETE!"
echo "========================================="
echo ""
echo "Embeddings at: $GCS_DEST/"
echo ""
echo "To download and inspect:"
echo "  gsutil -m cp '$GCS_DEST/*.tif' ./"
echo ""
echo "If results look good, run the full pipeline:"
echo "  ./run_pipeline_batched.sh"

