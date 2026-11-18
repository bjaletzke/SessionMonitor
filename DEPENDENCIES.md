# Dependencies and distribution

Session Monitor is a native macOS SwiftPM executable. It uses no hosted monitoring service, telemetry SDK, or inference dependency. Scanning does not require API keys.

| Dependency | Pinned version / source | License / notices |
| --- | --- | --- |
| Swift Markdown | 0.9.0; revision in `Package.resolved`; https://github.com/swiftlang/swift-markdown | Apache-2.0 with Swift Runtime Library Exception. Preserve `LICENSE.txt` and `NOTICE.txt`. |
| swift-cmark / cmark-gfm | 0.9.0; transitive, revision in `Package.resolved`; https://github.com/swiftlang/swift-cmark | BSD-style cmark terms and additional MIT notices for bundled components. Preserve the entire `COPYING` file. |
| SQLite | macOS system library `libsqlite3`, not vendored | SQLite is public domain: https://sqlite.org/copyright.html. |
| Swift Charts, SwiftUI, AppKit, Foundation, Swift runtime | Apple SDK / system frameworks | Provided by the operating system/toolchain; not vendored by this project. Apple SDK terms apply. |

`script/build_and_run.sh` includes complete dependency license and notice files in `Contents/Resources/Acknowledgements`, together with this inventory. It maps compiler checkout paths to `/src/SessionMonitor` so the packaged executable does not expose the developer's personal source path. The app does not bundle provider CLIs, provider data, test fixtures, configuration, authentication, or real chats.

The project's own license is pending owner selection. Dependency licenses do not grant a license to Session Monitor itself. Do not describe a distribution as open-source licensed until the owner adds the chosen `LICENSE`. The build script will include that file when present.

The development app is signed ad hoc for local use. Publishing a repository, selecting a project license, signing with an Apple Developer identity, notarizing and distributing a release are separate steps. None is performed by the build script.

## Analytics visualizations

The web analytics workspace serves these dependencies from `analytics/web/vendor` and makes no runtime CDN requests.

| Library | Version | License | Local notice |
| --- | --- | --- | --- |
| [D3](https://d3js.org/getting-started) | 7.9.2 | ISC | [D3-LICENSE.txt](analytics/web/vendor/D3-LICENSE.txt) |
| [Three.js](https://github.com/mrdoob/three.js/releases/tag/r187) | 0.187.0 / r187 | MIT | [three.LICENSE.txt](analytics/web/vendor/three.LICENSE.txt) |
| [OrbitControls](https://threejs.org/docs/pages/OrbitControls) | From Three.js 0.187.0 | MIT | [three.NOTICE.txt](analytics/web/vendor/three.NOTICE.txt) |

D3 loads with Explorer's interface. Three.js and OrbitControls load when Constellation is opened. OrbitControls' package import is rewritten to the local Three.js module. The modules and license notices otherwise retain their upstream content.
