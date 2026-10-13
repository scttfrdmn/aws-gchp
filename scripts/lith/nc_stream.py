# lith#407 real-tool index-then-stream: netCDF4 opens a GEOS-FP A3dyn file (scattered HDF5 metadata / B-tree walk),
# then reads one whole variable (U: 8 x 72 levels, one zlib chunk per level, ~750 MB compressed) time slice by time
# slice. Prints one JSON line: open_s, read_s, decoded bytes.
import json, sys, time, netCDF4
p, var = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "U")
t0 = time.perf_counter(); d = netCDF4.Dataset(p); v = d[var]; v.set_auto_maskandscale(False); t1 = time.perf_counter()
nb = 0
for t in range(v.shape[0]): nb += v[t].nbytes
t2 = time.perf_counter(); d.close()
print(json.dumps({"open_s": round(t1 - t0, 3), "read_s": round(t2 - t1, 3), "decoded_bytes": nb, "var": var}))
