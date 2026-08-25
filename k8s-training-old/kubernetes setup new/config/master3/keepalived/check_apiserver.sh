#!/bin/sh

errorExit() {
    echo "*** $*" 1>&2
    exit 1
}

curl --silent --max-time 2 --insecure https://localhost:80/ -o /dev/null || errorExit "Error GET https://localhost:80/"
if ip addr | grep -q 192.168.40.35; then
    curl --silent --max-time 2 --insecure https://192.168.40.35:80/ -o /dev/null || errorExit "Error GET https://192.168.40.35:80/"
fi