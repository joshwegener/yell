#!/bin/bash

model_checksum_for() {
    case "$1" in
        ggml-tiny.en.bin)
            echo "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"
            ;;
        ggml-base.en.bin)
            echo "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
            ;;
        ggml-small.en.bin)
            echo "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
            ;;
        *)
            return 1
            ;;
    esac
}

model_checksum_matches() {
    local path="$1"
    local name="$2"
    local expected actual

    expected="$(model_checksum_for "$name")" || return 1
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    [ "$actual" = "$expected" ]
}
