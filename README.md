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
    program #41.
  - The preceding execution sequence may affect reproducibility, but which
    preceding operations or environmental conditions matter has not been
    isolated.

## Reproducing

All runs used a **freshly booted** VM, a threaded executor, `sandbox=none`,
`procs=1`, `repeat=1`, no additional syzkaller features and a tiny 4 vCPU /
6 GiB KVM guest (QEMU 6.2.0). syzkaller revision:
`853b104bb454141a5b0fc0e4218ec78e9f34ffb1+` (the `+` denotes local KernSight
integration changes; see below).

Programs are executed strictly in file order; there is no concurrency.

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
kernel/                       kernel configs
cmdline/                      kernel command lines
MANIFEST.sha256               sha256 of every file in this repository
```
