#!/bin/sh
# Monte d'un cran le numéro de version publiée (studio.html + version.json + cache du service worker).
# À lancer avant chaque publication : ./publier-version.sh
set -e
cd "$(dirname "$0")"
v=$(sed -n 's/.*"version":"\([0-9]*\)".*/\1/p' version.json); n=$((v+1))
sed -i "s/window.APP_VERSION_PUBLIEE = \"$v\"/window.APP_VERSION_PUBLIEE = \"$n\"/; s/^var APP_VERSION='$v';/var APP_VERSION='$n';/" studio.html
sed -i "s/const CACHE = 'byviral-v[0-9]*';/const CACHE = 'byviral-v$n';/" sw.js
echo "{\"version\":\"$n\"}" > version.json
grep -q "APP_VERSION_PUBLIEE = \"$n\"" studio.html && echo "version $n"
