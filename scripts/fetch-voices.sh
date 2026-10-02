#!/bin/zsh
# Downloads the optional natural voices (≈ 400 MB) into ~/Library/Application Support/Sidekick/Voices.
# Without them Sidekick falls back to the Mac's built-in voices.
#   English: Kokoro multi-lang v1.0 (Apache-2.0)
#   Hindi:   Piper "priyamvada" (CC BY-NC-SA 4.0 — non-commercial use)
set -e
DIR="$HOME/Library/Application Support/Sidekick/Voices"
BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"
mkdir -p "$DIR"
cd "$DIR"
for m in kokoro-multi-lang-v1_0 vits-piper-hi_IN-priyamvada-medium; do
  if [[ -d "$m" ]]; then echo "✓ $m already installed"; continue; fi
  echo "↓ $m"
  curl -fL --progress-bar "$BASE/$m.tar.bz2" | tar xj
done
echo "Voices installed in $DIR — restart Sidekick and pick one in Settings → Voice."
