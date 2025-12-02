# Jamaica South Small - OlmoEarth Embeddings (Multi-Temporal)

## Approach

This pipeline uses the **OlmoEarth-recommended multi-temporal approach**:

> "Clouds -- we recommend inputting 6-12 monthly images. If a subset of images are cloudy at a particular spot, the model will still be able to make use of the other images."

Instead of creating a single median composite, we:
1. Create **6 monthly mosaics** (one per month, Dec-May)
2. Feed **all 6 timesteps** to OlmoEarth
3. The model **internally pools across time**, learning to ignore cloudy observations

This preserves temporal information and lets the model handle clouds intelligently.

---

## Quick Start

### 1. On VM: Pull the latest changes

```bash
# On local machine: commit and push
cd /Users/alicedurieux/Documents/GitHub/rslearn
git add jamaica_rslearn/
git commit -m "Switch to multi-temporal approach"
git push origin jamaica

# On VM: pull the changes
cd ~/rslearn
git pull origin jamaica
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
**Time Range:** December 1, 2024 - May 31, 2025 (dry season)  
**Resolution:** 10m/pixel  

**Sentinel-2:**
- 12 bands (B01-B12)
- **6 monthly mosaics** (one per 30-day period)
- Sorted by cloud cover within each month
- Harmonized across processing baselines

**Sentinel-1:**
- 2 bands (VV, VH)
- **6 monthly mosaics** (one per 30-day period)
- IW (Interferometric Wide) mode

**OlmoEarth Model:**
- Version: v1-Base
- Embedding size: 768 channels
- Patch size: 4 (40m tokens)
- **Multi-temporal input:** 6 timesteps
- **Temporal pooling:** Model averages across time internally

---

## Why Multi-Temporal?

| Approach | Pros | Cons |
|----------|------|------|
| **Median Composite** | Simple, removes clouds | Loses temporal info, can blur features |
| **Multi-Temporal (this)** | Model learns cloud handling, preserves phenology | Slightly more data to download |

The OlmoEarth model was trained on multi-temporal data and has learned to:
- Recognize cloudy observations
- Down-weight unreliable pixels
- Combine information across time intelligently

---

## Expected Runtime

- Data query: 2-5 min
- Download 6 monthly mosaics: 15-30 min
- Embedding generation: 2-4 hours
- **Total: ~2.5-5 hours**

---

## Expected Costs

- Compute: 3-4 hrs × $0.75/hr = **$2.25-$3.00**
- Storage: ~150 GB × $0.04/GB/month = **$6/month**
- **Total: ~$8-9** first month

---

## Output Structure

```
jamaica_south_small_dataset/
└── windows/
    └── default/
        └── default_*/
            └── layers/
                ├── sentinel2_l2a/
                │   ├── 0/geotiff.tif  (Dec mosaic)
                │   ├── 1/geotiff.tif  (Jan mosaic)
                │   ├── 2/geotiff.tif  (Feb mosaic)
                │   ├── 3/geotiff.tif  (Mar mosaic)
                │   ├── 4/geotiff.tif  (Apr mosaic)
                │   └── 5/geotiff.tif  (May mosaic)
                ├── sentinel1/
                │   └── (same structure)
                └── embeddings/
                    └── geotiff.tif  ← YOUR EMBEDDINGS (single output)
```

Each embedding GeoTIFF:
- **768 bands** (float32)
- **Same spatial extent as input**
- **1/4 spatial resolution** (40m pixels from 10m input)
- **Single timestep** (model pools across the 6 input months)

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
- Some months may have no cloud-free imagery - this is OK, model handles it

**Out of memory:**
- Reduce batch_size in model_config.yaml (4 → 2)
- Reduce patch_size (64 → 32)

**Disk full:**
- Increase disk size to 250 GB
- Multi-temporal needs more space than composite approach

**Missing timesteps:**
- Some months may not have imagery - model will use available timesteps
- Check `rslearn dataset prepare` output for warnings

---

## Next Steps

After embeddings are generated:
1. Download to local machine
2. Visualize in QGIS (first 3 bands as RGB)
3. Extract features at training point locations
4. Train seagrass classifier
5. Apply to full Jamaica coast!
