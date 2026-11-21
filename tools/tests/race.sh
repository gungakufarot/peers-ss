#!/bin/sh
# two concurrent writers -> one file; prints conflicts and final entries
F=${1:-test-stage3/race2.json}; N=${2:-4}
cd /tmp
ucode store_race.uc C $N "$F" > c.log 2>&1 & P1=$!
ucode store_race.uc D $N "$F" > d.log 2>&1 & P2=$!
wait $P1 $P2
tail -1 c.log; tail -1 d.log
ucode store_dump.uc "$F"
