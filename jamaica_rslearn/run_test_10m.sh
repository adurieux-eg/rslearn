#!/bin/bash
# Test script for 10m resolution embeddings (10 windows only)
# Tests the new Upsample layer configuration

set -e

# Configuration
DATASET_PATH=./jamaica_test_10m
TIME_RANGE_START="2025-01-01T00:00:00+00:00"
TIME_RANGE_END="2025-03-31T00:00:00+00:00"
RESOLUTION=10
AOI_FILE="./jamaica_seagrass_aoi.geojson"
GCS_DEST="gs://chris-seagrass/features/olmo_earth_10m_test"
MAX_WINDOWS=10

echo "========================================="
echo "10m Resolution Test - $MAX_WINDOWS windows"
echo "========================================="
echo "Output: $GCS_DEST"
echo ""

# Step 1: Create dataset and windows
echo "Step 1: Creating test dataset..."
rm -rf $DATASET_PATH
mkdir -p $DATASET_PATH
cp dataset_config.json $DATASET_PATH/config.json

rslearn dataset add_windows \
  --root $DATASET_PATH \
  --group default \
  --name default \
  --utm \
  --resolution $RESOLUTION \
  --src_crs EPSG:4326 \
  --fname $AOI_FILE \
  --start $TIME_RANGE_START \
  --end $TIME_RANGE_END \
  --grid_size 512

INITIAL_COUNT=$(ls -d $DATASET_PATH/windows/default/*/ 2>/dev/null | wc -l)
echo "✅ Windows created: $INITIAL_COUNT"

# Step 2: Filter windows to those overlapping with AOI
echo ""
echo "Step 2: Filtering windows to AOI overlap..."
python3 filter_windows_by_aoi.py "$DATASET_PATH" "$AOI_FILE" 5.0

FILTERED_COUNT=$(ls -d $DATASET_PATH/windows/default/*/ 2>/dev/null | wc -l)
echo "✅ Windows after AOI filter: $FILTERED_COUNT"

# Step 3: Keep only first N windows (from filtered set)
echo ""
echo "Step 3: Limiting to $MAX_WINDOWS windows..."
ALL_WINDOWS=($(ls -d $DATASET_PATH/windows/default/*/ 2>/dev/null | head -$MAX_WINDOWS | xargs -n1 basename))
echo "Selected windows: ${ALL_WINDOWS[@]}"

# Remove extra windows beyond MAX_WINDOWS
for w in $(ls $DATASET_PATH/windows/default/); do
    if [[ ! " ${ALL_WINDOWS[@]} " =~ " $w " ]]; then
        rm -rf "$DATASET_PATH/windows/default/$w"
    fi
done

WINDOW_COUNT=$(ls -d $DATASET_PATH/windows/default/*/ | wc -l)
echo "✅ Kept $WINDOW_COUNT windows"

# Step 4: Prepare (query imagery metadata)
echo ""
echo "Step 4: Querying imagery..."
rslearn dataset prepare \
  --root "$DATASET_PATH" \
  --workers 4 \
  --retry-max-attempts 5 \
  --retry-backoff-seconds 5

echo "✅ Imagery queried"

# Step 5: Materialize (download imagery)
echo ""
echo "Step 5: Downloading imagery..."
rslearn dataset materialize \
  --root "$DATASET_PATH" \
  --workers 4 \
  --no-use-initial-job \
  --retry-max-attempts 5 \
  --retry-backoff-seconds 5

echo "✅ Imagery downloaded"

# Step 6: Compute embeddings
echo ""
echo "Step 6: Computing 10m embeddings..."
export DATASET_PATH="$DATASET_PATH"
rslearn model predict --config model_config.yaml

echo "✅ Embeddings computed"

# Step 7: Check output sizes
echo ""
echo "Step 7: Checking output file sizes..."
for w in "${ALL_WINDOWS[@]}"; do
    tif=$(find "$DATASET_PATH/windows/default/$w/layers/embeddings" -name 'geotiff.tif' 2>/dev/null | head -1)
    if [ -n "$tif" ]; then
        size=$(du -h "$tif" | cut -f1)
        dims=$(gdalinfo "$tif" 2>/dev/null | grep "Size is" || echo "Size unknown")
        echo "  $w: $size - $dims"
    fi
done

# Step 8: Upload to GCS (without parallel composite to avoid download issues)
echo ""
echo "Step 8: Uploading to GCS..."
gcloud config set storage/parallel_composite_upload_enabled False 2>/dev/null
for w in "${ALL_WINDOWS[@]}"; do
    tif=$(find "$DATASET_PATH/windows/default/$w/layers/embeddings" -name 'geotiff.tif' 2>/dev/null | head -1)
    if [ -n "$tif" ]; then
        echo "  Uploading ${w}.tif..."
        gcloud storage cp "$tif" "$GCS_DEST/${w}.tif" --quiet
    fi
done

# Also upload config files for reproducibility
echo "  Uploading config files..."
gcloud storage cp model_config.yaml "$GCS_DEST/model_config.yaml" --quiet
gcloud storage cp dataset_config.json "$GCS_DEST/dataset_config.json" --quiet
gcloud storage cp run_test_10m.sh "$GCS_DEST/run_test_10m.sh" --quiet

echo ""
echo "========================================="
echo "✅ TEST COMPLETE!"
echo "========================================="
echo "Embeddings at: $GCS_DEST"
echo ""
echo "To view in QGIS, download with:"
echo "  gsutil -m cp '$GCS_DEST/*.tif' ./"
echo ""
echo "Expected output dimensions at 10m:"
echo "  - 1024x1024 pixels per window (vs 256x256 at 40m)"
echo "  - ~200MB per file (vs ~12MB at 40m)"

