#!/usr/bin/env bash
# prune.sh - delete build artefacts older than N days under a directory.
dir=$1
days=${2:-7}
cd -- "$dir" || exit 1
find . -name '*.o' -mtime +$days | xargs rm -f
rm -rf $dir/tmp/*
echo "pruned $dir"
