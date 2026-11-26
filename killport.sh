#!/bin/bash

# Usage: ./killport.sh 8000
port=$1

if [ -z "$port" ]; then
  echo "Usage: $0 <port>"
  exit 1
fi

pid=$(sudo lsof -t -i :$port)

if [ -n "$pid" ]; then
  echo "Killing process $pid on port $port..."
  sudo kill -9 $pid
  echo "Done."
else
  echo "No process found on port $port."
fi
