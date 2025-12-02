#!/bin/bash
# Jamaica South Small - OlmoEarth Embeddings Pipeline (Multi-Temporal)
# Area: ~59 km²
# Time range: Dec 2024 - May 2025 (6 months, dry season)
# Approach: 6 monthly mosaics fed to OlmoEarth (model handles clouds internally)

set -e

# Configuration
export DATASET_PATH=./jamaica_south_small_dataset
TIME_RANGE_START="2024-12-01T00:00:00+00:00"
TIME_RANGE_END="2025-05-31T00:00:00+00:00"
RESOLUTION=10
AOI_FILE="./jamaica_south_small.geojson"

echo "========================================="
echo "Jamaica South Small - OlmoEarth Pipeline"
echo "========================================="
echo "AOI: jamaica_south_small.geojson (~59 km²)"
echo "Time range: Dec 2024 - May 2025 (dry season)"
echo ""
echo "MULTI-TEMPORAL APPROACH (OlmoEarth recommended):"
echo "  - 6 monthly mosaics (one per month)"
echo "  - Model sees all timesteps, handles clouds internally"
echo "  - No median compositing - preserves temporal signal"
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

DISK_AVAIL=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
if [ "$DISK_AVAIL" -lt 150 ]; then
    echo "⚠️  WARNING: Only ${DISK_AVAIL}GB disk space (need ~150GB)"
    echo "   Continue anyway? (y/n)"
    read -r response
    if [ "$response" != "y" ]; then
        exit 1
    fi
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
echo "   (This may take a few minutes...)"
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
echo "   S1: Up to 6 monthly mosaics (Dec-May)"
echo "   (This may take 15-30 minutes...)"

rslearn dataset materialize \
  --root $DATASET_PATH \
  --workers 16 \
  --no-use-initial-job \
  --retry-max-attempts 5 \
  --retry-backoff-seconds 5

# Count materialized layers (should be multiple per window now)
NUM_S2=$(find $DATASET_PATH/windows/default/*/layers/sentinel2_l2a -name 'geotiff.tif' 2>/dev/null | wc -l)
NUM_S1=$(find $DATASET_PATH/windows/default/*/layers/sentinel1 -name 'geotiff.tif' 2>/dev/null | wc -l)
echo "✅ Materialized $NUM_S2 S2 mosaics, $NUM_S1 S1 mosaics"
echo ""

# Step 5: Compute OlmoEarth embeddings
echo "Step 5: Computing OlmoEarth embeddings..."
echo "   Model: OlmoEarth-v1-Base (768 channels)"
echo "   Patch size: 4 (40m spatial resolution)"
echo "   Input: 6 timesteps per modality"
echo "   Cloud handling: Model pools across time, ignores cloudy observations"
echo "   (This will take 2-4 hours...)"
echo ""

# Set DATASET_PATH for model config
export DATASET_PATH=$DATASET_PATH

# Run with GPU
rslearn model predict --config model_config.yaml

NUM_EMBEDDINGS=$(find $DATASET_PATH/windows/default/*/layers/embeddings -name 'geotiff.tif' 2>/dev/null | wc -l)
echo "✅ Generated embeddings for $NUM_EMBEDDINGS windows"
echo ""

# Step 6: Summary
echo "========================================="
echo "✅ Pipeline Complete!"
echo "========================================="
echo ""
echo "Results location:"
echo "  $DATASET_PATH/windows/default/"
echo ""
echo "Embeddings (768-band GeoTIFFs):"
for f in $DATASET_PATH/windows/default/*/layers/embeddings/*/geotiff.tif; do
    if [ -f "$f" ]; then
        SIZE=$(du -h "$f" | cut -f1)
        echo "  - $f ($SIZE)"
    fi
done
echo ""
echo "To download embeddings to local machine:"
echo "  gcloud compute scp --recurse alice-big:~/rslearn/jamaica_rslearn/$DATASET_PATH/windows/default/*/layers/embeddings ./ --zone=us-central1-a"
echo ""
echo "To view in QGIS:"
echo "  qgis $DATASET_PATH/windows/default/*/layers/embeddings/*/geotiff.tif"
echo ""
