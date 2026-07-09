#!/usr/bin/env bash

set -euo pipefail

build_san_entries() {
    local host_name="${1:-}"
    local local_hostname="${2:-}"
    local local_ipv4="${3:-}"
    local extra_hostnames=("${@:4}")
    local -a hosts=()

    add_host_if_missing() {
        local candidate="$1"
        local existing
        for existing in "${hosts[@]}"; do
            if [ "$existing" = "$candidate" ]; then
                return 0
            fi
        done
        hosts+=("$candidate")
    }

    SAN_KEYTOOL=""
    ALT_NAMES=""
    ALT_INDEX=1
    IP_INDEX=1

    add_host_if_missing "$host_name"
    for extra_host in "${extra_hostnames[@]}"; do
        if [ -n "$extra_host" ] && [ "$extra_host" != "$host_name" ]; then
            add_host_if_missing "$extra_host"
        fi
    done
    if [ -n "$local_hostname" ] && [ "$local_hostname" != "$host_name" ]; then
        add_host_if_missing "$local_hostname"
    fi

    for host_value in "${hosts[@]}"; do
        if [ -n "$host_value" ]; then
            if [ -n "$SAN_KEYTOOL" ]; then
                SAN_KEYTOOL="$SAN_KEYTOOL,dns:$host_value"
            else
                SAN_KEYTOOL="SAN=dns:$host_value"
            fi

            if [ -n "$ALT_NAMES" ]; then
                ALT_NAMES="$ALT_NAMES
DNS.$ALT_INDEX=$host_value"
            else
                ALT_NAMES="DNS.$ALT_INDEX=$host_value"
            fi
            ALT_INDEX=$((ALT_INDEX + 1))
        fi
    done

    if [ -n "$local_ipv4" ]; then
        if [ -n "$SAN_KEYTOOL" ]; then
            SAN_KEYTOOL="$SAN_KEYTOOL,ip:$local_ipv4"
        else
            SAN_KEYTOOL="SAN=ip:$local_ipv4"
        fi

        if [ -n "$ALT_NAMES" ]; then
            ALT_NAMES="$ALT_NAMES
IP.$IP_INDEX=$local_ipv4"
        else
            ALT_NAMES="IP.$IP_INDEX=$local_ipv4"
        fi
    fi
}
