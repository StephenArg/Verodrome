#!/bin/zsh
# render.sh <html> <css-width> <css-height> <out.png>  — renders at 2x in headless Chrome
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
  --default-background-color=00000000 --window-size=$2,$3 --virtual-time-budget=3000 \
  --screenshot="$4" "file://$1" >/dev/null 2>&1
