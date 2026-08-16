# Drittanbieter-Hinweise

Die PolyForm-Noncommercial-Lizenz von KRover gilt nicht für Software und
sonstiges Material Dritter. Diese Bestandteile behalten ihre eigenen Lizenzen.
Das Repository enthält keine Kopien der nachfolgend genannten Bibliotheken;
sie werden beim Build über Swift Package Manager beziehungsweise PlatformIO
bezogen.

## Laufzeit-Abhängigkeiten

- **MapLibre Native 6.28.0** — BSD 2-Clause. Copyright MapLibre contributors,
  MapTiler.com und Mapbox. Die Lizenz und die Copyright-Hinweise müssen bei der
  Weitergabe der iOS-App in der Dokumentation oder in anderen mitgelieferten
  Materialien erhalten bleiben.
  [Lizenz](https://github.com/maplibre/maplibre-gl-native-distribution/blob/6.28.0/LICENSE.md)
- **NimBLE-Arduino 2.5.1** — Apache License 2.0. Copyright Ryan Powell sowie die
  Mitwirkenden von esp-nimble-cpp und NimBLE-Arduino; Teile gehen auf Neil
  Kolban und esp32-snippets zurück. Bei einer Firmware-Weitergabe sind die
  Apache-Lizenz und die NOTICE-Hinweise beizulegen.
  [Lizenz](https://github.com/h2zero/NimBLE-Arduino/blob/2.5.1/LICENSE) ·
  [NOTICE](https://github.com/h2zero/NimBLE-Arduino/blob/2.5.1/NOTICE)
- **Arduino-ESP32 2.0.17** — GNU Lesser General Public License 2.1 oder später.
  Die Version wird durch `espressif32@7.0.1` von PlatformIO bereitgestellt.
  Wer ein kompiliertes Firmware-Image verteilt, muss insbesondere die
  Lizenzhinweise, den zugehörigen Bibliotheks-Quellcode und eine praktisch
  nutzbare Möglichkeit zum Ändern und erneuten Linken der LGPL-Bestandteile
  bereitstellen. Die Rechte an diesen Bestandteilen dürfen durch die
  KRover-Lizenz nicht eingeschränkt werden.
  [Lizenz](https://github.com/espressif/arduino-esp32/blob/2.0.17/LICENSE.md)
- **PlatformIO Espressif 32 Platform 7.0.1** — Apache License 2.0.
  [Lizenz](https://github.com/platformio/platform-espressif32/blob/v7.0.1/LICENSE)

NimBLE-Arduino enthält seinerseits weitere Bestandteile, unter anderem den
Apache-2.0-lizenzierten NimBLE-Stack und BSD-lizenzierte TinyCrypt-Komponenten.
Die jeweiligen Lizenzdateien der beim Build aufgelösten Pakete sind ebenfalls
zu beachten.

## Nur für Tests

- **Unity 2.6.1** — MIT License. Unity wird nur von den nativen Firmware-Tests
  verwendet und nicht in die Geräte-Firmware eingebunden.
  [Lizenz](https://github.com/ThrowTheSwitch/Unity/blob/v2.6.1/LICENSE.txt)

## Apple-Plattformbibliotheken

Die iOS-App verwendet außerdem Frameworks aus dem Apple SDK. Deren Nutzung und
Weitergabe richtet sich nach den jeweils anwendbaren Apple-Bedingungen; sie
werden durch dieses Repository nicht neu lizenziert.

## Bild- und Markenrechte

Bilder, Produktdarstellungen, Logos und Marken Dritter werden nicht durch die
KRover-Lizenz freigegeben. Vor einer Weiterverwendung oder Veröffentlichung
müssen die jeweils erforderlichen Rechte separat geprüft werden.
