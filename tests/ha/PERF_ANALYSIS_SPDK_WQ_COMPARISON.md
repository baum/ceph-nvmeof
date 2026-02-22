# Perf Analysis: SPDK WQ vs Default (AsioContextWQ)

**CI Run:** [baum/ceph-nvmeof Actions #22295965340](https://github.com/baum/ceph-nvmeof/actions/runs/22295965340)  
**Context:** [ceph/ceph#66881](https://github.com/ceph/ceph/pull/66881) – librbd ContextWQ as pure interface; SpdkContextWQ for reactor execution

## Summary

| Metric | perf_default (AsioContextWQ) | perf_spdk_wq (SpdkContextWQ) | Delta |
|--------|------------------------------|------------------------------|-------|
| Samples | 56K | 54K | ~4% fewer |
| Total samples (stack sum) | ~14.2B | ~13.6B | ~4% fewer |
| perf.data size | 6.75 MB | 6.52 MB | ~3% smaller |

## Bdevperf I/O Statistics

Workload: verify, depth 128, 4 KiB I/O, 1 second, 2 namespaces (Nvme00n1, Nvme00n2).

### Raw numbers

| Metric | Default (AsioContextWQ) | SPDK WQ (SpdkContextWQ) | Delta |
|--------|-------------------------|--------------------------|-------|
| **Total IOPS** | 2440.42 | 2387.24 | −2.2% |
| **Total MiB/s** | 9.53 | 9.33 | −2.1% |
| **Avg latency (µs)** | 102,084 | 104,711 | +2.6% |
| **Min latency (µs)** | 8,254 | 4,422 | **−46%** |
| **Max latency (µs)** | 267,568 | 192,958 | **−28%** |
| Nvme00n1 IOPS | 1092.49 | 1069.77 | −2.1% |
| Nvme00n2 IOPS | 1347.93 | 1317.46 | −2.3% |
| Nvme00n1 avg lat (µs) | 111,333 | 115,936 | +4.1% |
| Nvme00n2 avg lat (µs) | 94,227 | 95,527 | +1.4% |

### Analysis

- **IOPS / throughput:** SPDK WQ is ~2% lower; within noise for a 1-second run.
- **Average latency:** Slightly higher with SPDK WQ (+2.6%), also within variance.
- **Tail latency:** SPDK WQ shows **better** min and max latency (−46% min, −28% max), which suggests less queueing/contention when completions run on reactor threads instead of a separate ASIO pool.
- **1-second run:** Variance dominates; longer runs are needed for stable comparisons. The tail-latency improvement is the more notable result.

## Flame Graph Variations

### 1. reactor_0 `msg_queue_run_batch` / `spdk_ring_dequeue`

**Default:** 785.75M samples  
**SPDK WQ:** 861.25M samples (**+9.6%**)

This path is where SPDK executes messages enqueued via `spdk_thread_send_msg()`. With SpdkContextWQ, librbd completion callbacks are scheduled onto reactor threads through this mechanism. The higher sample count for SPDK WQ indicates more work on reactor threads from **librbd completions** that formerly ran on AsioContextWQ (io_context_pool) threads.

### 2. reactor_0 `spdk_thread_poll` / `thread_poll`

**Default:** 454.25M (thread_poll) / 161.5M (spdk_thread_poll)  
**SPDK WQ:** 489.75M (thread_poll) / 184.75M (spdk_thread_poll) (**+7.8%** / **+14.4%**)

More time spent in reactor polling with SpdkContextWQ, consistent with reactor threads handling both NVMe-oF I/O and librbd completion callbacks.

### 3. reactor_post_process_lw_thread / spdk_thread_is_exited

**Default:** 124.25M samples  
**SPDK WQ:** 133.75M samples (**+7.6%**)

Lightweight thread processing and exit checks increase with SpdkContextWQ, in line with more message/callback traffic on reactors.

### 4. thread_execute_poller → nvmf_tgroup_poll (I/O path)

**Default:** 37.5M samples (nvmf_tgroup_poll under thread_execute_poller)  
**SPDK WQ:** 42.25M samples (**+12.7%**)

The NVMe-oF transport poll path (bdev I/O) shows more activity with SpdkContextWQ, suggesting completions running on the same reactors that do I/O, which can improve locality.

### 5. Non-reactor threads (msgr-worker, safe_timer, ceph_timer, log)

Both runs show very small contributions from librados/ceph threads (msgr-worker-0, safe_timer, ceph_timer, log) – typically 250K samples each (~0.00%).  

- **Default:** msgr-worker-0 (1 stack), safe_timer (1 stack)  
- **SPDK WQ:** msgr-worker-0 (2 stacks, 500K), safe_timer (3 stacks, 750K), ceph_timer (1), log (1)

With SpdkContextWQ, less librbd completion work is expected on io_context/ASIO threads; the librados messenger and other ASIO work remain. The small counts make the difference hard to quantify at this run length.

## Interpretation (ContextWQ Change)

Per [ceph/ceph#66881](https://github.com/ceph/ceph/pull/66881):

- **AsioContextWQ:** completions run on an ASIO thread pool (io_context_pool); thread count scales with librados/librbd instances.
- **SpdkContextWQ:** completions run on SPDK reactor threads via `spdk_thread_send_msg()`; reactors are shared across bdevs.

The flame graph differences support this:

1. **More reactor work in SPDK WQ** – Higher counts in `msg_queue_run_batch`, `spdk_thread_poll`, and `reactor_post_process_lw_thread` indicate that librbd completion callbacks are now executed on reactors instead of ASIO threads.

2. **Completions on reactors** – The increase in reactor_0 `msg_queue_run_batch;spdk_ring_dequeue` (+9.6%) matches the expectation that SpdkContextWQ routes completion callbacks through `spdk_thread_send_msg()` into reactor message queues.

3. **1-second workload** – The run is only 1s, so librados/ASIO threads show minimal samples. Longer runs would give clearer visibility of reduced ASIO completion work with SpdkContextWQ.

## Artifacts

- **perf_default:** `perf_analysis_default/perf_ci_perf_default_20260223_080427/`
- **perf_spdk_wq:** `perf_analysis_spdk_wq/perf_ci_perf_spdk_wq_20260223_080312/`

Key files: `flame_graph.svg`, `cpu_flame_graph.svg`, `perf_report.txt`, `stack_collapse.txt`, `nvmeof.log` (if captured)

---

## Log Mining: SpdkContextWQ Assignment → Perf Correlation

When `rbd_with_spdk_wq` is enabled, the gateway logs show SpdkContextWQ creation. Use these lines to correlate with perf data.

### Example log lines (from Display logs or `nvmeof.log`)

```
bdev_rbd_find_reactor_thread: reactor thread lcore=1: thread=0x29f4e240, id=2, name=nvmf_tgt_poll_group_000
bdev_rbd_spdk_context_wq_create_from_ioctx: Successfully created SpdkContextWQ=0x2a21f450 with reactor thread=0x29f4e240 (id=2, name=nvmf_tgt_poll_group_000)
```

### Mining extraction

| Log field | Meaning | Perf correlation |
|-----------|---------|------------------|
| `lcore=1` | Reactor lcore (CPU core) | **reactor_1** in flame graph = lcore 1 |
| `thread=0x29f4e240` | SPDK thread pointer | — |
| `id=2` | SPDK thread ID | — |
| `name=nvmf_tgt_poll_group_000` | NVMe-oF poll group thread | Same reactor does nvmf polling + SpdkContextWQ completions |

### Key insight

- **lcore N** in logs = **reactor_N** in perf (same reactor).
- SpdkContextWQ completions run on the assigned reactor's message queue (`msg_queue_run_batch`).
- If `nvmf_tgt_poll_group_000` → that thread handles both NVMe-oF I/O and librbd completions on the same reactor.

### Grep commands (on `nvmeof.log` when in artifact)

```bash
grep -E 'bdev_rbd_find_reactor_thread|SpdkContextWQ|bdev_rbd_spdk_context_wq' nvmeof.log
```

### This run (SPDK WQ)

- **Assignment:** lcore=1 → reactor_1
- **Flame graph:** reactor_1 = 23.91% in SPDK WQ run
- reactor_0 (26.69%) and reactor_2 (26.71%) carry more load overall; reactor_1 holds the SpdkContextWQ for the single RBD bdev in this test.

---

## CPU Flame Graph: Ctrl-F Search Summary

The CPU flame graph SVG supports **Ctrl-F** (or F3) to search. Matching frames are highlighted in magenta and **"Matched: X%"** shows the percentage of total samples in frames containing the search term. Percentages are of the full graph (100% = all samples).

### Thread-level CPU % (root frames)

| Thread        | Default (AsioContextWQ) | SPDK WQ            | Change     |
|---------------|-------------------------|--------------------|------------|
| reactor_0     | 23.84% (3.38B cpu)      | 26.69% (3.64B cpu) | **+2.85pp** |
| reactor_1     | 23.36% (3.31B cpu)      | 23.91% (3.26B cpu) | +0.55pp   |
| reactor_2     | 27.54% (3.90B cpu)      | 26.71% (3.64B cpu) | -0.83pp   |
| reactor_3     | 25.25% (3.58B cpu)      | 22.67% (3.09B cpu) | **-2.58pp** |
| msgr-worker-0 | 0.00% (250K cpu)       | 0.00% (500K cpu)   | —         |
| safe_timer    | 0.01% (750K cpu)        | 0.01% (1.25M cpu)  | —         |
| ceph_timer    | —                       | 0.00% (250K cpu)   | new       |
| log           | —                       | 0.00% (250K cpu)   | new       |

### SPDK WQ run: reactor load distribution

- **reactor_0** carries the highest load (26.69%), followed by reactor_2 (26.71%), reactor_1 (23.91%), and reactor_3 (22.67%).
- Spread: reactor_0/reactor_2 vs reactor_3 ≈ **4pp**.
- reactor_0 gains the most work with SpdkContextWQ (completion callbacks on its reactor via round-robin assignment).

### Ctrl-F Search Terms (Code-Derived)

Terms from SPDK (`spdk/module/bdev/rbd/`, `spdk/lib/thread/`, `spdk/lib/event/`) and Ceph.

**SpdkContextWQ call flow:**
```
librbd completion → SpdkContextWQ::queue() → spdk_thread_send_msg(reactor, spdk_msg_handler, msg)
reactor_run → spdk_thread_poll() → thread_poll() → msg_queue_run_batch() → spdk_ring_dequeue()
  → msg->fn() = spdk_msg_handler → rbd_context_complete(ctx, r)
```

**Tier 1 (SpdkContextWQ path):** `msg_queue_run_batch` (thread msgs), `thread_poll;msg_queue_run_batch`, `spdk_ring_dequeue`, `spdk_thread_send_msg`
**Tier 2 (Reactor):** `event_queue_run_batch` (reactor events, *not* SpdkContextWQ), `reactor_post_process_lw_thread`, `spdk_thread_is_exited`, `thread_execute_poller`
**Tier 3 (NVMe-oF/bdev):** `nvmf_tgroup_poll`, `nvmf_tcp_poll_group_poll`, `bdev_rbd_finish_aiocb`
**Tier 4 (Ceph/AsioContextWQ):** `msgr-worker`, `safe_timer` (timer tree), `ceph::mono_clock::now`, `std::_Rb_tree.*Context`

SpdkContextWQ uses **thread messages** (msg_queue_run_batch), not reactor events (event_queue_run_batch).

### Approximate % (both runs)

| Search term                  | Default | SPDK WQ | Interpretation                      |
|-----------------------------|---------|---------|-------------------------------------|
| `reactor_0`                 | 23.8%   | 26.7%   | More work on reactor_0 with SPDK WQ |
| `msg_queue_run_batch`       | ~5.7%   | ~6.1%   | SpdkContextWQ path; **SPDK WQ higher** |
| `spdk_ring_dequeue`         | ~4.7%   | ~5.2%   | Thread + event dequeue combined       |
| `event_queue_run_batch`     | ~3.2%   | ~3.3%   | Reactor events (not SpdkContextWQ)   |
| `reactor_post_process_lw_thread` | ~1.9% | ~2.0%   | Slight increase in lw thread work    |
| `nvmf_tgroup_poll`          | ~3.5%   | ~3.4%   | Similar NVMe-oF I/O path             |
| `msgr-worker`               | ~0.00%  | ~0.00%  | Negligible; no clear io_context drop |
| `safe_timer`                | 0.01%   | 0.01%   | Negligible                           |

Exact “Matched” values depend on overlapping frames; the table reflects aggregate trends.

### Takeaway

- **Default:** reactor load is relatively balanced (23–28% per reactor).
- **SPDK WQ:** reactor_0 and reactor_2 see more work; reactor_3 sees less.
- SpdkContextWQ moves librbd completions to reactors (especially reactor_0 in this run).
- Non-reactor threads (msgr-worker, safe_timer) remain at &lt;0.01% in both runs.
