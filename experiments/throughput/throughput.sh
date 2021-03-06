#!/bin/bash

# Usage: ./throughput.sh [-n NUM_CLIENTS]
#
# Tests the raw throughput of a single proxy. This script starts a web
# server serving swfcat.swf and a large data file, starts a facilitator,
# client transport plugin, and socat shim, and then starts multiple
# downloads through the proxy at once. Results are saved in a file
# called results-NUM_CLIENTS-DATE, where DATE is the current date.

#         plain       socks            ws               ws              plain
# httpget <---> socat <---> flashproxy-client <---> flashproxy <---> websockify <---> thttpd
#             2000        9001             9000                    8001             8000

. ../common.sh

NUM_CLIENTS=1

while getopts "n:" OPTNAME; do
	if [ "$OPTNAME" == n ]; then
		NUM_CLIENTS="$OPTARG"
	fi
done

PROFILE=flashexp1
PROXY_URL="http://127.0.0.1:8000/embed.html?facilitator=127.0.0.1:9002&max_clients=$NUM_CLIENTS&ratelimit=off&facilitator_poll_interval=1.0"
DATA_FILE_NAME="$FLASHPROXY_DIR/dump"
RESULTS_FILE_NAME="results-$NUM_CLIENTS-$(date --iso)"

# Declare an array.
declare -a PIDS_TO_KILL
stop() {
	browser_clear "$PROFILE"
	if [ -n "${PIDS_TO_KILL[*]}" ]; then
		echo "Kill pids ${PIDS_TO_KILL[@]}."
		kill "${PIDS_TO_KILL[@]}"
	fi
	echo "Delete data file."
	rm -f "$DATA_FILE_NAME"
	exit
}
trap stop EXIT

echo "Create data file."
dd if=/dev/null of="$DATA_FILE_NAME" bs=1M seek=10 2>/dev/null || exit

echo "Start web server."
"$THTTPD" -D -d "$FLASHPROXY_DIR" -p 8000 &
PIDS_TO_KILL+=($!)

echo "Start websockify."
"$WEBSOCKIFY" -v 8001 127.0.0.1:8000 >/dev/null &
PIDS_TO_KILL+=($!)

echo "Start facilitator."
"$FLASHPROXY_DIR"/facilitator -d --relay 127.0.0.1:8001 127.0.0.1 9002 >/dev/null &
PIDS_TO_KILL+=($!)
visible_sleep 1

echo "Start client transport plugin."
"$FLASHPROXY_DIR"/flashproxy-client >/dev/null &
PIDS_TO_KILL+=($!)
visible_sleep 1

echo "Start browser."
browser_goto "$PROFILE" "$PROXY_URL"
visible_sleep 2

# Create sufficiently many client registrations.
i=0
while [ $i -lt $NUM_CLIENTS ]; do
	echo -ne "\rRegister client $((i + 1))."
	echo $'POST / HTTP/1.0\r\n\r\nclient=127.0.0.1:9000' | socat STDIN TCP-CONNECT:127.0.0.1:9002
	sleep 1
	i=$((i + 1))
done
echo
visible_sleep 2

echo "Start socat."
"$SOCAT" TCP-LISTEN:2000,fork,reuseaddr SOCKS4A:127.0.0.1:dummy:0,socksport=9001 &
PIDS_TO_KILL+=($!)
visible_sleep 1


> "$RESULTS_FILE_NAME"

# Proxied downloads.
declare -a WAIT_PIDS
i=0
while [ $i -lt $NUM_CLIENTS ]; do
	echo "Start downloader $((i + 1))."
	./httpget.py -l proxy http://127.0.0.1:2000/dump >> "$RESULTS_FILE_NAME" &
	WAIT_PIDS+=($!)
	i=$((i + 1))
done
for pid in "${WAIT_PIDS[@]}"; do
	wait "$pid"
done
unset WAIT_PIDS

# Direct downloads.
declare -a WAIT_PIDS
i=0
while [ $i -lt $NUM_CLIENTS ]; do
	echo "Start downloader $((i + 1))."
	./httpget.py -l direct http://127.0.0.1:8000/dump >> "$RESULTS_FILE_NAME" &
	WAIT_PIDS+=($!)
	i=$((i + 1))
done
for pid in "${WAIT_PIDS[@]}"; do
	wait "$pid"
done
unset WAIT_PIDS
