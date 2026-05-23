# Software Stack Versioning

## S3 Structure

```
s3://gchp-shared-storage-us-east-2/stacks/
└── gcc12.3-ompi4.1.7-gchp14.7.1/    # Version-specific stack
    ├── gcc-12.3.0/
    ├── openmpi-4.1.7/
    ├── hdf5-1.14.6/
    ├── netcdf-c-4.10.0/
    ├── netcdf-fortran-4.6.2/
    ├── esmf-8.9.1/
    ├── gchp-14.7.1/
    ├── manifest.yaml
    └── gchp-env.sh
```

## Naming Convention

**Format:** `gcc{VERSION}-ompi{VERSION}-gchp{VERSION}`

Examples:
- `gcc12.3-ompi4.1.7-gchp14.7.1` - GCC 12, OpenMPI 4.1.7, GCHP 14.7.1
- `gcc12.3-ompi5.0-gchp14.7.1` - Same but testing OpenMPI 5

## FSx Configuration

```yaml
SharedStorage:
  - Name: software
    StorageType: FsxLustre
    MountDir: /fsx
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
      ImportPath: s3://gchp-shared-storage-us-east-2/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/
      ExportPath: s3://gchp-shared-storage-us-east-2/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/
      AutoImportPolicy: NEW_CHANGED
```

## Usage

**Load environment:**
```bash
source /fsx/gchp-env.sh
```

**Switch versions:** Change `ImportPath` in cluster config and recreate cluster.

## Benefits

- Multiple versions coexist in S3
- Clear version documentation  
- Easy rollback (change ImportPath)
- S3-backed (survives cluster deletion)
