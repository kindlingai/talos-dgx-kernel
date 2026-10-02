# dispram

`dispramd` lends the GB10 display carveout, the 2046 MiB that firmware reserves for the
display, to CUDA processes as device memory. It runs on every node as the `dispramd`
Talos extension service from the `dispram` system extension.

## How it works

- The RM reports the carveout as `DISPLAY_FRM` through
  `NV2080_CTRL_CMD_FB_GET_CARVEOUT_REGION_INFO`. On GB10 the driver allocates scanout
  memory only on SoCs with `PDB_PROP_GPU_IS_SOC_SDM` (GB20B, GB20C), so the range stays
  free, and the GPU's SMMU maps it directly.
- For each request, `dispramd` wraps a 2 MiB-granular slice in an
  `NV01_MEMORY_LIST_SYSTEM` object and exports it as a file descriptor with
  `NV0000_CTRL_CMD_OS_UNIX_EXPORT_OBJECT_TO_FD`. Creating memory lists requires root;
  importing the descriptor requires no privilege.
- The descriptor travels over `/run/dispram/dispram.sock` (`SOCK_SEQPACKET`,
  `SCM_RIGHTS`). The client imports it with `cuMemImportFromShareableHandle` (POSIX fd)
  or `cudaImportExternalMemory` (opaque fd) and maps it like any other device memory.
- A connection's slices return to the free list when it closes, normally at process
  exit.

`dispramd.c` compiles against the
[open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules) headers at
the driver release in `docker-bake.hcl` (`NVIDIA_VERSION`), and runs when
`/proc/driver/nvidia/version` reports that release.

## Protocol

One JSON object per message; every request carries `"key": "kindlingai_1"`.

| Request                     | Reply                                                                  |
| --------------------------- | ---------------------------------------------------------------------- |
| `{"op": "info"}`            | `{"base", "size", "free", "largest"}`                                  |
| `{"op": "alloc", "size": N}`| `{"ok": true, "base", "size"}` with the descriptor attached, or `{"ok": false, "error"}` |

The protocol is the one the `kindling-spark-os` dispram clients speak: its Python client
(`dispram/python/dispram.py`) and vLLM plugin (`dispram_vllm.py`) work with this daemon
unchanged.

## Using it from Kubernetes

Mount the socket directory into the pod and put the client on the Python path:

```yaml
volumes:
  - name: dispram
    hostPath:
      path: /run/dispram
      type: Directory
containers:
  - name: vllm
    volumeMounts:
      - name: dispram
        mountPath: /run/dispram
```

Under tensor parallelism, give every rank access to the socket, because vLLM sizes the
KV cache to the smallest budget across ranks.

Check the service on a node:

```sh
talosctl --nodes <node> service ext-dispramd
talosctl --nodes <node> logs ext-dispramd   # "DISPLAY_FRM 0x280200000 + 2046 MiB"
```

## Prior work

The forum post
[DeepSeek V4.1 Flash for 2x DGX Spark … +2GB free RAM unlock for all GB10s](https://forums.developer.nvidia.com/t/deepseek-v4-1-flash-for-2x-dgx-spark-exl3-3bpw-3m-kv-cache-c6-new-2gb-free-ram-unlock-for-all-gb10s/383583)
first showed that CUDA can use this memory on headless GB10s, through a DRM display
buffer. `dispramd` is the C form of the `kindling-spark-os` dispram daemon, which reaches
the same memory through RM memory-list objects.

## License

AGPL-3.0 (`LICENSE`). The NVIDIA headers it compiles against are MIT.
