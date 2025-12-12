#!/bin/bash
# Jamaica Full Coastline - OlmoEarth Embeddings Pipeline
# Area: ~3,628 km² (full seagrass buffer AOI)
# Time range: Dec 2024 - May 2025 (6 months, dry season)
# Approach: 6 monthly S2 mosaics fed to OlmoEarth (model handles clouds internally)

set -e

# Configuration
export DATASET_PATH=./jamaica_full_dataset
TIME_RANGE_START="2024-12-01T00:00:00+00:00"
TIME_RANGE_END="2025-05-31T00:00:00+00:00"
RESOLUTION=10
AOI_FILE="./jamaica_seagrass_aoi.geojson"
GCS_DEST="gs://chris-seagrass/olmo-earth-jamaica-embeddings"

echo "========================================="
echo "Jamaica Full Coastline - OlmoEarth Pipeline"
echo "========================================="
echo "AOI: jamaica_seagrass_aoi.geojson (~3,628 km²)"
echo "Time range: Dec 2024 - May 2025 (dry season)"
echo "GCS destination: $GCS_DEST"
echo ""
echo "MULTI-TEMPORAL APPROACH (OlmoEarth recommended):"
echo "  - Sentinel-2 only (12 bands)"
echo "  - 6 monthly mosaics (one per month)"
echo "  - Model sees all timesteps, handles clouds internally"
echo "  - No median compositing - preserves temporal signal"
echo ""
echo "Estimated: ~500-600 windows, 2-3 days runtime"
echo "========================================="
echo ""

# Step 0: Verify prerequisites
echo "Step 0: Checking prerequisites..."
if [ ! -f "$AOI_FILE" ]; then
    echo "❌ ERROR: AOI file not found: $AOI_FILE"
    exit 1
fi

if ! python -c "import rslearn" 2>/dev/null; then
    echo "❌ ERROR: rslearn not installed or venv not activated"
    echo "   Run: source ~/rslearn/venv/bin/activate"
    exit 1
fi

if ! gsutil ls $GCS_DEST &>/dev/null; then
    echo "Creating GCS destination: $GCS_DEST"
    gsutil mb -p seagrass-project $GCS_DEST 2>/dev/null || true
fi

DISK_AVAIL=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
if [ "$DISK_AVAIL" -lt 100 ]; then
    echo "⚠️  WARNING: Only ${DISK_AVAIL}GB disk space available"
    echo "   Embeddings will be uploaded to GCS and deleted locally"
fi

echo "✅ Prerequisites OK"
echo ""

# Step 1: Create dataset directory
echo "Step 1: Creating dataset structure..."
mkdir -p $DATASET_PATH
cp dataset_config.json $DATASET_PATH/config.json
echo "✅ Dataset directory created"
echo ""

# Step 2: Add windows from GeoJSON
echo "Step 2: Adding windows from AOI..."
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
  --grid_size 1024

NUM_WINDOWS=$(find $DATASET_PATH/windows/default/*/metadata.json 2>/dev/null | wc -l)
echo "✅ Created $NUM_WINDOWS window(s)"
echo ""

# Step 3: Prepare data (query STAC catalogs)
echo "Step 3: Querying Planetary Computer for imagery..."
echo "   Looking for 6 monthly mosaics per sensor..."
echo "   (This may take several minutes for large AOI...)"
rslearn dataset prepare \
  --root $DATASET_PATH \
  --workers 16 \
  --retry-max-attempts 5 \
  --retry-backoff-seconds 5

echo "✅ Data preparation complete"
echo ""

# Step 4: Materialize satellite imagery
echo "Step 4: Downloading monthly mosaics..."
echo "   S2: Up to 6 monthly mosaics (Dec-May)"
echo "   (This may take 1-2 hours for full AOI...)"

rslearn dataset materialize \
  --root $DATASET_PATH \
  --workers 16 \
  --no-use-initial-job \
  --retry-max-attempts 5 \
  --retry-backoff-seconds 5

NUM_S2=$(find $DATASET_PATH/windows/default/*/layers/sentinel2_l2a -name 'geotiff.tif' 2>/dev/null | wc -l)
echo "✅ Materialized $NUM_S2 S2 mosaics"
echo ""

# Step 5: Compute OlmoEarth embeddings
echo "Step 5: Computing OlmoEarth embeddings..."
echo "   Model: OlmoEarth-v1-Base (768 channels)"
echo "   Patch size: 4 (40m spatial resolution)"
echo "   Input: 6 timesteps per modality"
echo "   Cloud handling: Model pools across time, ignores cloudy observations"
echo "   (This will take 2-3 days for full AOI...)"
echo ""

export DATASET_PATH=$DATASET_PATH
rslearn model predict --config model_config.yaml

NUM_EMBEDDINGS=$(find $DATASET_PATH/windows/default/*/layers/embeddings -name 'geotiff.tif' 2>/dev/null | wc -l)
echo "✅ Generated embeddings for $NUM_EMBEDDINGS windows"
echo ""

# Step 6: Upload embeddings to GCS and cleanup local files
echo "Step 6: Uploading embeddings to GCS and cleaning up..."
echo "   Destination: $GCS_DEST"

UPLOAD_COUNT=0
UPLOAD_ERRORS=0

for window_dir in $DATASET_PATH/windows/default/*/; do
    window_name=$(basename "$window_dir")
    emb_dir="$window_dir/layers/embeddings"
    
    if [ -d "$emb_dir" ]; then
        for hash_dir in "$emb_dir"/*/; do
            if [ -d "$hash_dir" ]; then
                tif_file="$hash_dir/geotiff.tif"
                if [ -f "$tif_file" ]; then
                    dest_path="$GCS_DEST/$window_name/geotiff.tif"
                    
                    echo "  Uploading $window_name..."
                    if gsutil -q cp "$tif_file" "$dest_path"; then
                        UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
                        rm -rf "$emb_dir"
                        echo "    ✅ Uploaded and deleted local copy"
                    else
                        UPLOAD_ERRORS=$((UPLOAD_ERRORS + 1))
                        echo "    ❌ Upload failed, keeping local copy"
                    fi
                fi
            fi
        done
    fi
done

echo ""
echo "✅ Uploaded $UPLOAD_COUNT embeddings to GCS"
if [ "$UPLOAD_ERRORS" -gt 0 ]; then
    echo "⚠️  $UPLOAD_ERRORS uploads failed - local copies retained"
fi
echo ""

# Step 7: Summary
echo "========================================="
echo "✅ Pipeline Complete!"
echo "========================================="
echo ""
echo "Embeddings saved to:"
echo "  $GCS_DEST"
echo ""
echo "To list embeddings:"
echo "  gsutil ls $GCS_DEST/"
echo ""
echo "To download all embeddings:"
echo "  gsutil -m cp -r $GCS_DEST ./"
echo ""
echo "Total windows processed: $NUM_WINDOWS"
echo "Embeddings uploaded: $UPLOAD_COUNT"
echo ""
