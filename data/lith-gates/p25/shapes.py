# lith#216 re-sweep: one function per access shape, each driving a REAL tool against files on a lith mount.
# Usage: python shapes.py <shape> <mountdir>. Prints one JSON line:
#   {"shape", "ok", "tool_bytes" (bytes the tool asked for at its own API level, or null when the
#    library decides internally), "n_opens", "wall_s" (the tool's own work), "detail"}
import json, mmap, os, random, sqlite3, sys, threading, time, zipfile

shape, M = sys.argv[1], sys.argv[2]
R = random.Random(216)
out = {"shape": shape, "ok": False, "tool_bytes": None, "n_opens": 1, "detail": ""}
t0 = time.perf_counter()

if shape == "grib_idx":
    import eccodes
    g = f"{M}/gfs.t00z.pgrb2.0p25.f000"; idx = open(g + ".idx").read().splitlines()
    size = os.path.getsize(g)
    rec = []  # (offset, varname:level) from the .idx sidecar
    for ln in idx:
        p = ln.split(":"); rec.append((int(p[1]), f"{p[3]}:{p[4]}"))
    want = ["TMP:500 mb", "UGRD:500 mb", "VGRD:500 mb", "HGT:500 mb", "TMP:850 mb", "RH:850 mb",
            "TMP:2 m above ground", "RH:2 m above ground", "UGRD:10 m above ground", "VGRD:10 m above ground",
            "PRMSL:mean sea level", "HGT:1000 mb"]
    got, nb, fd = [], 0, os.open(g, os.O_RDONLY)
    for i, (off, name) in enumerate(rec):
        if name in want and name not in [x for x in got]:
            end = rec[i + 1][0] if i + 1 < len(rec) else size
            msg = os.pread(fd, end - off, off); nb += len(msg)
            h = eccodes.codes_new_from_message(msg); eccodes.codes_get_values(h); eccodes.codes_release(h)
            got.append(name)
    os.close(fd)
    out.update(ok=len(got) == len(want), tool_bytes=nb, n_opens=2, detail=f"{len(got)}/{len(want)} fields decoded")

