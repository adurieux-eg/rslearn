# Jamaica South Small - OlmoEarth Embeddings

## Quick Start

### 1. On VM: Pull the latest changes

Since you're working in your forked rslearn repo, you'll need to commit and push these files first.

```bash
# On local machine: commit and push
cd /Users/alicedurieux/Documents/GitHub/rslearn
git add jamaica_rslearn/
git commit -m "Add Jamaica test pipeline configs"
git push origin main  # or your branch name

# On VM: pull the changes
cd ~/rslearn
git pull origin main  # or your branch name
```

### 2. Navigate to the directory and activate venv

```bash
cd ~/rslearn/jamaica_rslearn
source ~/rslearn/venv/bin/activate
```

### 3. Run the pipeline

```bash
chmod +x run_pipeline.sh
./run_pipeline.sh
```

---

## Configuration Details

**Area:** ~59 km² (jamaica_south_small.geojson)  
**Time Range:** November 1, 2024 - November 1, 2025  
**Resolution:** 10m/pixel  

**Sentinel-2:**
- 12 bands (B01-B12)
- MEDIAN composite of up to 24 clearest images
- Sorted by cloud cover
- Harmonized across processing baselines

**Sentinel-1:**
- 2 bands (VV, VH)
- MEDIAN composite of up to 24 images
- IW (Interferometric Wide) mode

**OlmoEarth Model:**
- Version: v1-Base
- Embedding size: 768 channels
- Patch size: 4 (40m tokens)
- Sliding window: 64×64 with 50% overlap

---

## Expected Runtime

- Data query: 2-5 min
- Download & composite: 10-20 min
- Embedding generation: 2-4 hours
- **Total: ~2.5-4.5 hours**

---

## Expected Costs

- Compute: 3 hrs × $0.75/hr = **$2.25**
- Storage: 120 GB × $0.04/GB/month = **$4.80/month**
- **Total: ~$7** first month

---

## Output Structure

```
jamaica_south_small_dataset/
└── windows/
    └── default/
        └── default_*/
            └── layers/
                ├── sentinel2_l2a/
                │   └── B01_..._B12/
                │       └── geotiff.tif
                ├── sentinel1/
                │   └── vv_vh/
                │       └── geotiff.tif
                └── embeddings/
                    └── 768_bands/
                        └── geotiff.tif  ← YOUR EMBEDDINGS!
```

Each embedding GeoTIFF:
- **768 bands** (float32)
- **Same spatial extent as input**
- **1/4 spatial resolution** (40m pixels from 10m input)
- **~100-120 GB per tile**

---

## Download Results

From your local machine:
```bash
gcloud compute scp --recurse \
  alice-big:~/rslearn/jamaica_rslearn/jamaica_south_small_dataset/windows/default/*/layers/embeddings \
  ./ --zone=us-central1-a
```

---

## Running in a Screen Session (Recommended)

To avoid disconnection issues:

```bash
# Start screen session
screen -S jamaica_embeddings

# Run pipeline
./run_pipeline.sh

# Detach: Press Ctrl+A then D
# Reconnect later: screen -r jamaica_embeddings
```

---

## Troubleshooting

**"No valid pixels" / Empty images:**
- Check AOI is over water (not land)
- Expand time range if needed
- Check Planetary Computer availability

**Out of memory:**
- Reduce batch_size in model_config.yaml (4 → 2)
- Reduce patch_size (64 → 32)

**Disk full:**
- Increase disk size to 250 GB
- Or process in smaller batches

---

## Next Steps

After embeddings are generated:
1. Download to local machine
2. Visualize in QGIS
3. Extract features at training point locations
4. Train seagrass classifier
5. Apply to full Jamaica coast!

