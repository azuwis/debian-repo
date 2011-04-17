#!/bin/sh
find etc -type f | while read i; do cp "/$i" "$i"; done
