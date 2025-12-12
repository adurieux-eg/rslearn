# Jamaica Full Coastline - OlmoEarth Embeddings

## Overview

Pipeline to generate OlmoEarth embeddings for the entire Jamaica seagrass AOI (~3,628 km²).

**Key Features:**
- Multi-temporal approach (6 monthly mosaics)
- Automatic upload to GCS after each batch
- Local cleanup to manage disk space
- Handles ~500-600 windows over 2-3 days

---

## Quick Start

### 1. Copy AOI file to VM

After pushing to git, copy the new AOI file to your VM:

```bash
# From your LOCAL machine:
gcloud compute scp \
  ~/Documents/GitHub/seagrass-mapping-pm/alice_notebooks/olmo/jamaica_embeddings/jamaica_seagrass_aoi.geojson \
  alice-big:~/rslearn/jamaica_rslearn/ \
  --zone=us-central1-a
```

Or, if you've pushed to git:

```bash
# On the VM:
cd ~/rslearn/jamaica_rslearn

# Download from seagrass-mapping repo
curl -L -o jamaica_seagrass_aoi.geojson \
  "https://raw.githubusercontent.com/earth-genome/seagrass-mapping/alice-olmo/alice_notebooks/olmo/jamaica_embeddings/jamaica_seagrass_aoi.geojson"
```

### 2. On VM: Pull latest rslearn changes

```bash
cd ~/rslearn
git pull origin jamaica

cd jamaica_rslearn
source ~/rslearn/venv/bin/activate
```

### 3. Authenticate GCS (if needed)

```bash
gcloud auth login
```

### 4. Run in a screen session

```bash
screen -S jamaica_full

chmod +x run_pipeline.sh
./run_pipeline.sh

# Detach: Ctrl+A then D
# Reconnect: screen -r jamaica_full
```

---

## Configuration

| Parameter | Value |
|-----------|-------|
| **AOI** | `jamaica_seagrass_aoi.geojson` (~3,628 km²) |
| **Time Range** | Dec 2024 - May 2025 (6 months) |
| **Resolution** | 10m/pixel |
| **Windows** | ~500-600 (1024×1024 pixels each) |
| **GCS Destination** | `gs://chris-seagrass/olmo-earth-jamaica-embeddings` |

---

## Pipeline Steps

1. **Add windows** - Tiles the AOI into 1024×1024 windows
2. **Prepare** - Queries Planetary Computer for Sentinel-2 imagery
3. **Materialize** - Downloads 6 monthly mosaics per window
4. **Predict** - Runs OlmoEarth model to generate embeddings
5. **Upload** - Copies embeddings to GCS
6. **Cleanup** - Deletes local embeddings to save disk space

---

## Estimated Runtime & Cost

| Stage | Time | Notes |
|-------|------|-------|
| Add windows | 5 min | Creates ~500-600 tiles |
| Prepare | 30 min | Query STAC catalog |
| Materialize | 2-4 hours | Download S2 data |
| Predict | 2-3 days | GPU inference |
| Upload | 30 min | To GCS |

**Costs:**
- Compute: ~72 hrs × $0.35/hr = **~$25**
- Storage (GCS): ~150 GB × $0.02/GB = **~$3/month**

---

## Output

Embeddings are uploaded to GCS with this structure:

```
gs://chris-seagrass/olmo-earth-jamaica-embeddings/
├── default_23552_-196608/
│   └── geotiff.tif  (768 bands, float32)
├── default_23552_-197632/
│   └── geotiff.tif
├── default_24576_-196608/
│   └── geotiff.tif
└── ... (~500-600 windows)
```

Each GeoTIFF:
- **768 bands** (embedding dimensions)
- **256×256 pixels** (40m resolution)
- **Georeferenced** (UTM projection)

---

## Access Results

```bash
# List all embeddings
gsutil ls gs://chris-seagrass/olmo-earth-jamaica-embeddings/

# Download all to local
gsutil -m cp -r gs://chris-seagrass/olmo-earth-jamaica-embeddings/ ./jamaica_embeddings/

# Download single window
gsutil cp gs://chris-seagrass/olmo-earth-jamaica-embeddings/default_23552_-196608/geotiff.tif ./
```

---

## Monitoring Progress

```bash
# Reconnect to screen
screen -r jamaica_full

# Check GPU usage (in another terminal)
nvidia-smi

# Check uploaded files
gsutil ls gs://chris-seagrass/olmo-earth-jamaica-embeddings/ | wc -l
```

---

## Troubleshooting

**Pipeline stops overnight:**
- Use `screen` session (see Quick Start)
- If disconnected: `screen -r jamaica_full`

**GCS permission denied:**
- Run `gcloud auth login` on VM

**Disk full:**
- Pipeline auto-cleans after upload
- If still full: `rm -rf $DATASET_PATH/windows/default/*/layers/sentinel2_l2a`

**GPU out of memory:**
- Edit `model_config.yaml`: reduce `batch_size` to 2

---

## Next Steps

After pipeline completes:
1. Download embeddings from GCS
2. Intersect with training points
3. Train seagrass classifier
4. Generate full Jamaica seagrass map
