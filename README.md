# SCTP `sctp_unpack_cookie()` KASAN use-after-free — reproducers

This repository contains the reproducers and logs for:

```
KASAN: slab-use-after-free in sctp_unpack_cookie
```

The access happens while processing a COOKIE-ECHO in
`sctp_sf_do_5_2_4_dupcook()`. With the upstream skb fault-injection option
`CONFIG_FAIL_SKB_REALLOC` enabled and `fail_nth: 43` on `sendto()`, the
`pskb_pull()` in `sctp_sf_do_5_2_4_dupcook()` triggers `pskb_expand_head()`
(through `skb_might_realloc()`), which frees the old skb head; the subsequent
`sctp_unpack_cookie()` reads two bytes from the freed buffer.

## Tested kernels

| Kernel | Release | Notes |
|---|---|---|
| 7.1.3 | `7.1.3-kernsight-kasan #13` | KASAN/KCOV build, `CONFIG_FAIL_SKB_REALLOC=y` |
| 7.3.0 | `7.3.0-kernsight-kasan #1` | vanilla 7.3.0 (sha256 of the source tarball: `87363c24f10e06321eb362765521094e94471f6bff8bce2d6b3e40f39f004953`), `CONFIG_FAIL_SKB_REALLOC=y` |

`CONFIG_FAIL_SKB_REALLOC` and `net/core/skb_fault_injection.c` are upstream
(they are present in the vanilla 7.3.0 tarball). No SCTP changes were made for this
testing (for 7.3.0, `net/sctp/` matches vanilla apart from build artifacts).

Kernel configs and command lines are in `kernel/` and `cmdline/`.

## Observed results

- **7.1.3**:
  - syzkaller reproducer (`repro/repro.prog`) reproduces.
  - C reproducer (`repro/repro.cprog`) compiles and reproduces
    (`gcc -x c -O2 -pthread -o repro repro.cprog && ./repro`). See
    `logs/serial-7.1.3-c-repro.log`.
- **7.3.0**:
  - The standalone three-call program did **not** reproduce in two runs on a
    fresh guest (`logs/serial-7.3-minimal-no-trigger.log`).
  - Replaying the stored 42-program execution sequence
    (`repro/repro.kernsight.prog`) reproduced the crash (`logs/serial-7.3.log`).
    The SCTP trigger appears as program #40 and again inside the final
    program #41. A single executor process replays the programs one at a time;
    earlier programs' kernel-side asynchronous effects are not cancelled.
  - The preceding execution sequence may affect reproducibility, but which
    preceding operations or environmental conditions matter has not been
    isolated.

## Reproducing

All runs used a **freshly booted** VM, a threaded executor, `sandbox=none`,
`procs=1`, `repeat=1`, no additional syzkaller features and a tiny 4 vCPU /
6 GiB KVM guest (QEMU 6.2.0). syzkaller revision:
`853b104bb454141a5b0fc0e4218ec78e9f34ffb1+` (the `+` denotes local KernSight
integration changes; see below).

Programs are replayed by a single executor process (`procs=1`) one at a time
in file order, with `repeat=1`. The executor does not run programs in parallel,
but a program can leave kernel-side asynchronous work behind (timers,
workqueues, networking), so earlier programs' effects may still be active while
later ones run.

### 7.1.3 — minimal program

```sh
scp syz-execprog syz-executor repro/repro.prog root@guest:/tmp/
ssh root@guest
cd /tmp && chmod +x syz-execprog syz-executor
./syz-execprog -procs=1 -repeat=1 -disable=swap -executor ./syz-executor ./repro.prog
```

The program (3 calls):

```
r0 = socket$inet6_sctp(0xa, 0x5, 0x84)
setsockopt$inet6_sctp_SCTP_SOCKOPT_BINDX_ADD(r0, 0x84, 0x64, &(0x7f0000000080)=[@in6={0xa, 0x4e21, 0x5, @loopback, 0x9}], 0x1c)
sendto$inet6(r0, &(0x7f0000000000)='M', 0x1, 0x20004845, &(0x7f0000000040)={0xa, 0x4e21, 0xffffff00, @loopback, 0x2}, 0x1c) (fail_nth: 43)
```

C reproducer (7.1.3):

```sh
gcc -O2 -pthread -o repro repro/repro.cprog
./repro
```

### 7.3.0 — state-construction sequence

```sh
scp syz-execprog syz-executor repro/repro.kernsight.prog root@guest:/tmp/
ssh root@guest
cd /tmp && chmod +x syz-execprog syz-executor
./syz-execprog -procs=1 -repeat=1 -disable=swap -executor ./syz-executor ./repro.kernsight.prog
```

## Manual replay and verification

To watch a replay by hand:

1. Boot the guest with the serial console captured to a file, e.g.
   `-serial file:$OUT/serial.log`, and follow it from another terminal with
   `tail -f $OUT/serial.log`.
2. Start `syz-execprog` in the guest as shown above. It prints
   `parsed N programs`; add `-vv=1` to see every call's result:

   ```sh
   ./syz-execprog -vv=1 -procs=1 -repeat=1 -disable=swap      -executor ./syz-executor ./repro.kernsight.prog
   ```

