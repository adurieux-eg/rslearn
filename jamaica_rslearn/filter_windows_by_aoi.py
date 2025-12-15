#!/usr/bin/env python3
"""Filter rslearn windows to only keep those overlapping with AOI polygon."""

import json
import sys
import shutil
from pathlib import Path

try:
    from shapely.geometry import shape, box
    from shapely.ops import unary_union
    from pyproj import Transformer
    HAS_SHAPELY = True
except ImportError:
    HAS_SHAPELY = False
    print("Warning: shapely/pyproj not installed, using bounding box check only")

def get_window_bounds(window_dir):
    """Read window bounds from metadata.json"""
    metadata_file = window_dir / "metadata.json"
    if not metadata_file.exists():
        return None
    with open(metadata_file) as f:
        meta = json.load(f)
    return meta

def main():
    if len(sys.argv) < 3:
        print("Usage: python filter_windows_by_aoi.py <dataset_path> <aoi_geojson> [min_overlap_pct]")
        sys.exit(1)
    
    dataset_path = Path(sys.argv[1])
    aoi_path = Path(sys.argv[2])
    min_overlap_pct = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
    
    print(f"Loading AOI from {aoi_path}")
    with open(aoi_path) as f:
        aoi_geojson = json.load(f)
    
    if aoi_geojson["type"] == "FeatureCollection":
        features = aoi_geojson["features"]
    elif aoi_geojson["type"] == "Feature":
        features = [aoi_geojson]
    else:
        features = [{"geometry": aoi_geojson}]
    
    if HAS_SHAPELY:
        geometries = []
        for feat in features:
            geom = feat.get("geometry", feat)
            geometries.append(shape(geom))
        aoi_geom = unary_union(geometries)
        print(f"AOI area: {aoi_geom.area:.6f} sq degrees")
    else:
        aoi_geom = None
        aoi_boxes = []
        for feat in features:
            geom = feat.get("geometry", feat)
            if geom["type"] == "Polygon":
                coords = geom["coordinates"][0]
            elif geom["type"] == "MultiPolygon":
                coords = [c for poly in geom["coordinates"] for c in poly[0]]
            else:
                continue
            xs = [c[0] for c in coords]
            ys = [c[1] for c in coords]
            aoi_boxes.append([min(xs), min(ys), max(xs), max(ys)])
    
    windows_dir = dataset_path / "windows" / "default"
    if not windows_dir.exists():
        print(f"Windows directory not found: {windows_dir}")
        sys.exit(1)
    
    total = 0
    kept = 0
    removed = 0
    
    for window_dir in sorted(windows_dir.iterdir()):
        if not window_dir.is_dir():
            continue
        total += 1
        
        meta = get_window_bounds(window_dir)
        if meta is None:
            print(f"  No metadata for {window_dir.name}, keeping")
            kept += 1
            continue
        
        # bounds is a list [x1, y1, x2, y2], projection is a dict
        coords = meta.get("bounds", [])
        projection_info = meta.get("projection", {})
        
        if len(coords) < 4:
            print(f"  Invalid bounds for {window_dir.name}, keeping")
            kept += 1
            continue
        
        # Get CRS and resolution from projection dict
        # Note: y_resolution is often negative (north-up), so use actual values
        if isinstance(projection_info, dict):
            projection = projection_info.get("crs", "")
            x_res = projection_info.get("x_resolution", 10)
            y_res = projection_info.get("y_resolution", -10)
        else:
            projection = str(projection_info)
            x_res = 10
            y_res = -10
        
        # Convert pixel bounds to projection units (pixel * resolution)
        window_minx = coords[0] * x_res
        window_miny = coords[1] * y_res
        window_maxx = coords[2] * x_res
        window_maxy = coords[3] * y_res
        
        # Ensure min < max for box creation
        if window_minx > window_maxx:
            window_minx, window_maxx = window_maxx, window_minx
        if window_miny > window_maxy:
            window_miny, window_maxy = window_maxy, window_miny
        
        if HAS_SHAPELY:
            if "EPSG:4326" not in str(projection):
                epsg = str(projection).split(":")[-1] if "EPSG:" in str(projection) else None
                if epsg:
                    try:
                        transformer = Transformer.from_crs(f"EPSG:{epsg}", "EPSG:4326", always_xy=True)
                        lon_min, lat_min = transformer.transform(window_minx, window_miny)
                        lon_max, lat_max = transformer.transform(window_maxx, window_maxy)
                        window_box = box(lon_min, lat_min, lon_max, lat_max)
                    except Exception as e:
                        print(f"  Transform error for {window_dir.name}: {e}, keeping")
                        kept += 1
                        continue
                else:
                    print(f"  Unknown projection for {window_dir.name}, keeping")
                    kept += 1
                    continue
            else:
                window_box = box(window_minx, window_miny, window_maxx, window_maxy)
            
            intersection = aoi_geom.intersection(window_box)
            overlap_pct = (intersection.area / window_box.area) * 100 if window_box.area > 0 else 0
            
            if overlap_pct >= min_overlap_pct:
                kept += 1
            else:
                print(f"  Removing {window_dir.name} ({overlap_pct:.1f}% overlap < {min_overlap_pct}%)")
                shutil.rmtree(window_dir)
                removed += 1
        else:
            kept += 1
    
    print(f"\n{'='*50}")
    print(f"Total windows: {total}")
    print(f"Kept: {kept}")
    print(f"Removed: {removed}")
    if total > 0:
        print(f"Reduction: {removed/total*100:.1f}%")

if __name__ == "__main__":
    main()

