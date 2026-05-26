## 0.1.1

- Expand pubspec description for pub.dev.
- Add dartdoc comments to public API (`startSimDeckFlutterInspector`, `stopSimDeckFlutterInspector`, `SimDeckFlutterInspector`, `SimDeckFlutterInspectorOptions`, `SimDeckFlutterInspectorFailure`).

## 0.1.0

- Initial release of `simdeck_flutter_inspector`.
- Publishes the live Flutter widget hierarchy to SimDeck over WebSocket in debug builds.
- Exposes render bounds, diagnostics properties, semantics metadata, and source locations when widget creation tracking is enabled.
- Supports `View.hitTest`, `View.describeAtPoint`, `View.getProperties`, `View.listActions`, and `View.perform` (tap, longPress, focus, resignFirstResponder, setText, scrollBy, scrollTo, increase, decrease).