3. The first KASAN report appears in the console about 212 s into the run in
   our environment; with `panic_on_warn=1` the guest then panics.

Numbers to confirm (all derivable from this repository):

| Check | Command | Expected |
|---|---|---|
| programs in the sequence | `grep -c '^executing program' repro/repro.kernsight.prog` | 42 |
| SCTP trigger programs | `./verify.sh` (parses the sequence) | #40 and #41 |
| KASAN reports in the 7.3 sequence log | `grep -a -c 'KASAN: slab-use-after-free in sctp_unpack_cookie' logs/serial-7.3.log` | 1 |
| first KASAN timestamp, 7.3 sequence | `grep -a -m1 'BUG: KASAN' logs/serial-7.3.log` | `[ 212.7...]` |
| KASAN in standalone 7.3 run 1 / run 2 | same grep on `logs/serial-7.3-minimal*-no-trigger.log` | 0 / 0 |
| KASAN in the 7.1.3 C run | same grep on `logs/serial-7.1.3-c-repro.log` | 1 |
| `fail_skb_realloc` injection logged | `grep -a 'name fail_skb_realloc' logs/serial-7.3.log` | present |

`./verify.sh` runs these checks and prints `OK`/`FAIL`.

## Revert test (62b08083ec3d)

Following the maintainer's request, `62b08083ec3d` ("[SCTP]: Fix panic's when
receiving fragmented SCTP control chunks.") was reverted by hand on top of
7.3.0 (`pskb_pull()` + `goto nomem` -> `skb_pull()` in
`sctp_sf_do_5_1D_ce()`, `sctp_sf_beat_8_3()` and
`sctp_sf_do_5_2_4_dupcook()`), and the kernel was rebuilt with the same
configuration (`7.3.0-kernsight-kasan #2`).

Replaying the same 42-program sequence:

| Kernel | Result |
|---|---|
| unmodified 7.3.0 | 1/1 trigger: GPF + KASAN slab-use-after-free in `sctp_unpack_cookie` (t=212.7 s) |
| reverted 7.3.0 | 2/2 no panic, no KASAN report; fault injection still fires (`failslab`, `times 0`, 4 messages/run) but lands in `sctp_unpack_cookie+0x68e` instead of the skb reallocation hook |

See `revert-test/` for the patch, the run logs and `counts.txt`.

## Fault injection

The `sendto()` call is annotated with `fail_nth: 43`. During this execution,
the kernel logged a `fail_skb_realloc` injection, followed by the KASAN report:

```
FAULT_INJECTION: forcing a failure.
name fail_skb_realloc, interval 1, probability 0, space 0, times 1
```

No additional `fail_skb_realloc` debugfs configuration was required.

## Key report lines

7.3.0 (full report in `logs/`):

```
BUG: KASAN: slab-use-after-free in sctp_unpack_cookie+0xb57/0xf30
Read of size 2 at addr ...
 sctp_unpack_cookie+0xb57/0xf30
 sctp_sf_do_5_2_4_dupcook+0x2e2/0x3320
 ...
Freed by task ...:
 skb_free_head
 pskb_expand_head
 skb_might_realloc
 sctp_sf_do_5_2_4_dupcook
```

7.1.3 (full report in `logs/cebee8cfa01b-kasan-7.1.3.txt`):

```
BUG: KASAN: slab-use-after-free in sctp_unpack_cookie+0xa56/0xdc0 net/sctp/sm_make_chunk.c:1744
 sctp_unpack_cookie+0xa56/0xdc0 net/sctp/sm_make_chunk.c:1744
 sctp_sf_do_5_2_4_dupcook+0x2dc/0x3030 net/sctp/sm_statefuns.c:2244
...
Freed by task ...:
 skb_free_head+0xb9/0x150 net/core/skbuff.c:1087
 pskb_expand_head+0x3b3/0x10b0 net/core/skbuff.c:2335
 skb_might_realloc+0xb6/0xd0 net/core/skb_fault_injection.c:33
 sctp_sf_do_5_2_4_dupcook+0x1ff/0x3030 net/sctp/sm_statefuns.c:2235
```

`pskb_pull()` is at `sm_statefuns.c:2235`; the subsequent call that enters
`sctp_unpack_cookie()` is at `:2244`.

## syzkaller modifications

The syzkaller tree is revision `853b104bb454141a5b0fc0e4218ec78e9f34ffb1` plus
KernSight integration changes (seed ordering/state feedback, `pkg/kernsight`,
`prog/kernsight_*`, `syz-manager/kernsight_*`, `pkg/execbackend`, snapshot
support in `vm/qemu`). None of these change the SCTP syscall descriptions or
the fault-injection semantics of the executor.

## Files

```
repro/repro.prog              syz program with fail_nth: 43 (7.1.3 minimal)
repro/repro.cprog             C reproducer with fail-nth setup (7.1.3)
repro/repro.kernsight.prog    42-program execution sequence (7.3.0)
logs/                         full KASAN reports and console logs
revert-test/                  revert of 62b08083ec3d: patch, logs, counts
verify.sh                     checks the numbers quoted above
kernel/                       kernel configs
cmdline/                      kernel command lines
MANIFEST.sha256               sha256 of every file in this repository
```