elif shape == "netcdf4_hyperslab":
    import netCDF4
    f = [x for x in sorted(os.listdir(M)) if "M6C01_G19" in x][0]
    d = netCDF4.Dataset(f"{M}/{f}"); v = d["CMI"]; v.set_auto_maskandscale(False)
    ny, nx = v.shape; a = v[ny // 2: ny // 2 + 256, nx // 2: nx // 2 + 256]; d.close()
    out.update(ok=a.shape == (256, 256), tool_bytes=int(a.nbytes), detail=f"{f} CMI {ny}x{nx} slab 256x256 {a.dtype}")

elif shape == "mmap_random":
    p = f"{M}/human_g1k_v37.fasta.gz"; fd = os.open(p, os.O_RDONLY); sz = os.path.getsize(p)
    mm = mmap.mmap(fd, sz, access=mmap.ACCESS_READ); s = 0
    pages = [R.randrange(0, sz // 4096) for _ in range(3000)]
    for pg in pages: s += mm[pg * 4096]
    mm.close(); os.close(fd)
    out.update(ok=True, tool_bytes=3000 * 4096, detail=f"3000 random 4 KiB page touches over {sz} B (checksum {s})")

elif shape == "concurrent_handles":
    g = f"{M}/gfs.t00z.pgrb2.0p25.f000"; sz = os.path.getsize(g); share = sz // 8; tot = [0] * 8
    def rd(i):
        with open(g, "rb") as f:
            f.seek(i * share); left = share if i < 7 else sz - 7 * share
            while left > 0:
                b = f.read(min(1 << 20, left)); tot[i] += len(b); left -= len(b)
                if not b: break
    th = [threading.Thread(target=rd, args=(i,)) for i in range(8)]
    [t.start() for t in th]; [t.join() for t in th]
    out.update(ok=sum(tot) == sz, tool_bytes=sum(tot), n_opens=8, detail="8 handles, contiguous 1/8 shares, 1 MiB reads")

elif shape == "cog_overview_window":
    import rasterio
    from rasterio.windows import Window
    with rasterio.open(f"{M}/cog.tif") as d:
        ov = d.overviews(1); f = ov[-1]
        a = d.read(1, out_shape=(d.height // f, d.width // f))       # served from the smallest overview
        w = d.read(1, window=Window(3000, 3000, 512, 512))             # full-resolution window
    out.update(ok=a.size > 0 and w.shape == (512, 512), tool_bytes=int(a.nbytes + w.nbytes),
               detail=f"overview factors {ov}, read 1/{f} overview + 512x512 window (decoded pixel bytes)")

elif shape == "fits_header_cutout":
    from astropy.io import fits
    with fits.open(f"{M}/image.fits") as h:
        hdr = h[0].header; c = h[0].section[3000:3512, 3000:3512]
    out.update(ok=c.shape == (512, 512), tool_bytes=int(c.nbytes) + 2880,
               detail=f"header ({len(hdr)} cards) + 512x512 float32 cutout via .section")

elif shape == "webdataset_stream":
    import webdataset as wds
    n = 0; nb = 0
    for s in wds.WebDataset(f"file:{M}/shards.tar", shardshuffle=False):
        n += 1; nb += sum(len(v) for k, v in s.items() if isinstance(v, (bytes, bytearray)))
    out.update(ok=n == 400, tool_bytes=os.path.getsize(f"{M}/shards.tar"), detail=f"{n} samples, {nb} payload B")

elif shape == "zip_seek_to_end":
    with zipfile.ZipFile(f"{M}/bundle.zip") as z:
        names = z.namelist(); pick = R.sample(names, 20); nb = sum(len(z.read(n)) for n in pick)
    out.update(ok=len(names) == 500, tool_bytes=nb, detail=f"central directory ({len(names)} entries) + 20 random entries")

elif shape == "tinyfiles_random":
    fs = sorted(os.listdir(f"{M}/tiny")); R.shuffle(fs); nb = 0
    for x in fs:
        with open(f"{M}/tiny/{x}", "rb") as f: nb += len(f.read())
    out.update(ok=len(fs) == 300, tool_bytes=nb, n_opens=300, detail="300 x 8 KiB, random order")

elif shape == "sqlite_random":
    db = sqlite3.connect(f"file:{M}/data.sqlite?immutable=1&mode=ro", uri=True); c = db.cursor(); hits = 0
    for _ in range(1000): hits += len(c.execute("select v from t where k=?", (R.randrange(1000000),)).fetchall())
    rows = sum(len(c.execute("select * from t where id between ? and ?", (a, a + 2000)).fetchall())
               for a in (R.randrange(290000) for _ in range(5)))
    db.close()
    out.update(ok=rows > 0, detail=f"1000 indexed point lookups ({hits} hits) + 5 range scans ({rows} rows)")

elif shape in ("kerchunk_scan", "kerchunk_read"):
    import kerchunk.hdf, fsspec
    f = f"{M}/MERRA2.20190709.A3dyn.05x0625.nc4"; refs = "/scratch/sweep/kerchunk-refs.json"
    if shape == "kerchunk_scan":
        with open(f, "rb") as fh: r = kerchunk.hdf.SingleHdf5ToZarr(fh, f, inline_threshold=0).translate()
        json.dump(r, open(refs, "w")); out.update(ok=len(r["refs"]) > 0, detail=f"{len(r['refs'])} refs from HDF5 metadata walk")
    else:
        import zarr
        m = fsspec.filesystem("reference", fo=refs, remote_protocol="file").get_mapper("")
        a = zarr.open_group(m, mode="r")["U"][3, 30, :, :]
        out.update(ok=a.size > 0, tool_bytes=int(a.nbytes), detail=f"U[time=3, lev=30] {a.shape} via kerchunk refs + zarr")

elif shape == "hemco_timeslice":
    import netCDF4
    files = ["CEDS/v2024-06/2019/CEDS_NH3_0.1x0.1_2019.nc", "GFAS/v2018-09/2019/GFAS_201907.nc",
             "EDGARv43/v2016-11/EDGAR_v43.NH3.SOL.0.1x0.1.nc"]
    nb, nv = 0, 0
    for rel in files:
        d = netCDF4.Dataset(f"{M}/{rel}")
        for name, v in d.variables.items():
            if v.ndim >= 3 and v.dimensions[0].lower().startswith("time"):
                t = min(6, v.shape[0] - 1); a = v[t]; nb += a.nbytes; nv += 1
        d.close()
    out.update(ok=nv > 0, tool_bytes=int(nb), n_opens=3, detail=f"{nv} vars, one time slice each, 3 HEMCO files")
else:
    sys.exit(f"unknown shape {shape}")

out["wall_s"] = round(time.perf_counter() - t0, 3)
print(json.dumps(out))
