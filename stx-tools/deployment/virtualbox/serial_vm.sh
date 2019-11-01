#!/usr/bin/env bash

socat UNIX-CONNECT:"/tmp/serial_$1" stdio,raw,echo=0,icanon=0
