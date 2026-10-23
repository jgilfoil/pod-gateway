#!/bin/sh
# Run inside the image: docker run --rm -i --entrypoint sh IMAGE < tests/dnssec.sh
# Uses public DNS only; requires UDP/TCP access to 1.1.1.1:53.
set -eu

dnsmasq --test --conf-file=/usr/share/dnsmasq/trust-anchors.conf --dnssec
dnsmasq --keep-in-foreground --conf-file=/usr/share/dnsmasq/trust-anchors.conf \
    --dnssec --no-resolv --server=1.1.1.1 --listen-address=127.0.0.1 \
    --bind-interfaces --port=5353 --pid-file= --log-facility=- &
resolver_pid=$!
trap 'kill "$resolver_pid" 2>/dev/null || true; wait "$resolver_pid" 2>/dev/null || true' EXIT

attempt=0
until dig @127.0.0.1 -p 5353 +time=1 +tries=1 +short . SOA >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 5 ] || { echo 'FAIL: test resolver did not start'; exit 1; }
done

valid=$(dig @127.0.0.1 -p 5353 +time=5 +tries=1 +dnssec +adflag cloudflare.com A)
printf '%s\n' "$valid" | grep -q 'status: NOERROR' || {
    printf 'FAIL: valid signed domain did not resolve\n%s\n' "$valid"
    exit 1
}
printf '%s\n' "$valid" | grep -Eq 'flags:.* ad[; ]' || {
    printf 'FAIL: valid answer was not DNSSEC authenticated\n%s\n' "$valid"
    exit 1
}
echo 'PASS: signed public domain resolves with authenticated data'

invalid=$(dig @127.0.0.1 -p 5353 +time=5 +tries=1 +dnssec dnssec-failed.org A)
printf '%s\n' "$invalid" | grep -q 'status: SERVFAIL' || {
    printf 'FAIL: invalid DNSSEC domain was not rejected\n%s\n' "$invalid"
    exit 1
}
# Ensure the negative test is an actual signature failure, not unreachable DNS.
unchecked=$(dig @127.0.0.1 -p 5353 +time=5 +tries=1 +cdflag dnssec-failed.org A)
printf '%s\n' "$unchecked" | grep -q 'status: NOERROR' || {
    printf 'FAIL: negative-test domain is unreachable\n%s\n' "$unchecked"
    exit 1
}
echo 'PASS: bogus signatures are rejected while upstream remains reachable'
