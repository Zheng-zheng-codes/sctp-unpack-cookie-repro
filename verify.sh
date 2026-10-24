#!/bin/sh
# Verify the numbers quoted in README.md / the bug report against the files in
# this repository.
set -u
cd "$(dirname "$0")" || exit 1
fail=0
check() {
  name=$1; expected=$2; actual=$3
  if [ "$actual" = "$expected" ]; then
    printf 'OK    %-48s %s\n' "$name" "$actual"
  else
    printf 'FAIL  %-48s got=%s want=%s\n' "$name" "$actual" "$expected"
    fail=1
  fi
}

check "programs in repro.kernsight.prog" 42 \
  "$(grep -c '^executing program' repro/repro.kernsight.prog)"

trig=$(python3 - <<'PY'
import re
d = open('repro/repro.kernsight.prog', errors='replace').read()
p = re.split(r'(?m)^executing program (\d+):\n', d)[1:]
b = list(zip(p[0::2], p[1::2]))
print(','.join(n for n, t in b if 'socket$inet6_sctp' in t and 'fail_nth: 43' in t))
PY
)
check "SCTP trigger program indices in sequence" "40,41" "$trig"

check "KASAN reports, 7.3 sequence replay" 1 \
  "$(grep -a -c 'KASAN: slab-use-after-free in sctp_unpack_cookie' logs/serial-7.3.log)"
check "KASAN reports, 7.3 standalone run 1" 0 \
  "$(grep -a -c 'KASAN: slab-use-after-free in sctp_unpack_cookie' logs/serial-7.3-minimal-no-trigger.log)"
check "KASAN reports, 7.3 standalone run 2" 0 \
  "$(grep -a -c 'KASAN: slab-use-after-free in sctp_unpack_cookie' logs/serial-7.3-minimal2-no-trigger.log)"
check "KASAN reports, 7.1.3 C reproducer" 1 \
  "$(grep -a -c 'KASAN: slab-use-after-free in sctp_unpack_cookie' logs/serial-7.1.3-c-repro.log)"

first=$(grep -a -m1 'BUG: KASAN: slab-use-after-free in sctp_unpack_cookie' logs/serial-7.3.log |
  grep -oE '^\[ *[0-9]+\.[0-9]+' | tr -d '[] ')
case "$first" in
  212.7*) printf 'OK    %-48s %s\n' "first KASAN timestamp (s), 7.3 sequence" "$first" ;;
  *) printf 'FAIL  %-48s got=%s want=212.7*\n' "first KASAN timestamp (s), 7.3 sequence" "$first"; fail=1 ;;
esac

check "fault injection logged in 7.3 sequence" yes \
  "$(grep -aq 'name fail_skb_realloc' logs/serial-7.3.log && echo yes || echo no)"

exit $fail
