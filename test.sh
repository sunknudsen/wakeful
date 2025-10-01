#! /bin/sh

function stop()
{
  count=0
  while [ $count -lt 30 ]
  do
    echo "Stopping on $(date '+%H:%M:%S')" >> ~/Downloads/test
    sleep 1
    count=$((count + 1))
  done
  echo "Stopped on $(date '+%H:%M:%S')" >> ~/Downloads/test
  diskutil eject "/Volumes/Docker"
  exit 0
}

function terminate()
{
  echo "Terminated on $(date '+%H:%M:%S')" >> ~/Downloads/test
  exit 0
}

trap stop INT

trap terminate TERM

rm ~/Downloads/test

printf "Press Ctrl+C to initiate stop\n"

while :
do
  sleep 60
done