# RoboTwin Parallel Data Collection

Multi-machine, multi-GPU parallel data collection infrastructure for [RoboTwin](https://github.com/RoboTwin-Platform/RoboTwin). Designed for large-scale episode generation across 20+ machines with 8 GPUs each.

## Architecture

The pipeline has two phases:

1. **Phase 1 (Seed Collection)** — Each machine runs a subset of tasks, collecting valid seeds through simulation. Multiple workers per GPU explore different seed ranges in parallel.

2. **Phase 2 (Rendering)** — A shared queue distributes episode batches across all machines dynamically. Workers claim batches via `fcntl.flock`, render episodes, and mark them done. This provides automatic load balancing — faster machines simply claim more work.

```
┌─────────────────────────────────────────────────────────┐
│                    Shared Storage (NFS/Lustre)           │
│  save_path/                                             │
│  ├── _queue/          # Phase 2 task queues (JSON)      │
│  ├── _barrier/        # Cross-node synchronization      │
│  ├── _logs/           # Per-node logs                   │
│  └── <task_name>/<config>/                              │
│      ├── seed.txt           # Valid seeds               │
│      ├── _traj_data/        # Phase 1 trajectories      │
│      ├── data/              # episode*.hdf5             │
│      ├── video/             # episode*.mp4              │
│      ├── _scene_info/       # Per-episode JSON          │
│      └── instructions/      # Generated text            │
└─────────────────────────────────────────────────────────┘
```

## Quick Start

### Full Pipeline (All Phases)

Run the same command on every node — differentiate by `RANK`:

```bash
# On each machine (RANK=0..19):
RANK=0 bash multi_proc_scripts/launch_all.sh
```

This runs Phase 1 → barrier sync → queue init → Phase 2 → finalize automatically.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RANK` | (required) | Node ID (0-indexed) |
| `NUM_MACHINES` | 20 | Total number of nodes |
| `NUM_GPUS` | 8 | GPUs per node |
| `NUM_WORKER_PER_GPU` | 4 | Workers per GPU (Phase 1); 1 recommended for Phase 2 |
| `TASK_CONFIG` | demo_clean | Config file name in `task_config/` |
| `BATCH_SIZE` | 5 | Episodes per queue batch (Phase 2) |
| `TASK_FILTER` | (all) | Comma-separated task names to include |
| `TASK_EXCLUDE` | (empty) | Comma-separated task names to exclude |
| `CLUSTER_ID` | (empty) | Isolate barriers when multiple clusters share storage |

### Run Phases Separately

```bash
# Phase 1 only
RANK=0 bash multi_proc_scripts/launch_phase1.sh

# After all nodes finish Phase 1, init queue (run on one node):
python multi_proc_scripts/init_queue.py --task-config demo_clean --batch-size 5

# Phase 2 only
RANK=0 bash multi_proc_scripts/launch_phase2.sh

# After all nodes finish Phase 2, generate instructions:
bash multi_proc_scripts/finalize_tasks.sh demo_clean
```

### Single-Task Reverse Rendering

For rendering a specific episode range (e.g., episodes 5999→4000):

```bash
# Single GPU
bash multi_proc_scripts/run_reverse.sh hanging_mug demo_clean --start 5999 --end 4000 --gpu 0

# Multi-GPU (8 GPUs)
bash multi_proc_scripts/run_reverse_multi.sh hanging_mug demo_clean --start 5999 --end 4000 --num-gpus 8
```

## Monitoring

```bash
# Overall progress (counts video files)
python multi_proc_scripts/monitor_progress.py --task-config demo_clean

# Live refresh every 30s
python multi_proc_scripts/monitor_progress.py --watch

# List all tasks sorted by completion
python multi_proc_scripts/monitor_progress.py --list --sort asc

# Filter specific tasks
python multi_proc_scripts/monitor_progress.py --task hanging_mug,lift_pot
```

## File Overview

```
multi_proc_scripts/
├── launch_all.sh           # Full pipeline entry point (Phase 1 + 2 + finalize)
├── launch_phase1.sh        # Phase 1 cluster entry point
├── launch_phase2.sh        # Phase 2 cluster entry point
├── run_phase1.sh           # Phase 1 per-node orchestrator
├── run_phase2.sh           # Phase 2 per-node orchestrator
├── phase1_worker.py        # Phase 1 single-worker process
├── phase2_worker.py        # Phase 2 single-worker process (queue consumer)
├── init_queue.py           # Generate Phase 2 queue files
├── merge_seeds.py          # Merge Phase 1 worker outputs
├── finalize_tasks.sh       # Post-Phase 2: merge scene_info + gen instructions
├── gen_instructions.sh     # Per-task instruction generation with validation
├── gen_all_instructions.sh # Batch instruction generation for all tasks
├── run_reverse.sh          # Single-GPU reverse-order rendering
├── run_reverse_multi.sh    # Multi-GPU reverse-order rendering
├── monitor_progress.py     # Progress monitoring (file-count based)
├── patch_curobo_warp.py    # CuRobo kernel patch for Hopper GPUs
├── run_all.sh              # Legacy multi-task runner
└── LESSONS_LEARNED.md      # Operational lessons from production runs

script/
└── collect_data.py         # Core data collection (Phase 1/2 modes)

envs/robot/
└── planner.py              # CuRobo motion planner (Hopper GPU fix)

envs/utils/
└── pkl2hdf5.py             # PKL→HDF5 conversion (cache cleanup)
```

## Key Design Decisions

### Concurrency Safety

| Resource | Strategy |
|----------|----------|
| Seed collection | Each worker uses independent seed range + output directory |
| Trajectory data | Single-process merge after Phase 1 |
| HDF5 files | Batch episodes don't overlap; existence check before write |
| Scene info | Independent per-episode files, merged at finalize |
| Queue files | `fcntl.flock` with `LOCK_NB` for non-blocking claims |

### Hopper GPU (H100/H200) Compatibility

CuRobo's LBFGS fused CUDA kernel causes illegal instruction errors on sm_90 (Hopper). The fix in `planner.py` disables only the problematic kernel while keeping CUDA graphs enabled:

```python
# After MotionGen creation:
self._disable_lbfgs_cuda_kernel(self.motion_gen)
```

If CuRobo was compiled with PTX fallback (`sm_89+PTX`), recompile with native `sm_90` for 10-15x speedup. Use `patch_curobo_warp.py` to patch the warp kernel compilation.

### Idempotent Rendering

Every worker checks for existing `episode{N}.hdf5` before rendering. This means:
- Crashed workers can be restarted without data loss
- Stale batches reclaimed by other workers won't duplicate work
- You can safely re-run any phase at any time

## Task Configuration

Edit `task_config/demo_clean.yml`:

```yaml
episode_num: 4000        # Episodes per task
save_path: /mnt/data/clean  # Shared storage path
# ... other settings
```

The 50 supported tasks are defined in `init_queue.py`.

## Docker Setup

Each node runs a Docker container with NVIDIA GPU passthrough. The container needs access to:
- The RoboTwin code directory (mounted to `/mnt/robotwin`)
- The shared data storage filesystem
- All NVIDIA GPU devices

### Container Launch

```bash
sudo docker run --gpus all \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -v /home/ubuntu/proj/robotwin/RoboTwin:/mnt/robotwin \
    -v /media/ubuntu/T7/lx/:/media/ubuntu/T7/lx/ \
    -it <your-image> \
    bash
```

Replace paths as needed:
- First `-v`: mount RoboTwin code to `/mnt/robotwin` (must match CuRobo config paths)
- Second `-v`: mount shared data storage (where `save_path` in task config points to)

### Running Inside Container

```bash
cd /mnt/robotwin

# Single machine, 1 GPU, 2 workers/GPU, batch_size=5
RANK=0 NUM_MACHINES=1 NUM_WORKER_PER_GPU=2 NUM_GPUS=1 BATCH_SIZE=5 \
    bash multi_proc_scripts/launch_all.sh

# Single machine, 8 GPUs, full pipeline
RANK=0 NUM_MACHINES=1 NUM_GPUS=8 NUM_WORKER_PER_GPU=2 BATCH_SIZE=5 \
    bash multi_proc_scripts/launch_all.sh

# Multi-machine (20 nodes), each node runs with its own RANK
RANK=0 NUM_MACHINES=20 NUM_GPUS=8 NUM_WORKER_PER_GPU=4 BATCH_SIZE=5 \
    bash multi_proc_scripts/launch_all.sh

# Filter specific tasks
RANK=0 NUM_MACHINES=1 NUM_GPUS=1 TASK_FILTER=hanging_mug,lift_pot \
    bash multi_proc_scripts/launch_all.sh

# Exclude tasks
RANK=0 NUM_MACHINES=1 NUM_GPUS=8 TASK_EXCLUDE=open_laptop,scan_object \
    bash multi_proc_scripts/launch_all.sh
```

### Multi-Machine Deployment

On a 20-machine cluster, each node runs the same Docker image with a different `RANK`:

```bash
# Node 0
sudo docker run --gpus all \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -v /path/to/RoboTwin:/mnt/robotwin \
    -v /mnt/shared-storage:/mnt/shared-storage \
    -it <your-image> \
    bash -c "cd /mnt/robotwin && RANK=0 NUM_MACHINES=20 NUM_GPUS=8 bash multi_proc_scripts/launch_all.sh"

# Node 1
# ... same command with RANK=1

# Node 19
# ... same command with RANK=19
```

All nodes must share the same `save_path` filesystem for queue coordination and data output.

### Key Mount Points

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| RoboTwin code | `/mnt/robotwin` | Must match CuRobo YAML hardcoded paths |
| Data storage | Same as `save_path` in config | Shared across all nodes |

### CuRobo Asset Path Issue

CuRobo YAML configs (`assets/embodiments/aloha-agilex/curobo_left.yml`, etc.) contain hardcoded absolute paths like:

```yaml
urdf_path: /mnt/robotwin/assets/embodiments/aloha-agilex/urdf/aloha_agilex_left.urdf
```

If your Docker mount path doesn't match, you'll get `FileNotFoundError`. Two fixes:

1. **Mount to match** (recommended): `-v /path/to/robotwin:/mnt/robotwin`
2. **Symlink**: `ln -sf /actual/path/assets /mnt/robotwin/assets`

### NVIDIA Driver Conflicts in Docker

If you see "failed to find a rendering device" (SAPIEN/Vulkan error), check for driver version mismatches:

```bash
# Inside container:
ls /usr/lib/x86_64-linux-gnu/libcuda* | grep -v $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr . _)
```

If there are library files from a different driver version than the host:

```bash
# Remove conflicting driver files (example for version 580.142 when host is 580.126):
rm -f /usr/lib/x86_64-linux-gnu/*580.142*
ldconfig
```

## Troubleshooting

**Workers exit with "no pending batches"**
- Normal if `TASK_FILTER`/`TASK_EXCLUDE` excludes all remaining work
- Check queue: `cat <save_path>/_queue/<task>.json | python -m json.tool | grep status`
- If you changed task filters, delete `_queue/` and re-run `init_queue.py`

**Slow rendering (minutes per episode instead of seconds)**
- Check CuRobo compilation target:
  ```bash
  python -c "
  import curobo
  import os
  path = os.path.dirname(curobo.__file__)
  # Look for compiled .so files and check their CUDA arch
  import subprocess
  sos = subprocess.check_output(f'find {path} -name \"*.so\"', shell=True).decode().split()
  for so in sos[:3]:
      out = subprocess.check_output(f'cuobjdump -lelf {so} 2>/dev/null | head -5', shell=True).decode()
      if out: print(f'{os.path.basename(so)}: {out}')
  "
  ```
- If you see `sm_89` (PTX fallback) on H100/H200, recompile CuRobo with `TORCH_CUDA_ARCH_LIST="9.0"`
- Reduce `NUM_WORKER_PER_GPU` — GPU contention kills throughput (2+ workers/GPU on Phase 2 is usually slower than 1)

**CuRobo "illegal instruction" on H100/H200 (Hopper)**
- The LBFGS fused CUDA kernel crashes on sm_90
- Fix is already in `planner.py` (`_disable_lbfgs_cuda_kernel`)
- Verify: if you see `CUDA error: an illegal instruction was encountered` in CuRobo stack traces, this is the cause
- `use_cuda_graph=True` is fine to keep enabled; only `use_cuda_kernel` needs to be False

**Incomplete cache / pkl2hdf5 errors**
- `pkl2hdf5.py` auto-cleans incomplete caches (missing sequential pkl files)
- Manual fix: `rm -rf <save_path>/<task>/<config>/.cache`
- This happens when a worker crashes mid-episode

**AssertionError: Collect Error / check_success failures**
- Phase 2 rendering may produce episodes where `check_success()` fails (physics divergence from seed collection)
- `collect_data.py` logs a warning but saves the data anyway — this is intentional
- If you see many failures for one task, the seed quality may be poor; re-run Phase 1

**IndexError in play_once()**
- Trajectory data mismatch for some episodes (pkl data doesn't match expected path length)
- `collect_data.py` catches this and skips the episode with a warning
- The episode will be missing from final output; re-check with `gen_instructions.sh --dry-run`

**Barrier stuck (nodes waiting forever)**
- Check `_barrier/` directory for missing node files
- If a node crashed, manually `touch _barrier/phase1_node_N` to unblock others
- Stale barrier from a previous run: delete `_barrier/` and restart all nodes together
- Use `CLUSTER_ID` to avoid conflicts when running multiple clusters

**Queue batch_size changes not taking effect**
- `init_queue.py` skips tasks whose queue file already exists
- Delete `_queue/` directory and re-run `init_queue.py` after changing `--batch-size`

**scene_info.json missing entries after Phase 2**
- Scene info is written as independent files in `_scene_info/episode_N.json`
- Run `bash multi_proc_scripts/gen_instructions.sh <task> <config> --dry-run` to check consistency
- `finalize_tasks.sh` merges them into `scene_info.json` automatically

**TASK_EXCLUDE with multiple tasks**
- Comma-separated, no spaces: `TASK_EXCLUDE=hanging_mug,lift_pot,open_laptop`

## Performance Tuning

| Setting | Phase 1 | Phase 2 |
|---------|---------|---------|
| `NUM_WORKER_PER_GPU` | 2-4 (CPU-bound seed search) | 1 (GPU-bound rendering) |
| `BATCH_SIZE` | N/A | 5-10 (smaller = better load balance, more lock overhead) |
| Expected throughput | Varies by task complexity | ~60-180 ep/hour/GPU (single worker) |

Tips:
- Phase 2 is GPU-bound; adding more workers per GPU causes contention and slows everything down
- Phase 1 is more CPU-bound (planning); 2-4 workers/GPU can help
- Different tasks have very different rendering times; the queue system handles this naturally
- Monitor with `--watch` to get real-time throughput (ep/h) and ETA

## Requirements

- Python 3.8+
- PyYAML
- SAPIEN (robotics simulator)
- CuRobo (motion planning, compiled for target GPU arch)
- NVIDIA GPUs with CUDA support
- NVIDIA Container Toolkit (for Docker GPU passthrough)
- Shared filesystem (NFS, Lustre, etc.) accessible from all nodes
- Docker (recommended for reproducible environments)
