#!/bin/bash
# Copia a unalineaalavez/glassesInstructor los archivos que son 100% nuevos.
#
# Solo copia archivos que NO existen allá, así que no puede pisar tu trabajo
# de Shiki. Los archivos que sí existen en ambos repos divergieron demasiado
# para copiarse: esos van a mano, con los diffs de MIGRAR.md.
#
# Uso:  ./migrar-a-unalineaalavez.sh [--dry-run]

set -euo pipefail

ORIGEN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTINO="${DESTINO:-$HOME/PROYECTOS PERSONALES/LIFE OF CHASSE/unalineaalavez/glassesInstructor}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Ordenados por prioridad. LinkAnalysis y LinkAnalyzer ya están migrados
# (idénticos allá), por eso el script los reporta como omitidos.
ARCHIVOS=(
  # Imprescindibles: escaneo sin gafas y aviso de desconexión
  "Source/Analysis/PhoneQRSession.swift"
  "Source/Views/Phone/GlassesOfflineOverlay.swift"
  "Source/Analysis/QRScanner.swift"
  # Opcionales: ya tienes Shiki con su propio TTS y vista
  "Source/Models/AvatarScript.swift"
  "Source/Managers/AvatarNarrator.swift"
  "Source/Views/Phone/AvatarAIView.swift"
  # Ya migrados (se omiten solos)
  "Source/Models/LinkAnalysis.swift"
  "Source/Analysis/LinkAnalyzer.swift"
)

if [[ ! -d "$DESTINO" ]]; then
  echo "No encuentro el repo destino:"
  echo "  $DESTINO"
  echo "Ajusta la variable DESTINO al principio del script."
  exit 1
fi

echo "Origen:  $ORIGEN"
echo "Destino: $DESTINO"
$DRY_RUN && echo "(simulación: no se escribe nada)"
echo

copiados=0
omitidos=0

for archivo in "${ARCHIVOS[@]}"; do
  origen="$ORIGEN/$archivo"
  destino="$DESTINO/$archivo"

  if [[ ! -f "$origen" ]]; then
    echo "  falta en origen: $archivo"
    continue
  fi

  # Nunca sobrescribir: si ya existe, es que lo tocaste tú.
  if [[ -f "$destino" ]]; then
    echo "  ya existe, se omite: $archivo"
    omitidos=$((omitidos + 1))
    continue
  fi

  if $DRY_RUN; then
    echo "  copiaría: $archivo"
  else
    mkdir -p "$(dirname "$destino")"
    cp "$origen" "$destino"
    echo "  copiado: $archivo"
  fi
  copiados=$((copiados + 1))
done

echo
echo "$copiados copiados, $omitidos omitidos por existir."
echo
echo "Siguiente paso: aplicar a mano los cambios de MIGRAR.md"
echo "(SpeechAudioManager, CameraStreamManager, GlassesConnectionManager,"
echo " FullScreenMainView, GlassesDeviceState y project.yml divergieron)."
echo
echo "Luego:  xcodegen generate && xcodebuild -scheme GlassesInstructor \\"
echo "          -destination 'generic/platform=iOS Simulator' build"
