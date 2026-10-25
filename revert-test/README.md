# Revert test: 62b08083ec3d on top of 7.3.0

- `sctp-revert-62b08083ec3d.patch` — manual revert of
  `62b08083ec3d ("[SCTP]: Fix panic's when receiving fragmented SCTP control chunks.")`
  adapted to 7.3.0: `pskb_pull()` + `goto nomem` → `skb_pull()` in
  `sctp_sf_do_5_1D_ce`, `sctp_sf_beat_8_3` and `sctp_sf_do_5_2_4_dupcook`.
- Kernel: `7.3.0-kernsight-kasan #2`, built with the same `.config`
  (KASAN/KCOV, `CONFIG_FAIL_SKB_REALLOC=y`) and gcc 11.4.0 (Ubuntu 22.04).
- Test input: the same 42-program sequence (`repro.kernsight.prog`) that
  triggered the UAF on the unmodified 7.3.0 (1/1, first KASAN at t=212.7 s).
- Result on the reverted kernel (2 runs, fresh VM each):
  - `parsed 42 programs`, `syz-execprog` exited 0, no panic;
  - no `KASAN: slab-use-after-free in sctp_unpack_cookie` in either serial;
  - fault injection still fires (`failslab`, `times 0`, 4 messages/run), but
    the stack shows the injection landing in `sctp_unpack_cookie+0x68e`
    instead of the skb reallocation hook; no stale-pointer access was reported
    by KASAN.

The same input sequence and fail_nth annotations were used. However, removing
these `pskb_pull()` calls changes the fault-injection sequence: the reverted
runs logged `failslab` injections instead of the original
`fail_skb_realloc` injection. These results therefore show that the original
reproducer no longer triggers the reported UAF after the revert; they do not
establish equivalent injection coverage.

`run1/` and `run2/` contain `serial.log`, `console.log`, `execprog-out.txt`;
`counts.txt` summarizes the numbers.
