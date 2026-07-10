#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UTILS="$SCRIPT_DIR/../tls_san_utils.sh"

assert_contains() {
    local haystack="$1"
    local needle="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "Expected '$needle' in '$haystack'" >&2
        exit 1
    fi
}

if [ ! -f "$UTILS" ]; then
    echo "Missing helper script: $UTILS" >&2
    exit 1
fi

source "$UTILS"

build_san_entries \
    "ip-10-0-0-10.ec2.internal" \
    "ip-10-0-0-10" \
    "10.0.0.10" \
    "ip-10-0-0-10.compute.internal" \
    "ip-10-0-0-10.ec2.internal"

assert_contains "$SAN_KEYTOOL" "dns:ip-10-0-0-10.ec2.internal"
assert_contains "$SAN_KEYTOOL" "dns:ip-10-0-0-10"
assert_contains "$SAN_KEYTOOL" "dns:ip-10-0-0-10.compute.internal"
assert_contains "$SAN_KEYTOOL" "ip:10.0.0.10"
assert_contains "$ALT_NAMES" "DNS.1=ip-10-0-0-10.ec2.internal"
assert_contains "$ALT_NAMES" "DNS.2=ip-10-0-0-10.compute.internal"
assert_contains "$ALT_NAMES" "DNS.3=ip-10-0-0-10"
assert_contains "$ALT_NAMES" "IP.1=10.0.0.10"

echo "tls_san_utils regression test passed"
