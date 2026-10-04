/* slabread — read one HDF5 hyperslab the way MAPL/ExtData does, and time it.
 *
 * WHY THIS EXISTS: h5dump can take the same subset (-d/-s/-c) but spends ~12 s of
 * user CPU on a 3.3 MB slab walking elements through its formatter, which buries
 * the I/O time we are trying to measure. A direct H5Dread into one contiguous
 * buffer costs inflate and nothing else, so wall time is I/O + decompression —
 * which is exactly what GriddedIO's collective_prefetch_data pays.
 *
 * Links the GCHP stack's own HDF5 1.14.0, so the access pattern is the authentic
 * one (same chunk cache, same filter pipeline, same POSIX read sizes).
 *
 *   slabread FILE DSET START COUNT
 *   slabread A3dyn.nc /U 0,0,0,0 1,72,721,1152
 *
 * Prints one line: open_s read_s bytes checksum
 * The checksum is there so a lith read and an FSx read can be proven identical.
 */
#include <hdf5.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

/* parse "1,72,721,1152" into out[]; returns rank */
static int parse_dims(const char *s, hsize_t *out, int max) {
    char buf[256], *tok, *save = NULL;
    int n = 0;
    snprintf(buf, sizeof buf, "%s", s);
    for (tok = strtok_r(buf, ",", &save); tok && n < max; tok = strtok_r(NULL, ",", &save))
        out[n++] = (hsize_t)strtoull(tok, NULL, 10);
    return n;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s FILE DSET START COUNT\n", argv[0]);
        return 2;
    }
    hsize_t start[H5S_MAX_RANK], count[H5S_MAX_RANK];
    int rank  = parse_dims(argv[3], start, H5S_MAX_RANK);
    int rankc = parse_dims(argv[4], count, H5S_MAX_RANK);
    if (rank != rankc || rank == 0) {
        fprintf(stderr, "START and COUNT must have the same nonzero rank\n");
        return 2;
    }

    double t0 = now();
    hid_t f = H5Fopen(argv[1], H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) { fprintf(stderr, "H5Fopen failed: %s\n", argv[1]); return 1; }
    hid_t d = H5Dopen2(f, argv[2], H5P_DEFAULT);
    if (d < 0) { fprintf(stderr, "H5Dopen failed: %s\n", argv[2]); return 1; }
    double t_open = now() - t0;

    hid_t fspace = H5Dget_space(d);
    if (H5Sselect_hyperslab(fspace, H5S_SELECT_SET, start, NULL, count, NULL) < 0) {
        fprintf(stderr, "hyperslab selection failed\n"); return 1;
    }
    hid_t mspace = H5Screate_simple(rank, count, NULL);

    /* read as float: every gcgrid met variable is H5T_IEEE_F32LE */
    hsize_t nelem = 1;
    for (int i = 0; i < rank; i++) nelem *= count[i];
    float *buf = malloc(nelem * sizeof(float));
    if (!buf) { fprintf(stderr, "malloc of %llu floats failed\n",
                        (unsigned long long)nelem); return 1; }

    t0 = now();
    if (H5Dread(d, H5T_NATIVE_FLOAT, mspace, fspace, H5P_DEFAULT, buf) < 0) {
        fprintf(stderr, "H5Dread failed\n"); return 1;
    }
    double t_read = now() - t0;

    /* order-sensitive checksum: proves two backends returned the same bytes */
    unsigned long long ck = 1469598103934665603ULL;
    const unsigned char *p = (const unsigned char *)buf;
    for (size_t i = 0; i < nelem * sizeof(float); i++) {
        ck ^= p[i];
        ck *= 1099511628211ULL;
    }

    printf("%.3f %.3f %llu %016llx\n", t_open, t_read,
           (unsigned long long)(nelem * sizeof(float)), ck);

    free(buf);
    H5Sclose(mspace); H5Sclose(fspace); H5Dclose(d); H5Fclose(f);
    return 0;
}
